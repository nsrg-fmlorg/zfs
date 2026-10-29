#!/bin/sh
# dioresidue.sh: what still lands in the ARC when a dataset bypasses it.
#
# For direct=always and primarycache=metadata, each workload runs on a
# fresh pool and arcstats/dbufstats are sampled every second, as in
# memprofile.sh.  Every ARC component is kept, peak and at the end, so
# the remainder can be split by cause.  The pool's own iostats show
# whether Direct I/O was taken at all.  "plain" under direct=always runs
# twice per round as the A/A control.
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=2
ARC_MIN=$((64 * 1024 * 1024))
ARC_MAX=$((1024 * 1024 * 1024))
SIZE=2G
RUNTIME=15
MODES="direct_always pc_metadata"
FEATURES="plain plain2 lz4 enc dedup"
# name:fio options; recordsize is 128k throughout
WORKLOADS="
seqwrite1M:--rw=write --bs=1M
seqread1M:--rw=read --bs=1M
randwrite128k:--rw=randwrite --bs=128k
randread128k:--rw=randread --bs=128k
misread:--rw=randread --bs=128k --blockalign=4k --offset=2k
rw4k:--rw=randwrite --bs=4k
mmapread:--rw=randread --bs=128k --ioengine=mmap
syncwrite128k:--rw=randwrite --bs=128k --sync=1
"
STATS="size data_size metadata_size dbuf_size dnode_size hdr_size
    l2_hdr_size bonus_size abd_chunk_waste_size"
mkdir -p "$OUT"

arcstat() {	# arcstat <file> <stat>
	awk -v k="$2" '$1 == k { print $3 }' "$1"
}

sample() {	# sample <file>: one line of all STATS per second
	while :; do
		cp /proc/spl/kstat/zfs/arcstats "$1.now"
		line=""
		for s in $STATS; do
			line="$line $(arcstat "$1.now" "$s")"
		done
		line="$line $(awk '$1 == "cache_size_bytes" { print $3 }' \
		    /proc/spl/kstat/zfs/dbufstats)"
		echo "$line" >> "$1"
		sleep 1
	done
}

pool_create() {	# pool_create <mode> <feature>
	sudo truncate -s 6G /dev/shm/vdev
	props="-O recordsize=128k -O atime=off"
	case $1 in
	direct_always)	props="$props -O direct=always" ;;
	pc_metadata)	props="$props -O primarycache=metadata" ;;
	esac
	case $2 in
	plain|plain2)	props="$props -O compression=off" ;;
	lz4)		props="$props -O compression=lz4" ;;
	enc)		props="$props -O compression=off -O encryption=on
			    -O keyformat=passphrase
			    -O keylocation=file:///var/tmp/bench.key" ;;
	dedup)		props="$props -O compression=off -O dedup=on" ;;
	esac
	# shellcheck disable=SC2086
	sudo ./zpool create -f $props bench /dev/shm/vdev
}

dio_counts() {	# direct read and write counts of the pool
	awk '$1 == "direct_read_count" { r = $3 }
	    $1 == "direct_write_count" { w = $3 }
	    END { printf "%d %d", r, w }' /proc/spl/kstat/zfs/bench/iostats \
	    2>/dev/null || echo "0 0"
}

# measure <round> <mode> <feature> <name> <fio options>
measure() {
	r=$1 mode=$2 feat=$3 name=$4
	shift 4
	s="$OUT/s.$r.$mode.$feat.$name"
	rm -f "$s"
	pool_create "$mode" "$feat"
	# Data to read and to overwrite, at 50% compressibility so lz4 has
	# something to do and dedup sees unique blocks.
	sudo fio --name=fill --directory=/bench --filename=data --size=$SIZE \
	    --rw=write --bs=1M --buffer_compress_percentage=50 \
	    --refill_buffers --end_fsync=1 >/dev/null
	sudo ./zpool export bench
	sudo ./zpool import -d /dev/shm bench
	if [ "$feat" = enc ]; then
		sudo ./zfs load-key bench
		sudo ./zfs mount bench
	fi
	before=$(dio_counts)
	sample "$s" &
	spid=$!
	# shellcheck disable=SC2086,SC2024
	sudo fio --name="$name" --directory=/bench --filename=data \
	    --size=$SIZE --numjobs=1 --iodepth=1 --time_based \
	    --runtime=$RUNTIME --buffer_compress_percentage=50 \
	    --refill_buffers --output-format=json "$@" > "$s.json" || true
	kill "$spid"
	wait "$spid" 2>/dev/null || true
	after=$(dio_counts)
	bw=$(jq '((.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
	    / 1048576) | floor' "$s.json" 2>/dev/null || echo err)
	# peak and end of each column, in MiB
	stats=$(awk '
	    { for (i = 1; i <= NF; i++) if ($i > p[i]) p[i] = $i
	      for (i = 1; i <= NF; i++) e[i] = $i }
	    END { for (i = 1; i <= NF; i++)
		printf "\t%.1f/%.1f", p[i] / 1048576, e[i] / 1048576 }' "$s")
	# shellcheck disable=SC2086
	set -- $before $after
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$r" "$mode" "$feat" "$name" \
	    "$bw" "$(($3 - $1))" "$(($4 - $2))" "$stats" >> "$OUT"/raw.tsv
	sudo ./zpool destroy bench
	sudo rm -f /dev/shm/vdev
}

"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
# arc.c ignores a zfs_arc_max not above arc_c_min (RAM/32): lower it first.
echo "$ARC_MIN" | sudo tee /sys/module/zfs/parameters/zfs_arc_min >/dev/null
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
echo "benchbenchbench" | sudo tee /var/tmp/bench.key >/dev/null
{
	fio --version
	uname -r
	for p in zfs_arc_min zfs_arc_max zfs_dio_enabled zfs_dio_strict; do
		echo "$p $(cat /sys/module/zfs/parameters/$p)"
	done
	awk '$1 == "c_min" || $1 == "c_max" { print "arcstats." $1, $3 }' \
	    /proc/spl/kstat/zfs/arcstats
	sudo dmesg | grep -iE 'ignoring tunable|unknown parameter' || true
} | tee "$OUT"/env.txt

hdr="round\tmode\tfeature\tworkload\tMiB/s\tdio_reads\tdio_writes"
for s in $STATS dbuf_cache; do hdr="$hdr\t$s(peak/end)"; done
printf '%b\n' "$hdr" > "$OUT"/raw.tsv

r=1
while [ $r -le $ROUNDS ]; do
	for mode in $MODES; do
		for feat in $FEATURES; do
			[ "$mode" = pc_metadata ] && [ "$feat" = plain2 ] &&
			    continue
			echo "$WORKLOADS" | while IFS=: read -r name opts; do
				[ -n "$name" ] || continue
				# shellcheck disable=SC2086
				measure $r $mode $feat "$name" $opts
			done
		done
	done
	r=$((r + 1))
done

column -t -s "$(printf '\t')" "$OUT"/raw.tsv | tee -a "$GITHUB_STEP_SUMMARY"
