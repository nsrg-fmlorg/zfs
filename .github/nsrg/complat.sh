#!/bin/sh
# complat.sh: what compression costs in I/O latency on fast media.
#
# For compression off, lz4 and zstd-3, data of 0% and 50% compressibility,
# and two backing stores (/dev/shm, which shows only the CPU cost, and a
# file on the runner's disk), measure clat mean, p99 and p99.9:
#
#   a  randread and randwrite, bs=4k, iodepth=1, recordsize=16k
#      (a 4k record cannot shrink below one 4k sector at ashift=12, so
#      16k is the smallest record where 50% data is stored smaller; the
#      randwrite is therefore a read-modify-write of a 16k record)
#   b  randread and randwrite, bs=128k, iodepth=32, recordsize=128k,
#      bandwidth recorded too
#
# Reads must not be served from the ARC, or the decompression cost is
# hidden: every dataset has primarycache=metadata.  The ioengine is
# io_uring, which hands blocking ZFS I/O to workers, so iodepth=32 is
# real concurrency.  "off2" repeats "off" as an A/A control.
#
# Neither store is NVMe; the numbers show a trend, not NVMe latency.
set -eu

OUT=/var/tmp/complat
HERE=$(pwd)
ROUNDS=3
SIZE=2G
RUNTIME=10
COMPS="off off2 lz4 zstd-3"
PCTS="0 50"
STORES="shm disk"
mkdir -p "$OUT"

vdev_path() {
	case $1 in
	shm)	echo /dev/shm/vdev ;;
	disk)	echo /mnt/vdev ;;
	esac
}

pool_create() {	# pool_create <store> <comp> <recordsize>
	v=$(vdev_path "$1")
	sudo truncate -s 8G "$v"
	c=$2
	[ "$c" = off2 ] && c=off
	sudo ./zpool create -f -o ashift=12 -O compression="$c" \
	    -O recordsize="$3" -O atime=off -O primarycache=metadata \
	    bench "$v"
}

pool_destroy() {	# pool_destroy <store>
	sudo ./zpool destroy bench
	sudo rm -f "$(vdev_path "$1")"
}

datafio() {	# datafio <pct> <args...>: fio with data of that compressibility
	pct=$1
	shift
	sudo fio --directory=/bench --filename=data --size=$SIZE \
	    --refill_buffers --buffer_compress_percentage="$pct" \
	    --buffer_compress_chunk=4k "$@"
}

# run <round> <store> <comp> <pct> <set> <rw> <bs> <depth>
run() {
	j="$OUT/$1.$2.$3.$4.$5.$6.json"
	# The JSON goes to a file we own, so the redirect is meant to be ours.
	# shellcheck disable=SC2024
	datafio "$4" --name="$6" --rw="$6" --bs="$7" --iodepth="$8" \
	    --ioengine=io_uring --time_based --runtime=$RUNTIME \
	    --output-format=json > "$j"
	d="read"
	[ "$6" = randwrite ] && d="write"
	jq -r --arg k "$2	$3	$4	$5	$6" --arg d "$d" '
	    .jobs[0][$d] as $x | [$k,
	    ($x.clat_ns.mean / 1000 | floor),
	    ($x.clat_ns.percentile["99.000000"] / 1000 | floor),
	    ($x.clat_ns.percentile["99.900000"] / 1000 | floor),
	    ($x.bw_bytes / 1048576 | floor)] | @tsv' "$j" >> "$OUT"/raw.tsv
}

"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
fio --version | tee "$OUT"/env.txt
uname -r | tee -a "$OUT"/env.txt
: > "$OUT"/raw.tsv

r=1
while [ $r -le $ROUNDS ]; do
	for st in $STORES; do
		for c in $COMPS; do
			for p in $PCTS; do
				for set in a b; do
					rs=16k; bs=4k; qd=1
					[ $set = b ] && { rs=128k; bs=128k; qd=32; }
					pool_create "$st" "$c" "$rs"
					datafio "$p" --name=fill --rw=write \
					    --bs=1M --end_fsync=1 >/dev/null
					sudo ./zpool export bench
					sudo ./zpool import -d "$(dirname \
					    "$(vdev_path "$st")")" bench
					run $r "$st" "$c" "$p" $set randread \
					    $bs $qd
					run $r "$st" "$c" "$p" $set randwrite \
					    $bs $qd
					sudo ./zfs get -H -o value \
					    compressratio bench |
					    sed "s/^/$st $c $p $set ratio /" \
					    >> "$OUT"/ratio.txt
					pool_destroy "$st"
				done
			done
		done
	done
	r=$((r + 1))
done

# Per store/comp/pct/set/rw: mean and min-max over rounds of each column.
awk -F'\t' '{
	k = $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
	n[k]++
	for (i = 6; i <= 9; i++) {
		s[k, i] += $i
		if (!((k, i) in lo) || $i < lo[k, i]) lo[k, i] = $i
		if (!((k, i) in hi) || $i > hi[k, i]) hi[k, i] = $i
	}
    }
    END {
	print "store\tcomp\tpct\tset\trw\tmean us\tp99 us\tp99.9 us\tMiB/s"
	for (k in n) {
		line = k
		for (i = 6; i <= 9; i++)
			line = line sprintf("\t%d (%d-%d)", s[k, i] / n[k],
			    lo[k, i], hi[k, i])
		print line
	}
    }' "$OUT"/raw.tsv | sort | tee "$OUT"/summary.tsv |
    column -t -s "$(printf '\t')" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
