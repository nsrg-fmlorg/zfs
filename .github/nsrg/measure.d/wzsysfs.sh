#!/bin/sh
# wzsysfs.sh <label> <srcdir> <outdir>: what a zvol advertises for
# discard and write-zeroes, read from sysfs, on base and head.
set -eu
label=$1 src=$2 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
"$here"/.github/nsrg/load.sh "$src"
sudo truncate -s 2G /var/tmp/wz-vdev
sudo "$src"/zpool create -f wz /var/tmp/wz-vdev
sudo "$src"/zfs create -V 256M -o volblocksize=16k wz/vol
sudo udevadm settle
dev=$(basename "$(readlink -f /dev/zvol/wz/vol)")
{
	echo "== $label $(uname -r) $dev"
	for f in discard_max_bytes discard_granularity write_zeroes_max_bytes \
	    write_zeroes_unmap_max_hw_bytes write_zeroes_unmap_max_bytes; do
		printf '%s\t%s\n' "$f" \
		    "$(cat /sys/block/"$dev"/queue/$f 2>/dev/null || echo absent)"
	done
	grep -h 'WZEROES_UNMAP' "$src"/zfs_config.h || echo "no WZEROES_UNMAP in zfs_config.h"
} | tee "$out"/sysfs.txt | tee -a "$out"/summary.md
sudo "$src"/zpool destroy wz
sudo rm -f /var/tmp/wz-vdev
