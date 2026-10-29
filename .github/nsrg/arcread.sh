#!/bin/sh
# arcread.sh: what the ARC range read saves on small reads of large
# records that the ARC holds but the dbuf cache does not.
#
# The comparison is made inside one module by flipping dmu_arc_range_read,
# so no runner or build difference enters it; "off-aa" repeats "off" to
# show the noise, and "base" runs upstream master once as a sanity check
# that "off" is the old behaviour.  The ARC is sized to hold the whole
# working set while the dbuf cache (a 32nd of it) cannot.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/bench/arcread
HERE=$(pwd)
ROUNDS=3
ARC_MIN=$((64 * 1024 * 1024))
ARC_MAX=$((4 * 1024 * 1024 * 1024))
FILESZ=2G
P=/sys/module/zfs/parameters

mkdir -p "$OUT"
git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master
base=$(mktemp -d /var/tmp/base.XXXXXX)
git worktree add -q --detach "$base" "$BASE"
"$HERE"/.github/nsrg/build.sh "$base" release
"$HERE"/.github/nsrg/build.sh "$HERE" release

setup() {	# setup <srcdir>
	"$HERE"/.github/nsrg/load.sh "$1"
	# arc.c ignores a zfs_arc_max that is not above arc_c_min.
	echo $ARC_MIN | sudo tee $P/zfs_arc_min >/dev/null
	echo $ARC_MAX | sudo tee $P/zfs_arc_max >/dev/null
	sudo truncate -s 6G /dev/shm/vdev
	sudo "$1"/zpool create -f -O compression=off -O recordsize=128k \
	    -O atime=off arcread /dev/shm/vdev
	sudo fio --name=fill --filename=/arcread/f --size=$FILESZ \
	    --rw=write --bs=1M --end_fsync=1 >/dev/null
	# Pull the file into the ARC; the dbuf cache keeps only a tail of it.
	sudo fio --name=warm --filename=/arcread/f --size=$FILESZ \
	    --rw=read --bs=1M >/dev/null
}

teardown() {	# teardown <srcdir>
	sudo "$1"/zpool destroy arcread
	sudo rm -f /dev/shm/vdev
}

kstat() {	# kstat <file> <name>
	awk -v n="$2" '$1 == n { print $3 }' /proc/spl/kstat/zfs/"$1"
}

run() {	# run <label>
	h0=$(kstat arcstats hits)
	m0=$(kstat arcstats misses)
	bw=$(sudo fio --name=rr --filename=/arcread/f --size=$FILESZ \
	    --rw=randread --bs=4k --numjobs=4 --ioengine=psync \
	    --time_based --runtime=15 --group_reporting \
	    --output-format=json | jq '.jobs[0].read.iops | floor')
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$bw" \
	    "$(kstat arcstats overhead_size)" \
	    "$(kstat dbufstats cache_size_bytes)" \
	    $(($(kstat arcstats hits) - h0)) \
	    $(($(kstat arcstats misses) - m0)) >> "$OUT"/raw.tsv
}

setup "$HERE"
echo "c_max $(kstat arcstats c_max)" > "$OUT"/params.txt
i=0
while [ $i -lt $ROUNDS ]; do
	for mode in off on off-aa; do
		case $mode in
		on)	v=1 ;;
		*)	v=0 ;;
		esac
		echo $v | sudo tee $P/dmu_arc_range_read >/dev/null
		run $mode
	done
	i=$((i + 1))
done
teardown "$HERE"

setup "$base"
echo "base c_max $(kstat arcstats c_max)" >> "$OUT"/params.txt
i=0
while [ $i -lt $ROUNDS ]; do
	run base
	i=$((i + 1))
done
teardown "$base"

{
	cat "$OUT"/params.txt
	printf 'mode\tIOPS mean\tIOPS min-max\toverhead_size\tdbuf cache\tARC hits\tARC misses\n'
	awk -F'\t' '
	    {
		k = $1; n[k]++; s[k] += $2; o[k] = $3; d[k] = $4
		hit[k] += $5; mis[k] += $6
		if (!(k in lo) || $2 < lo[k]) lo[k] = $2
		if (!(k in hi) || $2 > hi[k]) hi[k] = $2
	    }
	    END {
		for (k in n)
			printf "%s\t%d\t%d-%d\t%d\t%d\t%d\t%d\n", k,
			    s[k] / n[k], lo[k], hi[k], o[k], d[k],
			    hit[k] / n[k], mis[k] / n[k]
	    }' "$OUT"/raw.tsv
} | tee "$OUT"/summary.tsv | column -t -s "$(printf '\t')" |
    tee -a "$GITHUB_STEP_SUMMARY"
