#!/bin/sh
# zil-seq.sh <fix 0|1> <cases...>: does lrc_seq go backward in a chain,
# and what does import then do?  Writes data1, data33 to block 0 and
# data5 to block 2 in separate opens.  Run as root from a built tree.
set -u
FIX=$1; shift
OUT=/var/tmp/diag/fix$FIX
mkdir -p "$OUT"
DIR=/var/tmp/diag-vdev
BLK=131072
PATH=$(pwd):$PATH
export PATH
Z=/sys/module/zfs/parameters
echo 1 > $Z/zfs_dbgmsg_enable
echo "$FIX" > $Z/zil_seq_fix
dd if=/dev/urandom of="$OUT/data" bs=$BLK count=64 status=none

ident() {
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
state() { # state <case> <when> <file>
	dd if="$3" of="$OUT/r" bs=$BLK count=4 status=none iflag=direct ||
	    dd if="$3" of="$OUT/r" bs=$BLK count=4 status=none ||
	    echo "$1: $2: read failed"
	echo "$1: $2: blk0=$(ident "$OUT/r" 0) blk2=$(ident "$OUT/r" 2)"
}
w() { # w <dst file> <src> <dst block>
	dd if="$OUT/data" of="$1" oflag=dsync bs=$BLK count=1 \
	    skip="$2" seek="$3" conv=notrunc status=none
	udevadm settle
}
chain() { # chain <case> <dataset>: seqs in the log, pool exported
	zdb -e -p "$DIR" -ivvv "$2" > "$OUT/$1.zdb" 2>&1
	echo "$1: zdb rc $?"
	grep -E 'ZIL header|Block seqno' "$OUT/$1.zdb" | head -12 |
	    sed "s/^/$1: zdb: /"
	grep -oE 'seq [0-9]+' "$OUT/$1.zdb" | tr '\n' ' ' |
	    sed "s/^/$1: lr seqs: /"; echo
}
dbg() {
	cp /proc/spl/kstat/zfs/dbgmsg "$OUT/$1.dbgmsg"
	grep -E 'zil_|ZIL|replay' "$OUT/$1.dbgmsg" | cut -d' ' -f2- |
	    tail -${2:-40} | sed "s/^/$1: dbgmsg: /"
}
stuck() { # stuck <case> <step>
	dbg "$1"
	for p in $(pgrep -x zpool); do
		echo "== $p"; cat /proc/"$p"/stack
	done 2>&1 | sed "s/^/$1: stack: /"
	dmesg | grep -v -E 'audit|apparmor' | tail -50 | sed "s/^/$1: dmesg: /"
	echo "$1: $2 stuck, leaving this case"
	chmod -R a+r /var/tmp/diag
	exit 1
}
imp() { # imp <case> <flags...>
	c=$1; shift
	echo > /proc/spl/kstat/zfs/dbgmsg
	zpool import "$@" -d "$DIR" rp &
	pid=$!
	i=0
	while kill -0 $pid 2>/dev/null && [ $i -lt 60 ]; do
		sleep 1
		i=$((i + 1))
	done
	kill -0 $pid 2>/dev/null && stuck "$c" import
	wait $pid
	echo "$c: import exit $?"
	udevadm settle
}
fresh() {
	rm -rf "$DIR" && mkdir -p "$DIR" && truncate -s 1G "$DIR/a"
	zpool create -f rp "$DIR/a"
	echo > /proc/spl/kstat/zfs/dbgmsg
}
mkvol() {
	zfs create -V 64M -b 128K -o compression=off rp/vol
	udevadm settle
}
lastsynced() {
	awk '$3 == "C" { t = $1 } END { print t }' /proc/spl/kstat/zfs/rp/txgs
}
sessions() { # sessions <case> <path>
	w "$2" 1 0; w "$2" 33 0; w "$2" 5 2
	state "$1" written "$2"
}
V=/dev/zvol/rp/vol
F=/rp/fs/f

case_vol_frozen() {
	c=vol-frozen; fresh; mkvol
	w $V 60 10; zpool sync rp; zpool freeze rp
	sessions $c $V
	dbg $c 30
	zpool export rp; echo "$c: export $?"; chain $c rp/vol
	imp $c -f; state $c imported $V; dbg $c; zpool destroy rp
}
case_vol_open() {	# one open across the writes, as control
	c=vol-frozen-oneopen; fresh; mkvol
	w $V 60 10; zpool sync rp; zpool freeze rp
	exec 9< $V
	sessions $c $V
	exec 9<&-
	udevadm settle
	zpool export rp; echo "$c: export $?"; chain $c rp/vol
	imp $c -f; state $c imported $V; dbg $c; zpool destroy rp
}
case_vol_plain() {	# no freeze, no rewind: must be clean
	c=vol-plain; fresh; mkvol
	w $V 60 10; zpool sync rp
	sessions $c $V
	dbg $c 30
	zpool export rp; echo "$c: export $?"; chain $c rp/vol
	imp $c; state $c imported $V; dbg $c; zpool destroy rp
}
case_vol_rewind() {	# no freeze: rewind past the closes
	c=vol-rewind; fresh; mkvol
	w $V 60 10; zpool sync rp
	t=$(lastsynced); echo "$c: rewind target txg $t"
	sessions $c $V
	dbg $c 30
	zpool export rp; echo "$c: export $?"
	zdb -e -p "$DIR" -ul rp 2>&1 | grep -E '^ *txg' | sort -u | tail -5 |
	    sed "s/^/$c: ub: /"
	imp $c -T "$t"; state $c imported $V; dbg $c; zpool destroy rp
}
case_fs_frozen() {
	c=fs-frozen-remount; fresh
	zfs create -o recordsize=128K -o compression=off rp/fs
	w $F 60 10; zpool sync rp; zpool freeze rp
	w $F 1 0
	zfs unmount rp/fs; zfs mount rp/fs
	w $F 33 0
	zfs unmount rp/fs; zfs mount rp/fs
	w $F 5 2
	state $c written $F
	dbg $c 30
	zpool export rp; echo "$c: export $?"; chain $c rp/fs
	imp $c -f; state $c imported $F; dbg $c; zpool destroy rp
}
case_fs_frozen_nomount() {	# control
	c=fs-frozen; fresh
	zfs create -o recordsize=128K -o compression=off rp/fs
	w $F 60 10; zpool sync rp; zpool freeze rp
	sessions $c $F
	zpool export rp; echo "$c: export $?"; chain $c rp/fs
	imp $c -f; state $c imported $F; dbg $c; zpool destroy rp
}
case_fs_rewind() {
	c=fs-rewind; fresh
	zfs create -o recordsize=128K -o compression=off rp/fs
	w $F 60 10; zpool sync rp
	t=$(lastsynced); echo "$c: rewind target txg $t"
	w $F 1 0
	zfs unmount rp/fs; zfs mount rp/fs
	w $F 33 0
	zfs unmount rp/fs; zfs mount rp/fs
	w $F 5 2
	zpool export rp; echo "$c: export $?"; chain $c rp/fs
	imp $c -T "$t"; state $c imported $F; dbg $c; zpool destroy rp
}
case_vol_suspend() {	# no freeze: write errors suspend the pool mid-chain
	c=vol-suspend; fresh; mkvol
	w $V 60 10; zpool sync rp
	zinject -d "$DIR/a" -e io -T write -f 100 rp
	w $V 1 0 &
	wp=$!
	i=0
	while [ $i -lt 30 ]; do
		[ "$(zpool get -Ho value health rp)" = SUSPENDED ] && break
		sleep 1; i=$((i + 1))
	done
	echo "$c: health $(zpool get -Ho value health rp) after ${i}s"
	zinject -c all
	timeout 60 zpool clear rp; echo "$c: clear $?"
	i=0
	while kill -0 $wp 2>/dev/null && [ $i -lt 60 ]; do
		sleep 1; i=$((i + 1))
	done
	kill -0 $wp 2>/dev/null && stuck $c write
	w $V 33 0; w $V 5 2
	state $c written $V
	dbg $c 30
	timeout 60 zpool export rp; echo "$c: export $?"; chain $c rp/vol
	imp $c; state $c imported $V; dbg $c; zpool destroy rp
}

for c in "$@"; do
	echo "=== fix=$FIX $c"
	( "case_$c" ) 2>&1
	echo "=== rc $?"
	if zpool list rp >/dev/null 2>&1; then
		timeout 60 zpool destroy -f rp
	fi
done
chmod -R a+r /var/tmp/diag
