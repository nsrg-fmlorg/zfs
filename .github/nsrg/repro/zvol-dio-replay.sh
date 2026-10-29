#!/bin/sh
# zvol-dio-replay.sh: which mix of direct and buffered sync writes to a
# frozen pool makes the ZIL replay at import hang?  Variants run from the
# least to the most suspect; at the first import that does not return,
# the kernel stacks and the dbgmsg are saved and the script stops, since
# a hung import holds the namespace lock and nothing after it would run.
# Run as root.
set -u
OUT=/var/tmp/repro
mkdir -p "$OUT"
DIR=/var/tmp/repro-vdev
BLK=131072
PATH=$(pwd):$PATH

log() { echo "$*" | tee -a "$OUT/summary.txt"; }

echo 1 > /sys/module/zfs/parameters/zfs_dbgmsg_enable
echo 1 > /proc/sys/kernel/sysrq
dd if=/dev/urandom of="$OUT/data" bs=$BLK count=64 status=none

# identify <file> <block>: which data block (or "zero") a block holds
identify() {
	dd if="$1" bs=$BLK skip="$2" count=1 status=none > "$OUT/blk"
	if cmp -s "$OUT/blk" /dev/zero -n $BLK; then echo zero; return; fi
	j=0
	while [ $j -lt 64 ]; do
		if dd if="$OUT/data" bs=$BLK skip=$j count=1 status=none |
		    cmp -s - "$OUT/blk"; then
			echo "data$j"
			return
		fi
		j=$((j + 1))
	done
	echo other
}

w() { # w <direct|buffered> <src block> <dst block>
	if [ "$1" = direct ]; then f=direct,dsync; else f=dsync; fi
	dd if="$OUT/data" of=/dev/zvol/rp/vol oflag=$f bs=$BLK count=1 \
	    skip="$2" seek="$3" conv=notrunc status=none
}

variant() { # variant <direct property> <name> <write list...>
	direct=$1 name=$1-$2
	shift 2
	rm -rf "$DIR" && mkdir -p "$DIR" && truncate -s 1G "$DIR/a"
	zpool create -f rp "$DIR/a"
	if [ "$direct" = none ]; then
		zfs create -V 64M -b 128K -o compression=off rp/vol
	else
		zfs create -V 64M -b 128K -o direct="$direct" \
		    -o compression=off rp/vol
	fi
	udevadm settle
	if [ "${REPRO_PREFILL:-yes}" = yes ]; then
		dd if=/dev/zero of=/dev/zvol/rp/vol bs=1M count=16 status=none
	fi
	zpool sync rp
	zpool freeze rp
	expect=""
	while [ $# -gt 0 ]; do
		w "$1" "$2" "$3"
		expect="$expect $3:data$2"
		shift 3
	done
	zpool export rp
	zpool import -d "$DIR" rp &
	pid=$!
	i=0
	while kill -0 $pid 2>/dev/null && [ $i -lt 90 ]; do
		sleep 1
		i=$((i + 1))
	done
	if kill -0 $pid 2>/dev/null; then
		log "$name: import HUNG after ${i}s"
		echo w > /proc/sysrq-trigger
		dmesg > "$OUT/dmesg.txt"
		for p in $(pgrep -f 'zpool import'); do
			echo "== $p"
			cat /proc/"$p"/stack
		done > "$OUT/stacks.txt" 2>&1
		for p in $(pgrep -f 'txg_sync|zvol|z_wr|z_rd'); do
			echo "== $p $(cat /proc/"$p"/comm)"
			cat /proc/"$p"/stack
		done >> "$OUT/stacks.txt" 2>&1
		cat /proc/spl/kstat/zfs/dbgmsg > "$OUT/dbgmsg.txt"
		exit 1
	fi
	wait $pid
	log "$name: import returned $? after ${i}s"
	udevadm settle
	dd if=/dev/zvol/rp/vol of="$OUT/$name.read" bs=$BLK count=16 \
	    status=none
	# The last write to each block must win.
	for e in $expect; do
		blk=${e%%:*}
		want=$(echo "$expect" | tr ' ' '\n' | grep "^$blk:" | tail -1)
		got=$(identify "$OUT/$name.read" "$blk")
		[ "$blk:$got" = "$want" ] && continue
		log "$name: block $blk holds $got, expected ${want#*:}"
	done
	zpool destroy rp
}

# REPRO_DIRECT is "none" for a tree without the volume direct property.
for d in ${REPRO_DIRECT:-standard always}; do
	variant "$d" C-overwrite	buffered 1 0  buffered 33 0
	variant "$d" D-direct-overwrite	direct 1 0  direct 33 0
	variant "$d" F-test-sequence	direct 0 0  buffered 1 1  \
	    buffered 32 0  direct 33 1
done
log "no hang"
