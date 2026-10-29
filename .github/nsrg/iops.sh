#!/bin/sh
# iops.sh: does 4k random IOPS scale with the number of vdevs?
#
# Pools of 1, 2 and 4 vdevs on RAM-backed block devices (brd if the
# runner kernel has it, else loop devices over /dev/shm), compared with
# fio on the same devices without ZFS.  scheduler=auto bypasses the vdev
# queue only for non-rotational block devices (vdev_should_queue_io()),
# so file vdevs would not show the bypass at all.  Results go to
# $OUT/iops.tsv: label, vdevs, scheduler, workload, round, IOPS.
set -eu

OUT=/var/tmp/iops
HERE=$(pwd)
NDEV=4
DEVSIZE_MB=2048
RUNTIME=15
ROUNDS=2
JOBS=$(nproc)
mkdir -p "$OUT"

setup_devices() {
	if sudo modprobe brd rd_nr=$NDEV rd_size=$((DEVSIZE_MB * 1024)) \
	    2>/dev/null && [ -b /dev/ram0 ]; then
		DEVS=$(seq 0 $((NDEV - 1)) | sed 's#^#/dev/ram#')
		echo "devices: brd" | tee -a "$OUT"/env
	else
		DEVS=
		for i in $(seq 0 $((NDEV - 1))); do
			sudo truncate -s "${DEVSIZE_MB}M" "/dev/shm/iops$i"
			DEVS="$DEVS $(sudo losetup -f --show "/dev/shm/iops$i")"
		done
		echo "devices: loop over /dev/shm" | tee -a "$OUT"/env
	fi
	for d in $DEVS; do
		b=$(basename "$d")
		echo "$d rotational=$(cat /sys/block/"$b"/queue/rotational)" |
		    tee -a "$OUT"/env
	done
}

# first <n>: the first n devices, space separated
first() {
	# shellcheck disable=SC2086
	printf '%s\n' $DEVS | head -n "$1" | tr '\n' ' '
}

# fio_iops <rw> <fio args...>: total IOPS of one run.  Defaults to
# libaio at iodepth 32 with one job per CPU; later arguments override.
fio_iops() {
	rw=$1
	shift
	sudo fio --name=t --rw="$rw" --bs=4k --iodepth=32 --ioengine=libaio \
	    --direct=1 --numjobs="$JOBS" --time_based --runtime=$RUNTIME \
	    --group_reporting --output-format=json "$@" |
	    jq '(.jobs[0].read.iops + .jobs[0].write.iops) | floor'
}


record() {	# record <label> <vdevs> <sched> <rw> <round> <iops>
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" | tee -a "$OUT"/iops.tsv
}

raw_baseline() {
	for n in 1 2 4; do
		files=$(first $n | sed 's/ $//; s/ /:/g')
		for rw in randread randwrite; do
			r=1
			while [ $r -le $ROUNDS ]; do
				record raw $n - $rw $r "$(fio_iops $rw \
				    --filename="$files")"
				r=$((r + 1))
			done
		done
	done
}

# Whether ZFS completes libaio requests before io_submit() returns, which
# would hold every job to one I/O in flight whatever iodepth says: sweep
# the depth and the number of jobs, on the raw devices first and on ZFS
# afterwards (never both at once: raw writes would overwrite the pool),
# and count context switches per I/O.
concurrency_raw() {
	raw4=$(first $NDEV | sed 's/ $//; s/ /:/g')
	for jobs in 4 16 64; do
		for qd in 1 32; do
			for rw in randread randwrite; do
				record conc_raw $NDEV "j$jobs" "$rw/qd$qd" 1 \
				    "$(fio_iops $rw --filename="$raw4" \
				    --numjobs=$jobs --iodepth=$qd --thread)"
			done
		done
	done
}

concurrency_zfs() {
	# shellcheck disable=SC2046
	sudo "$HERE"/zpool create -f -o ashift=12 -O compression=off \
	    -O primarycache=metadata -O recordsize=4k -O atime=off \
	    iops $(first $NDEV)
	sudo fio --name=t --directory=/iops --size=64M --numjobs=64 \
	    --rw=write --bs=1M --end_fsync=1 >/dev/null
	for jobs in 4 16 64; do
		for qd in 1 32; do
			for rw in randread randwrite; do
				record conc_zfs $NDEV "j$jobs" "$rw/qd$qd" 1 \
				    "$(fio_iops $rw --directory=/iops \
				    --size=64M --numjobs=$jobs --iodepth=$qd \
				    --thread)"
			done
		done
	done
	for rw in randread randwrite; do
		sudo perf stat -a -e context-switches -x, -o "$OUT"/cs-$rw.txt \
		    -- sleep 10 &
		n=$(fio_iops $rw --directory=/iops --size=64M --numjobs=64 \
		    --iodepth=1 --thread --runtime=12)
		wait
		cs=$(sudo grep context-switches "$OUT"/cs-$rw.txt | cut -d, -f1)
		sudo chmod a+r "$OUT"/cs-$rw.txt
		echo "$rw j64 qd1: $n IOPS, $cs context switches in 10s," \
		    "$((cs / (n * 10 + 1))) per I/O" | tee -a "$OUT"/env
	done
	sudo "$HERE"/zpool destroy iops
}

