#!/bin/sh
# verify-snap.sh: does a page changed under writeback leave a bad block
# that a snapshot keeps?  mmapflip's last msync rewrites everything, so
# only snapshots taken while it runs hold what was written mid-flight.
set -u
HERE=$(pwd)
OUT=/var/tmp/qd1
gcc -O2 -pthread -o "$OUT"/mmapflip .github/nsrg/repro/mmapflip.c
Z="sudo $HERE/zpool"
F="sudo $HERE/zfs"
for c in "always 0" "standard 0" "always 1"; do
	set -- $c
	echo "$2" | sudo tee /sys/module/zfs/parameters/zfs_vdev_direct_write_verify >/dev/null
	sudo rm -f /dev/shm/vd
	sudo truncate -s 3G /dev/shm/vd
	$Z create -f -O compression=off vp /dev/shm/vd
	$F create -V 128M -b 4k -o direct="$1" -o primarycache=none vp/vol
	udevadm settle
	sudo timeout 60 "$OUT"/mmapflip /dev/zvol/vp/vol 20 &
	p=$!
	i=0
	while [ $i -lt 15 ]; do
		sleep 1
		$F snapshot vp/vol@s$i
		i=$((i + 1))
	done
	wait $p
	$Z sync vp
	$Z scrub -w vp
	echo "SNAP direct=$1 verify=$2:"
	$Z status -dpv vp | sed -n '/NAME/,$p' | head -14 | sed 's/^/SNAP   /'
	udevadm settle
	n=0
	until $Z destroy vp 2>/dev/null; do
		n=$((n + 1)); [ $n -lt 15 ] || exit 1
		sleep 2
	done
done
