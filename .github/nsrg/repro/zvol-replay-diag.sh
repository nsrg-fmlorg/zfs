#!/bin/sh
# zvol-replay-diag.sh: where do sync writes to a frozen pool's volume
# go missing?  Each case writes data1 then data33 to block 0 and data5
# to block 2, and reports what the volume holds while frozen, what the
# ZIL holds before export, and what the volume holds after import.
# Run as root.
set -u
OUT=/var/tmp/diag
mkdir -p "$OUT"
DIR=/var/tmp/diag-vdev
BLK=131072
PATH=$(pwd):$PATH

echo 1 > /sys/module/zfs/parameters/zfs_dbgmsg_enable
dd if=/dev/urandom of="$OUT/data" bs=$BLK count=64 status=none

ident() { # ident <file> <block>
	dd if="$1" bs=$BLK skip="$2" count=1 status=none > "$OUT/blk"
	if cmp -s "$OUT/blk" /dev/zero -n $BLK; then echo zero; return; fi
	for j in 1 5 33 60; do
		if dd if="$OUT/data" bs=$BLK skip=$j count=1 status=none |
		    cmp -s - "$OUT/blk"; then
			echo "data$j"
			return
		fi
	done
	echo other
}

state() { # state <case> <when>
	dd if=/dev/zvol/rp/vol of="$OUT/r" bs=$BLK count=4 iflag=direct \
	    status=none || echo "$1: $2: read failed"
	echo "$1: $2: blk0=$(ident "$OUT/r" 0) blk2=$(ident "$OUT/r" 2)"
}

w() { # w <oflag> <src> <dst>
	dd if="$OUT/data" of=/dev/zvol/rp/vol oflag="$1" bs=$BLK count=1 \
	    skip="$2" seek="$3" conv=notrunc status=none
}

hung() { # hung <case> <step>
	cp /proc/spl/kstat/zfs/dbgmsg "$OUT/$1.dbgmsg"
	dmesg | grep -v -E 'audit|apparmor' | tail -80 | sed "s/^/$1: dmesg: /"
	echo "$1: $2 hung; stopping"
	chmod -R a+r "$OUT"
	exit 1
}

# run <case> <prefill yes|no> <import flags> <oflag> <header yes|no>
run() {
	c=$1
	rm -rf "$DIR" && mkdir -p "$DIR" && truncate -s 1G "$DIR/a"
	zpool create -f rp "$DIR/a"
	zfs create -V 64M -b 128K -o compression=off rp/vol
	udevadm settle
	[ "$2" = yes ] &&
	    dd if=/dev/zero of=/dev/zvol/rp/vol bs=1M count=16 status=none
	# A sync write before the freeze, so the ZIL header is on disk.
	[ "$5" = yes ] && w dsync 60 10
	zpool sync rp
	zpool freeze rp
	w "$4" 1 0
	w "$4" 33 0
	w "$4" 5 2
	state "$c" frozen
	timeout 120 zpool export rp
	rc=$?
	echo "$c: export exit $rc"
	[ $rc = 124 ] && hung "$c" export
	echo > /proc/spl/kstat/zfs/dbgmsg
	# shellcheck disable=SC2086
	zpool import $3 -d "$DIR" rp &
	pid=$!
	i=0
	while kill -0 $pid 2>/dev/null && [ $i -lt 90 ]; do
		sleep 1
		i=$((i + 1))
	done
	if kill -0 $pid 2>/dev/null; then
		for p in $(pgrep -x zpool); do
			echo "== $p"
			cat /proc/"$p"/stack
		done 2>&1 | sed "s/^/$c: stack: /"
		hung "$c" import
	fi
	wait $pid
	echo "$c: import exit $?"
	udevadm settle
	state "$c" imported
	sleep 5
	state "$c" "imported+5s"
	cp /proc/spl/kstat/zfs/dbgmsg "$OUT/$c.dbgmsg"
	grep -i -E 'replay|claim|zil' "$OUT/$c.dbgmsg" | head -20 |
	    sed "s/^/$c: dbgmsg: /"
	zpool destroy rp
}

case ${DIAG_CASES:-all} in
all)
	run nohdr	no	-f	dsync		no
	run hdr		no	-f	dsync		yes
	run hdr-direct	no	-f	direct,dsync	yes
	;;
hdr)
	run hdr		no	-f	dsync		yes
	;;
esac
chmod -R a+r "$OUT"
