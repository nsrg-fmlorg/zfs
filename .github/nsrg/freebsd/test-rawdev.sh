#!/bin/sh
# test-rawdev.sh: file vdevs on a device node with no GEOM provider.
#
# Each case names what it guards.  The cases that cannot hang a pool run
# first, and every write runs in the background with a bound, so that a
# tree with these bugs still reports them all instead of blocking on a
# suspended pool.  A kernel panic stops the VM; the ssh session dies and
# the job fails at that case.
set -eu

ZPOOL=/usr/local/sbin/zpool
ZDB=/usr/local/sbin/zdb
DEV=/dev/zrawdisk
POOL=rawtp
fails=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ctr() { sysctl -n "debug.zrawdisk.$1"; }

# bounded <seconds> <what> <command...>: run a command that may block on
# a suspended pool; if it does, show where it sleeps and count a failure.
# Its output is dropped so that a blocked one does not hold ssh open.
bounded() {
	secs=$1 what=$2
	shift 2
	"$@" </dev/null >/dev/null 2>&1 &
	pid=$!
	i=0
	while kill -0 $pid 2>/dev/null && [ $i -lt "$secs" ]; do
		sleep 1
		i=$((i + 1))
	done
	if kill -0 $pid 2>/dev/null; then
		fail "$what: still blocked after ${secs}s"
		procstat -kk $pid || true
		timeout 10 $ZPOOL status $POOL || true
		return 1
	fi
	wait $pid
}

# The image may load the base system's zfs.ko; this tree's must replace
# it.  gmake install puts it in /boot/modules, named openzfs.ko so that
# it does not shadow the base one.
if kldstat -q -m zfs && ! kldunload zfs; then
	echo "cannot unload the loaded zfs module; root is:" >&2
	mount -p | head -1 >&2
	exit 1
fi
kldload /boot/modules/openzfs.ko
kldload .github/nsrg/freebsd/zrawdisk/zrawdisk.ko
[ -c $DEV ] || { echo "no $DEV" >&2; exit 1; }
# RAWDEV_LENIENT=1: measure a tree that gets lengths and sizes wrong
# instead of stopping at its first refused bio.
sysctl -q debug.zrawdisk.lenient="${RAWDEV_LENIENT:-0}"
counters() { sysctl debug.zrawdisk; }
trap counters EXIT

# zpool classification: a device node without a provider is a file vdev,
# an md(4) disk still a disk vdev.
if ! $ZPOOL create -f -O compression=off -O recordsize=1M $POOL $DEV; then
	fail "cannot create a pool on $DEV"
	exit 1
fi
if $ZDB -C $POOL | grep -q "type: 'file'"; then
	ok "no-GEOM device becomes a file vdev"
else
	fail "no-GEOM device is not a file vdev"
fi
md=$(mdconfig -a -t swap -s 64m)
$ZPOOL create -f mdtp "$md"
if $ZDB -C mdtp | grep -q "type: 'disk'"; then
	ok "GEOM device is still a disk vdev"
else
	fail "GEOM device is no longer a disk vdev"
fi
$ZPOOL destroy mdtp

# Sector and stripe size reach the ashift.
if $ZDB -C $POOL | grep -q "ashift: 12"; then
	ok "ashift from DIOCGSTRIPESIZE"
else
	fail "ashift not taken from the device"
fi

# The cache file is written with O_CREAT; pointed at a device node it
# must be refused, not written over the device.  md is any VCHR here.
dd if=/dev/zero of=/dev/"$md" bs=64k count=1 status=none
$ZPOOL set cachefile=/dev/"$md" $POOL 2>/dev/null || true
zeros=$(dd if=/dev/zero bs=64k count=1 status=none | sha256 -q)
if [ "$(dd if=/dev/"$md" bs=64k count=1 status=none | sha256 -q)" = \
    "$zeros" ]; then
	ok "cache file not written onto a device node"
else
	fail "cache file written onto /dev/$md"
fi
$ZPOOL set cachefile= $POOL
mdconfig -d -u "$md"

# TRIM: BIO_DELETE must carry its length in bio_bcount.
bounded 120 "TRIM" $ZPOOL trim -w $POOL || true
if [ "$(ctr delete_bytes)" -gt 0 ]; then
	ok "TRIM deleted $(ctr delete_bytes) bytes"
