#!/bin/sh
# abdorder.sh: what zfs_abd_scatter_max_order costs and buys.
#
# abd_alloc_chunks() takes the largest free compound page it can get
# without reclaim or compaction, down to order 0.  That keeps ABDs in a
# few large chunks, but it also takes the large free blocks other users
# of contiguous memory need.  For each max order this records fio
# throughput and system CPU, the order mix ABD actually got, compaction
# activity, and how many 2M huge pages the kernel can still find
# afterwards, with the ARC both larger and smaller than the working set.
#
# The vdev is a file on the runner's disk behind a direct-I/O loop
# device, so the pool's I/O does not sit in the page cache and muddy
# the memory picture.  It is not an NVMe device.
set -eu

OUT=/var/tmp/bench/abdorder
HERE=$(pwd)
ROUNDS=2
FILE_SIZE=2G
RUNTIME=15
WORKLOADS="write:1M read:1M randread:128k randwrite:128k"
PARAM=/sys/module/zfs/parameters
VDEV=/var/tmp/abd-vdev

mkdir -p "$OUT"
"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"

DEFAULT_ORDER=$(cat $PARAM/zfs_abd_scatter_max_order)
ORDERS="0 1 2 3 $DEFAULT_ORDER"

sudo truncate -s 8G "$VDEV"
LOOP=$(sudo losetup --direct-io=on --show -f "$VDEV")
sudo "$HERE"/zpool create -f -O compression=off -O recordsize=1M \
    -O atime=off abd "$LOOP"
sudo "$HERE"/zfs create -o recordsize=128k abd/small

set_param() {	# set_param <name> <value>: and prove it took
	echo "$2" | sudo tee $PARAM/"$1" >/dev/null
	got=$(cat $PARAM/"$1")
	[ "$got" = "$2" ] || { echo "$1 is $got, wanted $2" >&2; exit 1; }
}

vmstat_get() {
	awk -v k="$1" '$1 == k { print $2 }' /proc/vmstat
}

# Free blocks of order 9 and above (2M and up on x86-64), all zones.
big_free() {
	awk '{ for (i = 5 + 9; i <= NF; i++) n += $i } END { print n + 0 }' \
	    /proc/buddyinfo
}

# Start every run from the same memory state: an empty ARC, no page
# cache, compacted free memory.
reset_memory() {
	sudo "$HERE"/zpool export abd
	sync
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	echo 1 | sudo tee /proc/sys/vm/compact_memory >/dev/null
	sudo "$HERE"/zpool import -d "$LOOP" abd
}

# hugepages <label>: ask for 2M pages for half of free memory,
# time it, record how many the kernel found, give them back.
hugepages() {
	# Half of free memory: enough to need large blocks, not so much that
	# the request itself has to reclaim the ARC.
	want=$(awk '/^MemFree:/ { print int($2 / 2048 / 2) }' /proc/meminfo)
	t0=$(date +%s%N)
	echo "$want" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
	t1=$(date +%s%N)
	got=$(cat /proc/sys/vm/nr_hugepages)
	echo 0 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
	printf '%s\t%s\t%s\t%s\n' "$1" "$want" "$got" \
	    $(( (t1 - t0) / 1000000 ))
}

run() {	# run <arc> <order label> <order> <round>
	label="$1	$2	$4"
	reset_memory
	set_param zfs_abd_scatter_max_order "$3"

	stall0=$(vmstat_get compact_stall)
	fail0=$(vmstat_get compact_fail)
	free0=$(big_free)

	for w in $WORKLOADS; do
		rw=${w%:*}
		bs=${w#*:}
		dir=/abd
		[ "$bs" = 1M ] || dir=/abd/small
		sudo fio --name="$rw" --directory="$dir" --filename=f \
		    --size="$FILE_SIZE" --rw="$rw" --bs="$bs" --numjobs=4 \
		    --time_based --runtime="$RUNTIME" --group_reporting \
		    --ioengine=psync --output-format=json |
		    jq -r --arg l "$label" --arg w "$w" '[$l, $w,
		    ((.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
		    / 1048576 | floor), (.jobs[0].sys_cpu | . * 10 | floor
		    | . / 10)] | @tsv' >> "$OUT"/perf.tsv
	done

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$free0" "$(big_free)" \
	    $(( $(vmstat_get compact_stall) - stall0 )) \
	    $(( $(vmstat_get compact_fail) - fail0 )) \
	    "$(awk '/^arc_size|^size / { print $3; exit }' \
	    /proc/spl/kstat/zfs/arcstats)" >> "$OUT"/frag.tsv

	awk -v l="$label" '/^scatter_order_/ && $3 > 0 {
	    printf "%s\t%s\t%s\n", l, $1, $3 }' \
	    /proc/spl/kstat/zfs/abdstats >> "$OUT"/orders.tsv

	{
		echo "== $label"
		cat /proc/buddyinfo
		grep -A12 '^Free pages count per migrate type' \
		    /proc/pagetypeinfo || true
	} >> "$OUT"/buddyinfo.txt

	hugepages "$label" >> "$OUT"/hugepages.tsv
}

# The ARC limit only takes when above arc_c_min (RAM/32 by default).
set_param zfs_arc_min $((64 * 1024 * 1024))

# Fill the files once; every run then reads and rewrites them.
for d in /abd /abd/small; do
	sudo fio --name=fill --directory=$d --filename=f --size=$FILE_SIZE \
	    --rw=write --bs=1M --end_fsync=1 >/dev/null
done

for arc in big small; do
	case $arc in
	big)	set_param zfs_arc_max $((8 * 1024 * 1024 * 1024)) ;;
	small)	set_param zfs_arc_max $((512 * 1024 * 1024)) ;;
	esac
	r=1
	while [ $r -le $ROUNDS ]; do
		for o in $ORDERS; do
			run $arc "o$o" "$o" $r
		done
		# A/A: the default order once more in the same round.
		run $arc "o${DEFAULT_ORDER}aa" "$DEFAULT_ORDER" $r
		r=$((r + 1))
	done
done

sudo "$HERE"/zpool destroy abd
sudo losetup -d "$LOOP"
sudo rm -f "$VDEV"

"$HERE"/.github/nsrg/abdorder-summary.sh "$OUT" | tee "$OUT"/summary.txt |
    tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
