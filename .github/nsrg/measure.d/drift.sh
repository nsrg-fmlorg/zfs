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
RUNS=3
SECS=30
# Run 41124334438: on this branch the readers wander more than
# zfetch_max_reorder (16M) apart, become separate prefetch streams and
# stall on demand misses; on master they stay in lockstep within 6M.
#   default  as shipped, with dbuf_read timed: on master followers should
#            wait in dbuf_read for the leader's fill (DB_READ), here not
# Run 41128647606: widening zfetch_max_reorder did not help.  On master
# the first reader of each block spends ~150 us filling the dbuf from the
# ARC (a 1M copy into a linear buffer) and the others read it in 1-4 us,
# so whoever leads is slowed and the others close up; this branch shares
# the buffer and the leader pays nothing.  Test that cause directly:
#   noscatter  zfs_abd_scatter_enabled=0 gives the ARC linear buffers,
#              which master shares too (arc_buf_alloc_impl), so master
#              loses its leader penalty; the prediction is that master
#              then drifts as this branch does, and this branch is
#              unchanged.
CONDS="default noscatter"

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

# dbuf_read is exported, so it keeps a symbol to probe.
trace() {	# trace <tag>
	command -v bpftrace >/dev/null 2>&1 || return 0
	cat > "$out/trace.bt" <<'BT'
kprobe:dbuf_read { @s[tid] = nsecs; }
kretprobe:dbuf_read /@s[tid]/ {
	@us = hist((nsecs - @s[tid]) / 1000);
	@n = count();
	if (nsecs - @s[tid] > 20000) { @over20us = count(); }
	delete(@s[tid]);
}
BT
	# The output belongs to the runner, as the rest of $out does.
	# shellcheck disable=SC2024
	sudo timeout $((SECS + 5)) bpftrace "$out/trace.bt" \
	    > "$out/trace-$1.txt" 2>&1 || true
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

command -v bpftrace >/dev/null 2>&1 ||
    sudo apt-get install -y -qq bpftrace >/dev/null 2>&1 || true
for cond in $CONDS; do
	case $cond in
	default) echo 1 ;;
	noscatter) echo 0 ;;
	esac | sudo tee $param/zfs_abd_scatter_enabled >/dev/null
	# Empty the ARC so every block comes back in a buffer of the new kind.
	sudo "$src"/zpool export drift
	sudo "$src"/zpool import -d /dev/shm drift
	printf '%s\t%s\tzfs_abd_scatter_enabled=%s\n' "$label" "$cond" \
	    "$(cat $param/zfs_abd_scatter_enabled)" >> "$out"/params.tsv
	i=1
	while [ $i -le $RUNS ]; do
		tag="$cond-run$i"
		rm -f "$out/stop"
		sampler "$tag" &
		spid=$!
		trace "$tag" &
		tpid=$!
		fio_read "$tag"
		touch "$out/stop"
		wait "$spid" || true
		wait "$tpid" || true
		i=$((i + 1))
	done
done
echo 1 | sudo tee $param/zfs_abd_scatter_enabled >/dev/null
rm -f "$out/stop"

sudo "$src"/zpool destroy drift
sudo rm -f /dev/shm/drift
{
	echo "### drift $label (MiB/s per run)"
	cat "$out"/raw.tsv
} > "$out"/summary.md