else
	fail "TRIM deleted nothing"
fi
if [ "$(ctr bad_bcount)" = 0 ]; then
	ok "every bio had bio_bcount set"
else
	fail "$(ctr bad_bcount) bios without bio_bcount"
fi

# Data with 1M records, larger than the fixture's 64K si_iosize_max:
# guards splitting and unmapped I/O.
if bounded 300 "write" sh -c \
    "dd if=/dev/random of=/$POOL/f bs=1m count=200 status=none &&
    $ZPOOL sync $POOL"; then
	ok "200M written"
fi
if [ "$(ctr oversize)" = 0 ]; then
	ok "no bio over si_iosize_max"
else
	fail "$(ctr oversize) bios over si_iosize_max"
fi
if [ "$(ctr unmapped)" = 0 ]; then
	ok "no unmapped bio to a device without SI_UNMAPPED"
else
	fail "$(ctr unmapped) unmapped bios"
fi
if [ $fails -gt 0 ]; then
	echo "failures so far: $fails; the rest needs a working pool"
	exit 1
fi

sum1=$(sha256 -q /$POOL/f)
$ZPOOL export $POOL
$ZPOOL import -d /dev $POOL
sum2=$(sha256 -q /$POOL/f)
if [ "$sum1" = "$sum2" ]; then
	ok "data survives export/import"
else
	fail "data differs after export/import"
fi
$ZPOOL scrub -w $POOL
if $ZPOOL status $POOL | grep -q "errors: No known data errors"; then
	ok "scrub clean"
else
	fail "scrub found errors"
	$ZPOOL status -v $POOL
fi
if [ "$(ctr flushes)" -gt 0 ]; then
	ok "BIO_FLUSH reaches the device"
else
	fail "no BIO_FLUSH"
fi

# DIOCGSECTORSIZE failing during open: must fail the import, not drop a
# reference the caller still holds (panicked before).
$ZPOOL export $POOL
sysctl -q debug.zrawdisk.fail_sectorsize=1
if $ZPOOL import -d /dev $POOL 2>/dev/null; then
	fail "import succeeded without a sector size"
	$ZPOOL export $POOL
else
	ok "import refused without a sector size"
fi
sysctl -q debug.zrawdisk.fail_sectorsize=0
if $ZPOOL import -d /dev $POOL; then
	ok "import after the sector size returns"
else
	fail "cannot import again"
fi

# ENXIO from the driver: bio_to is NULL on these bios (panicked before).
# The pool suspends, as it would on any vdev; once ENXIO is lifted and
# the pool cleared, the writer must finish.
$ZPOOL set failmode=continue $POOL
sysctl -q debug.zrawdisk.fail_enxio=1
sh -c "dd if=/dev/random of=/$POOL/g bs=1m count=8 status=none;
    $ZPOOL sync $POOL" </dev/null >/dev/null 2>&1 &
writer=$!
sleep 20
echo "after 20s of ENXIO:"
timeout 10 $ZPOOL status $POOL || true
sysctl -q debug.zrawdisk.fail_enxio=0
timeout 30 $ZPOOL clear $POOL || true
i=0
while kill -0 $writer 2>/dev/null && [ $i -lt 120 ]; do
	sleep 1
	i=$((i + 1))
done
if kill -0 $writer 2>/dev/null; then
	fail "ENXIO: writer still blocked after clear"
	procstat -kk -a | grep -E "dd|zpool|txg_" || true
else
	ok "ENXIO: pool recovered after clear"
fi

# The cdev going away under an imported pool: the vdev must be marked
# REMOVED (zfs_post_remove() posts the event), not panic.
sysctl -q debug.zrawdisk.destroy=1
sleep 2
sh -c "dd if=/dev/random of=/$POOL/h bs=1m count=8 status=none;
    $ZPOOL sync $POOL" </dev/null >/dev/null 2>&1 &
sleep 60
timeout 10 $ZPOOL status $POOL || true
if timeout 10 $ZPOOL events | grep -q "resource.fs.zfs.removed"; then
	ok "removal reported"
else
	fail "no removal event 60s after the cdev went away"
	timeout 10 $ZPOOL events || true
fi

echo "failures: $fails"
[ $fails -eq 0 ]
