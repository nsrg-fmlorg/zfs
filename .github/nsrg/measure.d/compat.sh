#!/bin/sh
# compat.sh <label> <srcdir> <outdir>: what a tree without zero-detect
# does with a pool and a stream from one that has it.  The base tree is
# the older implementation.  The output is the result: a difference is
# something to read, not a failure, so only the data checks can fail.
set -u
label=$1 src=$2 out=$3
if [ "$label" = base ]; then
	echo "$src" > /var/tmp/compat-base
	exit 0
fi
base=$(cat /var/tmp/compat-base)
HERE=$(pwd)
log=$out/compat.txt
V=/var/tmp/compat.vdev
S=/var/tmp/compat.stream

run() {
	printf '\n$ %s\n' "$*" >> "$log"
	sudo "$@" >> "$log" 2>&1
	printf '[exit %d]\n' $? >> "$log"
}
say() { printf '\n=== %s\n' "$*" >> "$log"; }
sum() { sudo sha256sum "$1" | cut -c1-16; }
use() { "$HERE"/.github/nsrg/load.sh "$1"; T=$1; }

use "$src"
truncate -s 2G $V
say head creates the pool
run "$T"/zpool create -f -O atime=off cp $V
run "$T"/zfs create -o compression=zero-detect cp/fs
run "$T"/zfs create cp/fs/child
sudo dd if=/dev/urandom of=/cp/fs/data bs=1M count=32 status=none
sudo dd if=/dev/zero of=/cp/fs/zero bs=1M count=32 status=none
sudo dd if=/dev/urandom of=/cp/fs/child/data bs=1M count=8 status=none
run "$T"/zpool sync cp
s1=$(sum /cp/fs/data)
run "$T"/zfs snapshot -r cp/fs@s
sudo sh -c "$T/zfs send -p cp/fs@s > $S.p"
sudo sh -c "$T/zfs send -c -p cp/fs@s > $S.cp"
sudo sh -c "$T/zfs send -R cp/fs@s > $S.R"
run "$T"/zfs get -p compression cp/fs cp/fs/child
run "$T"/zdb -dddddd cp/fs 2
run "$T"/zpool export cp

use "$base"
say base imports it
run "$T"/zpool import -d /var/tmp cp
run "$T"/zpool status cp
run "$T"/zfs get compression cp/fs cp/fs/child
run "$T"/zfs get -p compression cp/fs
run "$T"/zfs get -s local all cp/fs
run "$T"/zfs list -o name,compression cp/fs
[ "$(sum /cp/fs/data)" = "$s1" ] || echo "DATA DIFFERS" >> "$log"
say "base writes under the stored value: zeroes, random, half"
sudo dd if=/dev/zero of=/cp/fs/zero2 bs=1M count=32 status=none
sudo dd if=/dev/urandom of=/cp/fs/data2 bs=1M count=32 status=none
sudo dd if=/dev/urandom of=/var/tmp/half bs=64k count=1 status=none
sudo dd if=/dev/zero of=/var/tmp/half bs=64k count=1 seek=1 status=none
sudo sh -c 'for i in 1 2 3 4 5 6 7 8; do cat /var/tmp/half; done > /cp/fs/half'
run "$T"/zpool sync cp
run "$T"/zfs get -p used,logicalused,compressratio cp/fs
run sh -c "du -k /cp/fs/zero2 /cp/fs/data2 /cp/fs/half"
s2=$(sum /cp/fs/data2)
say "base cannot set it, can inherit"
run "$T"/zfs set compression=zero-detect cp/fs
run "$T"/zfs inherit compression cp/fs/child
run "$T"/zpool scrub -w cp
run "$T"/zpool status cp
say base sends and receives
for k in p cp R; do
	printf '\n$ zfs receive cp/recv.%s < stream.%s\n' $k $k >> "$log"
	sudo sh -c "$T/zfs receive cp/recv.$k < $S.$k" >> "$log" 2>&1
	printf '[exit %d]\n' $? >> "$log"
	run "$T"/zfs get compression cp/recv.$k
	run "$T"/zfs get -p compression cp/recv.$k
done
run "$T"/zfs snapshot cp/fs@b
printf '\n$ base send -p\n' >> "$log"
sudo sh -c "$T/zfs send -p cp/fs@b > $S.b"
printf '[exit %d]\n' $? >> "$log"
run "$T"/zpool export cp

use "$src"
say head imports it back
run "$T"/zpool import -d /var/tmp cp
run "$T"/zfs get compression cp/fs cp/recv.p
[ "$(sum /cp/fs/data)" = "$s1" ] || echo "DATA DIFFERS" >> "$log"
[ "$(sum /cp/fs/data2)" = "$s2" ] || echo "DATA DIFFERS" >> "$log"
sudo sh -c "$T/zfs receive cp/back < $S.b" >> "$log" 2>&1
run "$T"/zfs get compression cp/back
run "$T"/zpool scrub -w cp
run "$T"/zpool status cp
run "$T"/zpool destroy cp
rm -f "$V"
sudo rm -f "$S".* /var/tmp/half
! grep -q 'DATA DIFFERS' "$log"
