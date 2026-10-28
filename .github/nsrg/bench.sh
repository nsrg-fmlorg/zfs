#!/bin/sh
# bench.sh: fio A/B of this tree against $BASE (a git ref).
#
# Both trees are built here and their modules loaded in turn on the
# same runner, five rounds each, so runner-to-runner variance does not
# enter the comparison.  The pool sits in /dev/shm and the ARC is held
# well below the working set: the numbers are CPU bound and show the
# cost of the code path (eviction, copies, checksums), not of a disk.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=5
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

# One line per workload: mean, min and max over the rounds for base and
# head, and head/base of the means.  A ratio whose ranges overlap is
# noise: an A/A run of identical trees moved read:1M by 16%.
summarise() {
	git -C "$1" log -1 --format='base %h %s'
	git log -1 --format='head %h %s'
	echo
	printf 'workload\tbase mean\tbase min-max\thead mean\thead min-max\thead/base\n'
	awk -F'\t' '
	    {
		k = $2 SUBSEP $1
		sum[k] += $3; n[k]++; w[$2] = 1
		if (!(k in lo) || $3 < lo[k]) lo[k] = $3
		if (!(k in hi) || $3 > hi[k]) hi[k] = $3
	    }
	    END {
		for (x in w) {
			b = x SUBSEP "base"; h = x SUBSEP "head"
			mb = sum[b] / n[b]; mh = sum[h] / n[h]
			printf "%s\t%d\t%d-%d\t%d\t%d-%d\t%.3f\n", x,
			    mb, lo[b], hi[b], mh, lo[h], hi[h], mh / mb
		}
	    }' "$OUT"/raw.tsv
}

# Module options a branch needs to exercise its change, e.g. a thread
# count the runner's four CPUs would not pick by default.  Both trees
# get them; a parameter the base module lacks is ignored with a warning.
if [ -s .github/nsrg/bench-options ]; then
	echo "options zfs $(cat .github/nsrg/bench-options)" |
	    sudo tee /etc/modprobe.d/zfs-bench.conf
fi

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
