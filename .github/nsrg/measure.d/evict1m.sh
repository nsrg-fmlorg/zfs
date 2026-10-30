#!/bin/sh
# evict1m.sh <label> <srcdir> <outdir>: sequential 1M reads under constant
# ARC eviction (512M ARC, 4G file, four jobs reading it from the start),
# with everything on one time axis: fio bandwidth per second, arcstats and
# dbufstats sampled every second, and bpftrace on the eviction paths.
# The point is to see whether the slow seconds are the ones where
# eviction makes no progress and readers wait for it.
set -eu
label=$1 src=$2 out=$3
nsrg=$(cd "$(dirname "$0")/.." && pwd)
param=/sys/module/zfs/parameters
ROUNDS=3
SECS=30

command -v bpftrace >/dev/null 2>&1 ||
    sudo apt-get install -y -qq bpftrace >/dev/null 2>&1 || true

kstat() {	# kstat <file> <name>
	awk -v n="$2" '$1 == n { print $3 }' /proc/spl/kstat/zfs/"$1"
}

ARCS="size c data_size overhead_size mru_data mfu_data \
    mru_evictable_data mfu_evictable_data evict_skip evict_not_enough \
    mutex_miss evict_l2_skip memory_throttle_count arc_need_free"

sampler() {	# sampler <tag>: one line a second until the stop file appears
	while [ ! -e "$out/stop" ]; do
		printf '%s\t%s\t%s' "$label" "$1" "$(date +%s)"
		for k in $ARCS; do
			printf '\t%s' "$(kstat arcstats "$k")"
		done
		printf '\t%s\t%s\n' "$(kstat dbufstats cache_size_bytes)" \
		    "$(kstat dbufstats cache_count)"
		sleep 1
	done >> "$out"/samples.tsv
}

# Only attach to symbols this module has, so a static function the
# compiler inlined does not abort the trace.
have() { grep -qw "$1" /proc/kallsyms; }

trace() {	# trace <tag>: bpftrace for the duration of one fio run
	command -v bpftrace >/dev/null 2>&1 || return 0
	prog=""
	if have arc_wait_for_eviction; then
		prog="$prog
kprobe:arc_wait_for_eviction { @wstart[tid] = nsecs; }
kretprobe:arc_wait_for_eviction /@wstart[tid]/ {
	@wait_us = hist((nsecs - @wstart[tid]) / 1000);
	@wait_n = count();
	@wait_sum_us = sum((nsecs - @wstart[tid]) / 1000);
	delete(@wstart[tid]);
}"
	fi
	if have arc_evict_hdr; then
		prog="$prog
kretprobe:arc_evict_hdr {
	@hdr[retval == 0 ? \"skipped\" : \"evicted\"] = count();
}"
	fi
	if have arc_evict_state; then
		prog="$prog
kprobe:arc_evict_state { @evict_state = count(); }"
	fi
	if [ -z "$prog" ]; then
		echo "no probes" > "$out/trace-$1.txt"
		return 0
	fi
	echo "$prog" > "$out/trace.bt"
	# The output belongs to the runner, as the rest of $out does.
	# shellcheck disable=SC2024
	sudo timeout $((SECS + 5)) bpftrace "$out/trace.bt" \
	    > "$out/trace-$1.txt" 2>&1 || true
}

fio_read() {	# fio_read <tag>
	sudo fio --name=r --filename=/evict1m/f --rw=read --bs=1M \
	    --numjobs=4 --size=4G --time_based --runtime=$SECS \
	    --group_reporting --write_bw_log="$out/bw-$1" \
	    --log_avg_msec=1000 --output-format=json |
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
	for s in arc_wait_for_eviction arc_evict_hdr arc_evict_state; do
		printf '%s\tsym:%s\t%s\n' "$label" "$s" \
		    "$(have "$s" && echo yes || echo no)"
	done
} >> "$out"/params.tsv

# 6G stays below the runner's 8G /dev/shm, which a file vdev must not
# reach: freed space is not returned to tmpfs.
sudo truncate -s 6G /dev/shm/evict1m
sudo "$src"/zpool create -f -O compression=off -O recordsize=1M \
    -O atime=off evict1m /dev/shm/evict1m
sudo dd if=/dev/urandom of=/evict1m/f bs=1M count=4096 status=none
sudo "$src"/zpool sync evict1m

round=1
while [ $round -le $ROUNDS ]; do
	for t in A A2; do
		tag="r$round-$t"
		rm -f "$out/stop"
		sampler "$tag" &
		spid=$!
		trace "$tag" &
		tpid=$!
		fio_read "$tag"
		touch "$out/stop"
		wait "$spid" || true
		wait "$tpid" || true
	done
	round=$((round + 1))
done
rm -f "$out/stop"

sudo "$src"/zpool destroy evict1m
sudo rm -f /dev/shm/evict1m

{
	echo "### evict1m $label (MiB/s per run)"
	cat "$out"/raw.tsv
} > "$out"/summary.md
