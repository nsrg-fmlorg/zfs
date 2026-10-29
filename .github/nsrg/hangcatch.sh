#!/bin/sh
# hangcatch.sh: find which configuration hangs, and capture the state.
#
# Run 40863141972 stopped for five hours in dioresidue.sh on
# direct=always + dedup=on, fio seqwrite 1M, with the ARC frozen at 50M
# eight seconds in.  Each case here runs under a deadline; on overrun the
# kernel and pool state is captured and the script stops, since a pool
# stuck in D state cannot be destroyed for the next case.
#
# Run 40912641885 showed the hang needs dedup, not Direct I/O: with
# primarycache=metadata it stopped too, the pool SUSPENDED after a MOS
# write failed with ENOSPC while the leaf vdev reported no errors.  Pool
# space and the dedup log are now sampled to see how the pool fills.
# The zvol case, which an earlier branch saw stall under memory pressure
# on the unchanged path, runs first so the dedup hang cannot hide it.
# Output goes under $OUT, owned by the runner, so redirects of sudo'ed
# commands are meant to be done as the runner.
# shellcheck disable=SC2024
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
ARC_MIN=$((64 * 1024 * 1024))
ARC_MAX=$((1024 * 1024 * 1024))
SIZE=2G
RUNTIME=15
LIMIT=$((RUNTIME + 120))
# name|pool properties|fio options|vdev size|target (file or zvol)
CASES="
zvol_standard_pressure|-O compression=off|--rw=randwrite --bs=128k --direct=1|10G|zvol
dedup_metadata|-O primarycache=metadata -O dedup=on -O compression=off|--rw=write --bs=1M|6G|file
"
mkdir -p "$OUT"

capture() {	# capture <case>: state of a run that overran its deadline
	d="$OUT/hang.$1"
	mkdir -p "$d"
	echo 1 | sudo tee /proc/sys/kernel/sysrq >/dev/null
	echo w | sudo tee /proc/sysrq-trigger >/dev/null
	echo t | sudo tee /proc/sysrq-trigger >/dev/null
	sleep 2
	sudo dmesg > "$d/dmesg.txt"
	for p in /proc/[0-9]*; do
		st=$(awk '/^State:/ { print $2 }' "$p/status" 2>/dev/null) ||
		    continue
		[ "$st" = D ] || continue
		{
			echo "== $p $(cat "$p/comm" 2>/dev/null)"
			sudo cat "$p/stack" 2>/dev/null
		} >> "$d/dstate-stacks.txt"
	done
	for k in arcstats dbufstats dbgmsg; do
		sudo cat /proc/spl/kstat/zfs/$k > "$d/$k.txt" 2>&1 || true
	done
	sudo cat /proc/spl/kstat/zfs/bench/txgs > "$d/txgs.txt" 2>&1 || true
	sudo cat /proc/spl/kstat/zfs/bench/iostats > "$d/iostats.txt" 2>&1 ||
	    true
	timeout 30 sudo ./zpool events -v > "$d/events.txt" 2>&1 || true
	timeout 30 sudo ./zpool status -v > "$d/status.txt" 2>&1 || true
	free -m > "$d/free.txt"
	cat /proc/meminfo > "$d/meminfo.txt"
	echo "HANG in case $1, state in $d" | tee -a "$GITHUB_STEP_SUMMARY"
}

# deadline <secs> <cmd...>: run cmd, return 1 if it is still running
# after secs.  A process in D state ignores SIGKILL and timeout(1) would
# wait for it, so the wait is counted here and the process left behind.
deadline() {
	secs=$1
	shift
	"$@" &
	pid=$!
	i=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ $i -ge "$secs" ]; then
			return 1
		fi
		sleep 1
		i=$((i + 1))
	done
	wait "$pid"
}

# spacewatch <case>: pool space and dedup log size twice a second, so a
# pool that fills shows how fast and whether frees keep up.
spacewatch() {
	while :; do
		printf '%s\t%s\t%s\n' "$(date +%s.%N | cut -c1-14)" \
		    "$(sudo ./zpool list -Hp -o alloc,free bench 2>/dev/null |
		    tr '\t' ' ')" \
		    "$(sudo sh -c 'cat /proc/spl/kstat/zfs/bench/ddt_stats_* \
		    2>/dev/null' | awk '$1 ~ /^dds_log_(active|flushing)_entries$/ ||
		    $1 == "dds_log_flush_rate" { printf "%s=%s ", $1, $3 }')"
		sleep 0.5
	done >> "$OUT/$1.space.tsv"
}

dio_counts() {	# iostats is readable by root only
	sudo cat /proc/spl/kstat/zfs/bench/iostats 2>/dev/null | awk '
	    $1 == "direct_read_count" { r = $3 }
	    $1 == "direct_write_count" { w = $3 }
	    END { printf "%d %d", r, w }'
}

run_case() {	# run_case <name> <props> <fio opts> <vdev size> <target>
	name=$1 props=$2 opts=$3 vsize=$4 target=$5
	sudo truncate -s "$vsize" /dev/shm/vdev
	# shellcheck disable=SC2086
	sudo ./zpool create -f $props -O recordsize=128k bench /dev/shm/vdev
	if [ "$target" = zvol ]; then
		sudo ./zfs create -V 3G -o volblocksize=16k bench/vol
		sudo udevadm settle
		where="--filename=/dev/zvol/bench/vol --size=3G"
	else
		if ! deadline 600 sudo fio --name=fill --directory=/bench \
		    --filename=data --size=$SIZE --rw=write --bs=1M \
		    --buffer_compress_percentage=50 --refill_buffers \
		    --end_fsync=1 --output="$OUT/$name.fill.txt"; then
			capture "$name.fill"
			return 1
		fi
		where="--directory=/bench --filename=data --size=$SIZE"
	fi
	before=$(dio_counts)
	spacewatch "$name" &
	swpid=$!
	# shellcheck disable=SC2086
	if ! deadline $LIMIT sudo fio --name="$name" $where \
	    --numjobs=1 --iodepth=1 --time_based --runtime=$RUNTIME \
	    --buffer_compress_percentage=50 --refill_buffers \
	    --output-format=json --output="$OUT/$name.json" $opts; then
		kill "$swpid" 2>/dev/null || true
		capture "$name"
		return 1
	fi
	kill "$swpid" 2>/dev/null || true
	after=$(dio_counts)
	bw=$(jq '((.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
	    / 1048576) | floor' "$OUT/$name.json")
	# shellcheck disable=SC2086
	set -- $before $after
	printf '%s\t%s\t%s\t%s\n' "$name" "$bw" "$(($3 - $1))" "$(($4 - $2))" |
	    tee -a "$OUT"/cases.tsv
	sudo ./zpool destroy bench
	sudo rm -f /dev/shm/vdev
}

"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
echo "$ARC_MIN" | sudo tee /sys/module/zfs/parameters/zfs_arc_min >/dev/null
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
{
	git log -1 --format='tree %h %s'
	uname -r
	free -m
	awk '$1 == "c_min" || $1 == "c_max" { print "arcstats." $1, $3 }' \
	    /proc/spl/kstat/zfs/arcstats
} | tee "$OUT"/env.txt
printf 'case\tMiB/s\tdio_reads\tdio_writes\n' > "$OUT"/cases.tsv

echo "$CASES" | while IFS='|' read -r name props opts vsize target; do
	[ -n "$name" ] || continue
	echo "== $name: $props / $opts / $target"
	run_case "$name" "$props" "$opts" "$vsize" "$target" || exit 1
done