# zfs_run <label> <vdevs> <scheduler>
zfs_run() {
	label=$1 n=$2 sched=$3
	# shellcheck disable=SC2046
	sudo "$HERE"/zpool create -f -o ashift=12 -O compression=off \
	    -O primarycache=metadata -O recordsize=4k -O atime=off \
	    iops $(first "$n")
	for d in $(first "$n"); do
		sudo "$HERE"/zpool set scheduler="$sched" iops "$d"
	done
	sudo fio --name=t --directory=/iops --size=$((1024 / JOBS))M \
	    --numjobs="$JOBS" --rw=write --bs=1M --end_fsync=1 >/dev/null
	for rw in randread randwrite; do
		r=1
		while [ $r -le $ROUNDS ]; do
			record "$label" "$n" "$sched" $rw $r "$(fio_iops $rw \
			    --directory=/iops --size=$((1024 / JOBS))M)"
			r=$((r + 1))
		done
	done
	sudo "$HERE"/zpool destroy iops
}

# Count vdev_should_queue_io() answers during one run, to see whether
# scheduler=auto really bypasses the queue on these devices.
bypass_check() {
	command -v bpftrace >/dev/null || { echo "no bpftrace" >> "$OUT"/env; return 0; }
	# shellcheck disable=SC2046
	sudo "$HERE"/zpool create -f -o ashift=12 -O compression=off \
	    -O primarycache=metadata -O recordsize=4k iops $(first $NDEV)
	sudo fio --name=t --directory=/iops --size=$((1024 / JOBS))M \
	    --numjobs="$JOBS" --rw=write --bs=1M --end_fsync=1 >/dev/null
	# The output files belong to the runner user; only the tools need root.
	# shellcheck disable=SC2024
	sudo timeout 20 bpftrace -e 'kretprobe:vdev_should_queue_io
	    { @queued[retval] = count(); }' > "$OUT"/bypass.txt 2>&1 &
	sleep 3
	fio_iops randread --directory=/iops --size=$((1024 / JOBS))M >/dev/null
	wait
	sudo "$HERE"/zpool destroy iops
}

# Profile the 4-vdev randread under the default scheduler.
profile() {
	# shellcheck disable=SC2046
	sudo "$HERE"/zpool create -f -o ashift=12 -O compression=off \
	    -O primarycache=metadata -O recordsize=4k iops $(first $NDEV)
	sudo fio --name=t --directory=/iops --size=$((1024 / JOBS))M \
	    --numjobs="$JOBS" --rw=write --bs=1M --end_fsync=1 >/dev/null
	for rw in randread randwrite; do
		sudo fio --name=t --rw=$rw --bs=4k --iodepth=32 \
		    --ioengine=libaio --direct=1 --numjobs="$JOBS" \
		    --time_based --runtime=40 --directory=/iops \
		    --size=$((1024 / JOBS))M >/dev/null &
		sleep 5
		sudo perf record -a -g -F 499 -o "$OUT"/perf-$rw.data \
		    -- sleep 10 >/dev/null 2>&1 || true
		sudo perf report -i "$OUT"/perf-$rw.data --no-children \
		    --sort symbol --stdio 2>/dev/null | grep -v '^#' |
		    grep '%' | head -40 > "$OUT"/perf-$rw.txt || true
		sudo rm -f "$OUT"/perf-$rw.data
		wait
	done
	sudo "$HERE"/zpool destroy iops
}

# Load-time zio taskq variants, 4 vdevs, default scheduler.
taskq_variants() {
	for pct in 50 100; do
		echo "options zfs zio_taskq_batch_pct=$pct" |
		    sudo tee /etc/modprobe.d/zfs-iops.conf >/dev/null
		"$HERE"/.github/nsrg/load.sh "$HERE"
		zfs_run "taskq_pct$pct" 4 auto
	done
	sudo rm -f /etc/modprobe.d/zfs-iops.conf
	"$HERE"/.github/nsrg/load.sh "$HERE"
}

setup_devices
raw_baseline
concurrency_raw
"$HERE"/.github/nsrg/load.sh "$HERE"
echo $((1024 * 1024 * 1024)) |
    sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
zfs_run aa 4 auto		# A/A partner of the zfs/4/auto row below
# Runs 1 and 2 found scheduler=on/off within 3% of auto; keep auto only.
for n in 1 2 4; do
	zfs_run zfs "$n" auto
done
concurrency_zfs
bypass_check
profile
taskq_variants

# Summary: mean and min-max IOPS per row.
awk -F'\t' '
    { k = $1 "\t" $2 "\t" $3 "\t" $4; s[k] += $6; c[k]++
      if (!(k in lo) || $6 < lo[k]) lo[k] = $6
      if (!(k in hi) || $6 > hi[k]) hi[k] = $6 }
    END { for (k in s) printf "%s\t%d\t%d-%d\n", k, s[k] / c[k], lo[k], hi[k] }' \
    "$OUT"/iops.tsv | sort > "$OUT"/summary.tsv
{
	cat "$OUT"/env
	printf '\nlabel\tvdevs\tsched\tworkload\tmean IOPS\tmin-max\n'
	cat "$OUT"/summary.tsv
	echo; echo "== vdev_should_queue_io() return values"; cat "$OUT"/bypass.txt 2>/dev/null
	for rw in randread randwrite; do
		echo; echo "== perf $rw"; head -25 "$OUT"/perf-$rw.txt 2>/dev/null
	done
} | tee -a "$GITHUB_STEP_SUMMARY"
