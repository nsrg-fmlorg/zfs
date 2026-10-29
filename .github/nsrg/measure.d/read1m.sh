#!/bin/sh
# read1m.sh <label> <srcdir> <outdir>: sequential 1M reads of 1M records,
# served from the ARC (hit) and from the vdev (miss, primarycache=
# metadata), five rounds with an A/A pair each, then a perf profile of
# each case.  The pool is in /dev/shm, so a miss costs the read path and
# not a disk.
set -eu
label=$1 src=$2 out=$3
nsrg=$(cd "$(dirname "$0")/.." && pwd)
param=/sys/module/zfs/parameters

if ! command -v perf >/dev/null 2>&1; then
	sudo apt-get install -y -qq linux-tools-common \
	    "linux-tools-$(uname -r)" >/dev/null 2>&1 ||
	    sudo apt-get install -y -qq linux-tools-common \
	    linux-tools-azure >/dev/null 2>&1 || true
fi

kstat() {	# kstat <name>
	awk -v n="$1" '$1 == n { print $3 }' /proc/spl/kstat/zfs/arcstats
}

# fio_read <tag> <seconds>: one sequential read, MiB/s to raw.tsv
fio_read() {
	sudo fio --name=r --filename=/read1m/f --rw=read --bs=1M \
	    --numjobs=4 --offset_increment=256M --size=256M --time_based \
	    --runtime="$2" --group_reporting --output-format=json |
	    jq -r --arg l "$label" --arg t "$1" \
	    '[$l, $t, (.jobs[0].read.bw_bytes / 1048576 | floor)] | @tsv' \
	    >> "$out"/raw.tsv
}

"$nsrg"/load.sh "$src"
# arc.c ignores a zfs_arc_max that is not above arc_c_min.
echo $((64 * 1024 * 1024)) | sudo tee $param/zfs_arc_min >/dev/null
echo $((2048 * 1024 * 1024)) | sudo tee $param/zfs_arc_max >/dev/null
printf '%s\tc_max\t%s\n' "$label" "$(kstat c_max)" >> "$out"/params.tsv

sudo truncate -s 4G /dev/shm/read1m
sudo "$src"/zpool create -f -O compression=off -O recordsize=1M \
    -O atime=off read1m /dev/shm/read1m
sudo dd if=/dev/urandom of=/read1m/f bs=1M count=1024 status=none
sudo "$src"/zpool sync read1m

round=1
while [ $round -le 5 ]; do
	for cache in all metadata; do
		sudo "$src"/zfs set primarycache=$cache read1m
		[ $cache = all ] && fio_read warmup 5 && sed -i '$d' "$out"/raw.tsv
		fio_read "$cache-A" 15
		fio_read "$cache-A2" 15
	done
	round=$((round + 1))
done

for cache in all metadata; do
	sudo "$src"/zfs set primarycache=$cache read1m
	fio_read "$cache-warm" 5
	sed -i '$d' "$out"/raw.tsv
	if command -v perf >/dev/null 2>&1; then
		sudo perf record -a -g -F 999 -o "$out"/perf.data -- \
		    sudo fio --name=r --filename=/read1m/f --rw=read --bs=1M \
		    --numjobs=4 --offset_increment=256M --size=256M \
		    --time_based --runtime=10 >/dev/null 2>&1 || true
		sudo perf report -i "$out"/perf.data --no-children \
		    --sort symbol --stdio 2>/dev/null | grep '%' | head -40 \
		    > "$out"/perf-$cache.txt || true
		sudo perf report -i "$out"/perf.data --no-children \
		    --sort symbol --stdio 2>/dev/null |
		    grep -E 'abd_|uiomove|copy_user|memcpy|kmap|rep_movs' |
		    head -30 > "$out"/perf-$cache-copy.txt || true
		sudo rm -f "$out"/perf.data
	else
		echo "perf unavailable" > "$out"/perf-$cache.txt
	fi
done

sudo "$src"/zpool destroy read1m
sudo rm -f /dev/shm/read1m

{
	echo "### read1m $label (MiB/s)"
	awk -F'\t' '{ s[$2] += $3; n[$2]++
	    if (!($2 in lo) || $3 < lo[$2]) lo[$2] = $3
	    if (!($2 in hi) || $3 > hi[$2]) hi[$2] = $3 }
	    END { for (k in s) printf "%s\t%d\t%d-%d\n", k, s[k] / n[k],
	    lo[k], hi[k] }' "$out"/raw.tsv | sort
} > "$out"/summary.md
