#!/bin/sh
# zvolbench.sh: throughput and ARC footprint of a zvol, master against
# this branch with direct=always, alternated on one runner, three rounds
# each.  QD=1 is one job at depth 1, QD=16 four jobs at depth 4.  fio
# opens the device O_DIRECT in both, so the page cache above the zvol is
# out of the picture and only the ARC differs.  The pool is reimported
# before each run, so the peaks are what that run brought in.  The pool
# sits in /dev/shm and the ARC is held below the volume, so these show
# the cost of the copy and the memory, not of a disk.  The "warm" sets
# fit in the ARC, the case Direct I/O is expected to lose.
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
BASETREE=/var/tmp/benchbase
ROUNDS=3
ARC_MAX=$((512 * 1024 * 1024))
# rw:bs:jobs:depth:span per job in MiB
WORKLOADS="randread:128k:1:1:3072 randread:128k:4:4:768
randread:128k:1:1:128 randread:128k:4:4:32
read:1M:1:1:3072 read:1M:4:4:768
randwrite:128k:1:1:3072 randwrite:128k:4:4:768
write:1M:1:1:3072 write:1M:4:4:768"
VOL=bench/vol
DEV=/dev/zvol/$VOL

arcstat() {
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/arcstats
}

iostat() {
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/bench/iostats
}

stuck() {
	echo "fio overran: $1 $2"
	free -m
	echo w | sudo tee /proc/sysrq-trigger >/dev/null
	sudo dmesg | tail -200
	exit 1
}

# Sample the ARC once a second while fio runs; print the two peaks.
peaks() {
	pd=0
	ps=0
	while [ -e "$OUT"/running ]; do
		v=$(arcstat data_size)
		[ "$v" -gt "$pd" ] && pd=$v
		v=$(arcstat size)
		[ "$v" -gt "$ps" ] && ps=$v
		sleep 1
	done
	echo "$pd $ps"
}

measure() {	# measure <label> <tree>
	for w in $WORKLOADS; do
		IFS=: read -r rw bs jobs depth span <<-EOF
		$w
		EOF
		# udev can still hold the device just after fio.
		udevadm settle
		n=0
		until sudo "$2"/zpool export bench; do
			n=$((n + 1))
			[ $n -lt 10 ] || exit 1
			sleep 2
		done
		sudo "$2"/zpool import -d /dev/shm bench
		udevadm settle
		dio=$(($(iostat direct_read_count) + $(iostat direct_write_count)))
		touch "$OUT"/running
		peaks > "$OUT"/peak &
		# The output is ours to read; only fio needs root.
		# shellcheck disable=SC2024
		sudo timeout 300 fio --name="$rw" --filename=$DEV --direct=1 \
		    --rw="$rw" --bs="$bs" --size="${span}M" --numjobs="$jobs" \
		    --offset_increment="${span}M" --iodepth="$depth" \
		    --ioengine=libaio --time_based --runtime=30 \
		    --group_reporting --output-format=json \
		    > "$OUT"/fio.json || stuck "$1" "$w"
		rm -f "$OUT"/running
		wait
		mib=$(jq '(.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
		    / 1048576 | floor' "$OUT"/fio.json)
		iops=$(jq '(.jobs[0].read.iops + .jobs[0].write.iops) | floor' \
		    "$OUT"/fio.json)
		dio=$(($(iostat direct_read_count) + $(iostat direct_write_count) -
		    dio))
		read -r pd ps < "$OUT"/peak
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$w" "$mib" "$iops" \
		    $((pd / 1048576)) $((ps / 1048576)) "$dio" >> "$OUT"/raw.tsv
	done
}

setup() {	# setup <tree> [zfs create options]
	t=$1
	shift
	"$HERE"/.github/nsrg/load.sh "$t"
	echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max \
	    >/dev/null
	sudo truncate -s 5G /dev/shm/vdev
	sudo "$t"/zpool create -f -O compression=off bench /dev/shm/vdev
	sudo "$t"/zfs create -V 3G -b 128K "$@" $VOL
	udevadm settle
	sudo dd if=/dev/urandom of=$DEV bs=1M count=3072 oflag=direct \
	    status=none
}

teardown() {	# teardown <tree>
	sudo "$1"/zpool destroy bench
	sudo rm -f /dev/shm/vdev
}

mkdir -p "$OUT"
git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master
git worktree add -q --detach "$BASETREE" "$(git merge-base HEAD upstream/master)"
"$HERE"/.github/nsrg/build.sh "$BASETREE" release
"$HERE"/.github/nsrg/build.sh "$HERE" release

i=0
while [ $i -lt $ROUNDS ]; do
	setup "$BASETREE"
	measure master "$BASETREE"
	teardown "$BASETREE"
	setup "$HERE" -o direct=always
	measure always "$HERE"
	teardown "$HERE"
	i=$((i + 1))
done

{
	git log -1 --format='head %h %s'
	echo "base $(git -C "$BASETREE" log -1 --format='%h %s')"
	echo
	echo "label workload MiB/s(mean) iops(mean) peak_data_MiB(max)" \
	    "peak_arc_MiB(max) direct_ios(mean)"
	awk -F'\t' '
	    {
		k = $1 " " $2
		m[k] += $3; o[k] += $4; n[k]++; d[k] += $7
		if ($5 > pd[k]) pd[k] = $5
		if ($6 > ps[k]) ps[k] = $6
	    }
	    END {
		for (k in n)
			printf "%s %d %d %d %d %d\n", k, m[k] / n[k],
			    o[k] / n[k], pd[k], ps[k], d[k] / n[k]
	    }' "$OUT"/raw.tsv | sort -k2,2 -k1,1
	echo
	cat "$OUT"/raw.tsv
} | tee "$OUT"/summary.tsv | tee -a "$GITHUB_STEP_SUMMARY"
