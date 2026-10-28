#!/bin/sh
# zvolbench.sh: throughput and ARC footprint of a zvol under
# direct=standard and direct=always, alternated on one build and one
# runner, three rounds each.  fio opens the device O_DIRECT in both, so
# the page cache above the zvol is out of the picture and only the ARC
# differs.  The pool is reimported before each run, so the peak of
# data_size is what that run brought into the ARC, and the Direct I/O
# counters show which path served it.  The pool sits in /dev/shm and
# the ARC is held below the volume, so the numbers show the cost of the
# copy, not of a disk.
#
# The runner has 16G.  A first version with a 10G vdev and a 6G volume
# stalled in randwrite under direct=standard; sizes are halved, and an
# fio that overruns is killed with the blocked tasks and memory logged.
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=3
ARC_MAX=$((512 * 1024 * 1024))
WORKLOADS="randread:128k read:1M randwrite:128k write:1M"
VOL=bench/vol
DEV=/dev/zvol/$VOL

arcstat() {
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/arcstats
}

iostat() {
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/bench/iostats
}

# Export and import, so that the ARC holds nothing of the pool and the
# peak below is what this run alone brought in.
reimport() {
	sudo "$HERE"/zpool export bench
	sudo "$HERE"/zpool import -d /dev/shm bench
	udevadm settle
}

# Log what is stuck: blocked tasks, memory, the tail of dmesg.
stuck() {
	echo "fio overran: direct=$1 $2"
	free -m
	echo w | sudo tee /proc/sysrq-trigger >/dev/null
	sudo dmesg | tail -200
	exit 1
}

# Sample data_size once a second while fio runs; print the peak.
peak_data_size() {
	peak=0
	while [ -e "$OUT"/running ]; do
		v=$(arcstat data_size)
		[ "$v" -gt "$peak" ] && peak=$v
		sleep 1
	done
	echo "$peak"
}

measure() {	# measure <direct value>
	sudo "$HERE"/zfs set direct="$1" $VOL
	for w in $WORKLOADS; do
		rw=${w%:*}
		bs=${w#*:}
		reimport
		dio=$(($(iostat direct_read_count) + $(iostat direct_write_count)))
		touch "$OUT"/running
		peak_data_size > "$OUT"/peak &
		echo "direct=$1 $w"
		# The output is ours to read; only fio needs root.
		# shellcheck disable=SC2024
		sudo timeout 300 fio --name="$rw" --filename=$DEV --direct=1 \
		    --rw="$rw" --bs="$bs" --size=768M --numjobs=4 \
		    --offset_increment=768M --iodepth=16 --ioengine=libaio \
		    --time_based --runtime=30 --group_reporting \
		    --output-format=json > "$OUT"/fio.json || stuck "$1" "$w"
		rm -f "$OUT"/running
		wait
		mib=$(jq '(.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
		    / 1048576 | floor' "$OUT"/fio.json)
		dio=$(($(iostat direct_read_count) + $(iostat direct_write_count) -
		    dio))
		printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$w" "$mib" \
		    $(($(cat "$OUT"/peak) / 1048576)) "$dio" >> "$OUT"/raw.tsv
	done
}

mkdir -p "$OUT"
"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
sudo truncate -s 5G /dev/shm/vdev
sudo "$HERE"/zpool create -f -O compression=off bench /dev/shm/vdev
sudo "$HERE"/zfs create -V 3G -b 128K $VOL
udevadm settle
sudo dd if=/dev/urandom of=$DEV bs=1M count=3072 oflag=direct status=none
free -m

i=0
while [ $i -lt $ROUNDS ]; do
	measure standard
	measure always
	i=$((i + 1))
done

{
	git log -1 --format='head %h %s'
	echo
	printf 'workload\tstandard MiB/s\talways MiB/s\talways/standard'
	printf '\tstandard peak data_size MiB\talways peak data_size MiB\n'
	awk -F'\t' '
	    {
		k = $2 SUBSEP $1
		bw[k] += $3; n[k]++; w[$2] = 1
		if ($4 > pk[k]) pk[k] = $4
	    }
	    END {
		for (x in w) {
			s = x SUBSEP "standard"; a = x SUBSEP "always"
			ms = bw[s] / n[s]; ma = bw[a] / n[a]
			printf "%s\t%d\t%d\t%.3f\t%d\t%d\n", x, ms, ma,
			    ma / ms, pk[s], pk[a]
		}
	    }' "$OUT"/raw.tsv
	echo
	echo "per round (value, workload, MiB/s, peak data_size MiB," \
	    "direct I/Os):"
	cat "$OUT"/raw.tsv
} | tee "$OUT"/summary.tsv | tee -a "$GITHUB_STEP_SUMMARY"
