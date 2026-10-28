#!/bin/sh
# bench.sh: fio A/B of this tree against $BASE (a git ref).
#
# Both trees are built here and their modules loaded in turn on the
# same runner, five rounds each, so runner-to-runner variance does not
# enter the comparison.  The pool sits in /dev/shm and the ARC is held
# well below the working set: the numbers are CPU bound and show the
# cost of the code path (eviction, copies, checksums), not of a disk.
set -eu

# A branch that measures something other than an A/B names its own
# script in .github/nsrg/bench-script.
if [ -s .github/nsrg/bench-script ]; then
	exec "./.github/nsrg/$(cat .github/nsrg/bench-script)"
fi

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=5
ARC_MAX=$((512 * 1024 * 1024))
ARC_MIN=$((64 * 1024 * 1024))
WORKLOADS="randread:128k read:1M randwrite:128k"

build_base() {
	git remote get-url upstream >/dev/null 2>&1 ||
	    git remote add upstream https://github.com/openzfs/zfs.git
	git fetch -q upstream master
	git worktree add -q --detach "$1" "$BASE"
	"$HERE"/.github/nsrg/build.sh "$1" release
}

# A measurement that does not show the setting took effect proves
# nothing, so keep the values the module actually ran with and the
# eviction counters next to the numbers.
record_params() {
	for p in zfs_arc_max $(sed 's/=[^ ]*//g' .github/nsrg/bench-options \
	    2>/dev/null); do
		printf '%s\t%s\t%s\n' "$1" "$p" \
		    "$(cat /sys/module/zfs/parameters/"$p" 2>/dev/null ||
		    echo absent)"
	done >> "$OUT"/params.tsv
	awk -v l="$1" '$1 == "c_max" || $1 == "c_min" {
	    printf "%s\tarcstats.%s\t%s\n", l, $1, $3 }' \
	    /proc/spl/kstat/zfs/arcstats >> "$OUT"/params.tsv
	sudo dmesg | grep -iE 'unknown parameter|ignoring tunable' | tail -3 \
	    >> "$OUT"/params.tsv || true
}

record_kstats() {
	for k in arcstats dbufstats; do
		{
			echo "== $1 $k"
			cat /proc/spl/kstat/zfs/"$k"
		} >> "$OUT"/kstats.txt
	done
}

# measure <label> <srcdir>: one round, appends <label> <workload> <MiB/s>
measure() {
	label=$1
	src=$2
	"$HERE"/.github/nsrg/load.sh "$src"
	# arc.c ignores a zfs_arc_max that is not above arc_c_min, which
	# defaults to RAM/32: 512M on the runner's 16G, the very value used
	# here.  Lower the minimum first.  record_params then shows c_max,
	# the limit actually in force, next to the tunable.
	echo "$ARC_MIN" | sudo tee /sys/module/zfs/parameters/zfs_arc_min \
	    >/dev/null
	echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max \
	    >/dev/null
	record_params "$label"
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

	record_kstats "$label"
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

sort -u "$OUT"/params.tsv | tee -a "$GITHUB_STEP_SUMMARY"
summarise "$base" | tee "$OUT"/summary.tsv |
    column -t -s "$(printf '\t')" | tee -a "$GITHUB_STEP_SUMMARY"
