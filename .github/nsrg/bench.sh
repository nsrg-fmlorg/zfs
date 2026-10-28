#!/bin/sh
# bench.sh: fio A/B of this tree against $BASE (a git ref).
#
# Both trees are built here and their modules loaded in turn on the
# same runner, three rounds each, so runner-to-runner variance does not
# enter the comparison.  The pool sits in /dev/shm and the ARC is held
# well below the working set: the numbers are CPU bound and show the
# cost of the code path (eviction, copies, checksums), not of a disk.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=3
ARC_MAX=$((512 * 1024 * 1024))
WORKLOADS="randread:128k read:1M randwrite:128k"

build_base() {
	git remote get-url upstream >/dev/null 2>&1 ||
	    git remote add upstream https://github.com/openzfs/zfs.git
	git fetch -q upstream master
	git worktree add -q --detach "$1" "$BASE"
	"$HERE"/.github/nsrg/build.sh "$1" release
}

# measure <label> <srcdir>: one round, appends <label> <workload> <MiB/s>
measure() {
	label=$1
	src=$2
	"$HERE"/.github/nsrg/load.sh "$src"
	echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max \
	    >/dev/null
	sudo truncate -s 8G /dev/shm/vdev
	sudo "$src"/zpool create -f -O compression=off -O recordsize=1M \
	    -O atime=off bench /dev/shm/vdev
	sudo fio --name=fill --directory=/bench --size=4G --rw=write \
	    --bs=1M --end_fsync=1 >/dev/null

	for w in $WORKLOADS; do
		rw=${w%:*}
		bs=${w#*:}
		sudo fio --name="$rw" --directory=/bench \
		    --filename=fill.0.0 --size=4G --rw="$rw" --bs="$bs" \
		    --numjobs=4 --time_based --runtime=30 --group_reporting \
		    --output-format=json |
		    jq -r --arg l "$label" --arg w "$w" '[$l, $w,
		    ((.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
		    / 1048576 | floor)] | @tsv' >> "$OUT"/raw.tsv
	done

	sudo "$src"/zpool destroy bench
	sudo rm -f /dev/shm/vdev
}

summarise() {
	git -C "$1" log -1 --format='base %h %s'
	git log -1 --format='head %h %s'
	echo
	printf 'workload\tbase MiB/s\thead MiB/s\thead/base\n'
	awk -F'\t' '
	    { sum[$2, $1] += $3; n[$2, $1]++; w[$2] = 1 }
	    END {
		for (k in w) {
			b = sum[k, "base"] / n[k, "base"]
			h = sum[k, "head"] / n[k, "head"]
			printf "%s\t%d\t%d\t%.3f\n", k, b, h, h / b
		}
	    }' "$OUT"/raw.tsv
}

mkdir -p "$OUT"
base=$(mktemp -d /var/tmp/base.XXXXXX)
build_base "$base"
"$HERE"/.github/nsrg/build.sh "$HERE" release

i=0
while [ $i -lt $ROUNDS ]; do
	measure base "$base"
	measure head "$HERE"
	i=$((i + 1))
done

summarise "$base" | tee "$OUT"/summary.tsv |
    column -t -s "$(printf '\t')" | tee -a "$GITHUB_STEP_SUMMARY"
