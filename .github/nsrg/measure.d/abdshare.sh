#!/bin/sh
# abdshare.sh <label> <srcdir> <outdir>: memory held twice by the ARC
# and dbufs while a hot set of 128k records is read again and again.
#
# arcstats overhead_size counts arc_buf data that is not shared with its
# header, i.e. the second copy; with sharing it should fall towards 0.
# The dbuf cache is made large enough to keep the whole set, which is
# where the two copies coexist.  Three rounds, each on a fresh pool.
set -eu
label=$1 src=$2 out=$3
nsrg=$(cd "$(dirname "$0")/.." && pwd)
param=/sys/module/zfs/parameters
SET=$((256 * 1024 * 1024))

kstat() {	# kstat <file> <name>
	awk -v n="$2" '$1 == n { print $3 }' /proc/spl/kstat/zfs/"$1"
}

"$nsrg"/load.sh "$src"
# arc.c ignores a zfs_arc_max that is not above arc_c_min.
echo $((64 * 1024 * 1024)) | sudo tee $param/zfs_arc_min >/dev/null
echo $((2048 * 1024 * 1024)) | sudo tee $param/zfs_arc_max >/dev/null
echo $((1024 * 1024 * 1024)) | sudo tee $param/dbuf_cache_max_bytes >/dev/null
printf '%s\tc_max\t%s\tdbuf_cache_max_bytes\t%s\n' "$label" \
    "$(kstat arcstats c_max)" "$(cat $param/dbuf_cache_max_bytes)" \
    >> "$out"/params.tsv

round=1
while [ $round -le 3 ]; do
	sudo truncate -s 4G /dev/shm/abdshare
	sudo "$src"/zpool create -f -O compression=off -O recordsize=128k \
	    -O atime=off abdshare /dev/shm/abdshare
	sudo dd if=/dev/urandom of=/abdshare/hot bs=1M count=$((SET >> 20)) \
	    status=none
	sudo "$src"/zpool export abdshare
	sudo "$src"/zpool import -d /dev/shm abdshare

	pass=1
	while [ $pass -le 3 ]; do
		t0=$(date +%s%N)
		sudo dd if=/abdshare/hot of=/dev/null bs=128k status=none
		t1=$(date +%s%N)
		printf '%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n' "$label" "$round" \
		    "$pass" $(((t1 - t0) / 1000000)) \
		    "$(kstat arcstats overhead_size)" \
		    "$(kstat arcstats data_size)" \
		    "$(kstat arcstats size)" \
		    "$(kstat dbufstats cache_size_bytes)" >> "$out"/raw.tsv
		pass=$((pass + 1))
	done

	sudo "$src"/zpool destroy abdshare
	sudo rm -f /dev/shm/abdshare
	round=$((round + 1))
done

{
	echo "### abdshare $label"
	echo
	echo "round pass ms overhead_size data_size arc_size dbuf_cache"
	cat "$out"/raw.tsv
} > "$out"/summary.md
