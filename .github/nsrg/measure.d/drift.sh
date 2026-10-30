#!/bin/sh
# drift.sh <label> <srcdir> <outdir>: why do four readers of one file
# drift apart?  Run 41116115375 showed this branch is faster than master
# with the reader layout fixed, yet in the shared-file layout it spends
# more time with the readers more than an ARC apart.  Here only that
# layout runs, longer, with per-job latency and bandwidth each second
# and the ARC, dbuf and prefetch counters on the same time axis, so the
# moment the readers separate can be inspected: which job slowed, and
# whether the followers stopped finding the leader's blocks.
set -eu
label=$1 src=$2 out=$3
nsrg=$(cd "$(dirname "$0")/.." && pwd)
param=/sys/module/zfs/parameters
RUNS=8
SECS=30

ARC="size c demand_data_hits demand_data_misses demand_data_iohits \
    prefetch_data_hits prefetch_data_misses prefetch_data_iohits \
    demand_hit_predictive_prefetch demand_iohit_predictive_prefetch \
    mru_hits mfu_hits mru_ghost_hits mfu_ghost_hits deleted \
    evict_l2_eligible evict_skip evict_not_enough mutex_miss"
DBUF="cache_size_bytes cache_count hash_hits hash_misses cache_total_evicts"
ZF="hits future stride past misses io_issued io_active"

kstat() {	# kstat <file> <name>
	awk -v n="$2" '$1 == n { print $3 }' /proc/spl/kstat/zfs/"$1"
}

header() {
	printf 'label\ttag\tt'
	for k in $ARC; do printf '\tarc.%s' "$k"; done
	for k in $DBUF; do printf '\tdbuf.%s' "$k"; done
	for k in $ZF; do printf '\tzf.%s' "$k"; done
	printf '\n'
}

sampler() {	# sampler <tag>: one line a second until the stop file appears
	while [ ! -e "$out/stop" ]; do
		printf '%s\t%s\t%s' "$label" "$1" "$(date +%s)"
		for k in $ARC; do printf '\t%s' "$(kstat arcstats "$k")"; done
		for k in $DBUF; do printf '\t%s' "$(kstat dbufstats "$k")"; done
		for k in $ZF; do printf '\t%s' "$(kstat zfetchstats "$k")"; done
		printf '\n'
		sleep 1
	done >> "$out"/samples.tsv
}

fio_read() {	# fio_read <tag>
	sudo fio --name=r --filename=/drift/f --rw=read --bs=1M \
	    --numjobs=4 --size=4G --time_based --runtime=$SECS \
	    --write_bw_log="$out/bw-$1" --write_lat_log="$out/lat-$1" \
	    --log_avg_msec=1000 --group_reporting --output-format=json |
	    jq -r --arg l "$label" --arg t "$1" \
	    '[$l, $t, (.jobs[0].read.bw_bytes / 1048576 | floor)] | @tsv' \
	    >> "$out"/raw.tsv
}

"$nsrg"/load.sh "$src"
# arc.c ignores a zfs_arc_max that is not above arc_c_min.
echo $((64 * 1024 * 1024)) | sudo tee $param/zfs_arc_min >/dev/null
echo $((512 * 1024 * 1024)) | sudo tee $param/zfs_arc_max >/dev/null
{
	printf '%s\tc_max\t%s\n' "$label" "$(kstat arcstats c_max)"
	printf '%s\tkernel\t%s\n' "$label" "$(uname -r)"
	printf '%s\tdbuf_cache_target\t%s\n' "$label" \
	    "$(kstat dbufstats cache_target_bytes)"
	for p in zfetch_max_distance zfetch_min_distance zfetch_max_streams \
	    zfs_arc_min_prefetch_ms dbuf_cache_shift; do
		printf '%s\t%s\t%s\n' "$label" "$p" \
		    "$(cat $param/$p 2>/dev/null || echo absent)"
	done
} >> "$out"/params.tsv
header > "$out"/samples.tsv

# 6G stays below the runner's 8G /dev/shm; a file vdev does not return
# freed space to tmpfs.
sudo truncate -s 6G /dev/shm/drift
sudo "$src"/zpool create -f -O compression=off -O recordsize=1M \
    -O atime=off drift /dev/shm/drift
sudo dd if=/dev/urandom of=/drift/f bs=1M count=4096 status=none
sudo "$src"/zpool sync drift

i=1
while [ $i -le $RUNS ]; do
	tag="run$i"
	rm -f "$out/stop"
	sampler "$tag" &
	spid=$!
	fio_read "$tag"
	touch "$out/stop"
	wait "$spid" || true
	i=$((i + 1))
done
rm -f "$out/stop"

sudo "$src"/zpool destroy drift
sudo rm -f /dev/shm/drift
{
	echo "### drift $label (MiB/s per run)"
	cat "$out"/raw.tsv
} > "$out"/summary.md
