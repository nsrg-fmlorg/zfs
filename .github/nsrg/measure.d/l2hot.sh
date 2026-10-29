#!/bin/sh
# l2hot.sh <base|head> <srcdir> <outdir>
#
# L2ARC hit rate with l2arc_keep_hot_pct.  A zipf-distributed random read
# over a file three times the size of the cache device: the hot head of
# the distribution fits in the L2ARC, the whole does not, so the write
# hand laps the device and, without keeping, overwrites hot blocks along
# with cold ones.  base runs once with master's module; head runs with
# the tunable at 0 (an A/A against base) and at 50.  Pool and cache
# device live in /dev/shm, so this is not a disk measurement.
set -eu

side=$1 src=$2 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
P=/sys/module/zfs/parameters
K=/proc/spl/kstat/zfs/arcstats
POOL=l2h

stat() {	# stat <name>: one arcstats counter, 0 if absent
	awk -v n="$1" '$1 == n { v = $3 } END { print v + 0 }' $K
}

param() {	# param <name> <value>
	echo "$2" | sudo tee "$P/$1" >/dev/null
}

zipf() {	# zipf <theta> <seconds>
	sudo fio --name=zipf --filename=/$POOL/f --rw=randread --bs=128k \
	    --size=1536M --random_distribution=zipf:"$1" --time_based \
	    --runtime="$2" --numjobs=2 --group_reporting \
	    --output-format=json | jq '.jobs[0].read.bw_bytes / 1048576 | floor'
}

run() {		# run <label> <keep_hot_pct, or - for base> <zipf theta>
	label=$1-z$3
	sudo truncate -s 4G /dev/shm/l2h-data
	sudo truncate -s 512M /dev/shm/l2h-cache
	sudo "$src"/zpool create -f -O compression=off -O recordsize=128K \
	    -O atime=off $POOL /dev/shm/l2h-data cache /dev/shm/l2h-cache
	sudo dd if=/dev/urandom of=/$POOL/f bs=1M count=1536 2>/dev/null
	sync
	[ "$2" = - ] || param l2arc_keep_hot_pct "$2"

	zipf "$3" 60 >/dev/null	# warm the ARC and fill the L2ARC

	h0=$(stat l2_hits) m0=$(stat l2_misses) w0=$(stat l2_write_bytes)
	k0=$(stat l2_keep_hot)
	bw=$(zipf "$3" 120)
	h1=$(stat l2_hits) m1=$(stat l2_misses) w1=$(stat l2_write_bytes)
	k1=$(stat l2_keep_hot)

	awk -v l="$label" -v bw="$bw" -v h=$((h1 - h0)) -v m=$((m1 - m0)) \
	    -v w=$(((w1 - w0) / 1048576)) -v k=$((k1 - k0)) 'BEGIN {
		printf "%s\t%s\t%d\t%d\t%.1f\t%d\t%d\n", l, bw, h, m,
		    h + m ? 100 * h / (h + m) : 0, w, k }' >> "$out"/result.tsv

	sudo "$src"/zpool destroy $POOL
	sudo rm -f /dev/shm/l2h-data /dev/shm/l2h-cache
}

"$here"/.github/nsrg/load.sh "$src"
# zfs_arc_max is ignored unless it is above zfs_arc_min (RAM/32 = 512M).
param zfs_arc_min $((64 * 1024 * 1024))
param zfs_arc_max $((256 * 1024 * 1024))
param l2arc_noprefetch 0
param l2arc_dwpd_limit 0
awk '$1 == "c_max" { print "c_max", $3 }' $K > "$out"/params.txt

printf 'run\tMiB/s\tl2_hits\tl2_misses\thit%%\tl2_written_MiB\tkept\n' \
    > "$out"/result.tsv
# A more skewed distribution (1.4) leaves fewer blocks hot, which is
# where keeping them should pay if it pays at all.
for theta in 1.1 1.4; do
	if [ "$side" = base ]; then
		run base - $theta
	else
		run head-off 0 $theta
		run head-keep10 10 $theta
		run head-keep50 50 $theta
	fi
done
cat "$out"/params.txt "$out"/result.tsv

if [ "$side" = head ]; then
	{
		echo "### l2hot (l2arc_keep_hot_pct)"
		echo
		echo '```'
		cat "$(dirname "$out")"/base/params.txt "$out"/params.txt
		cat "$(dirname "$out")"/base/result.tsv
		tail -n +2 "$out"/result.tsv
		echo '```'
	} > "$out"/summary.md
fi
