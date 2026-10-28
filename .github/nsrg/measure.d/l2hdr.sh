#!/bin/sh
# l2hdr.sh <base|head> <srcdir> <outdir>
#
# L2ARC-only header memory against l2arc_meta_percent (PR 19383).  The
# pool and its cache device live in /dev/shm.  The cache is filled with
# 8K records, then the pool is exported and imported so that the rebuild
# leaves only L2ARC-only headers, which are what the limit counts.  With
# l2arc_meta_percent lowered to 1, base keeps every header and stops
# feeding; head should prune down to the limit and feed again.  The cost
# is measured as the L2ARC hits lost when the first file is read back.
set -eu

side=$1 src=$2 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
P=/sys/module/zfs/parameters
K=/proc/spl/kstat/zfs/arcstats
ARC_MAX=$((512 * 1024 * 1024))
POOL=l2m

stat() {	# stat <name>: one arcstats counter
	awk -v n="$1" '$1 == n { print $3 }' $K
}

param() {	# param <name> <value>
	echo "$2" | sudo tee "$P/$1" >/dev/null
}

# Read a file twice, so that the feed thread has a full pass to write.
readback() {
	sudo dd if="/$POOL/$1" of=/dev/null bs=1M 2>/dev/null
	sudo dd if="/$POOL/$1" of=/dev/null bs=1M 2>/dev/null
}

# Wait until l2_size stops growing, at most 60s.
settle() {
	prev=-1 i=0
	while [ $i -lt 60 ]; do
		cur=$(stat l2_size)
		[ "$cur" = "$prev" ] && break
		prev=$cur
		sleep 2
		i=$((i + 2))
	done
}

"$here"/.github/nsrg/load.sh "$src"
# zfs_arc_max is ignored unless it exceeds arc_c_min, which defaults to
# a 32nd of memory: 512M or near it on a 16G runner.  Lower the minimum
# first, and record what the ARC took and anything it refused.
sudo dmesg -C
# Earlier runs set zfs_arc_max alone; record what that did, so their
# numbers can be placed.
printf 'mem\t%s\nc_min_default\t%s\nc_max_default\t%s\n' \
    "$(awk '/MemTotal/ { print $2 * 1024 }' /proc/meminfo)" \
    "$(stat c_min)" "$(stat c_max)" > "$out"/old-order.tsv
param zfs_arc_max $ARC_MAX
printf 'c_max_max_alone\t%s\nignored_max_alone\t%s\n' "$(stat c_max)" \
    "$(sudo dmesg | grep -ci 'ignoring tunable' || true)" >> "$out"/old-order.tsv
cat "$out"/old-order.tsv
sudo dmesg -C
param zfs_arc_min $((64 * 1024 * 1024))
param zfs_arc_max $ARC_MAX
c_max=$(stat c_max)
sudo dmesg | grep -i 'ignoring tunable' > "$out"/ignored.txt || true
if [ "$c_max" -ne $ARC_MAX ]; then
	echo "l2hdr.sh: c_max is $c_max, not $ARC_MAX" >&2
	cat "$out"/ignored.txt >&2
	exit 1
fi
param l2arc_noprefetch 0
param l2arc_write_max $((256 * 1024 * 1024))
# Log blocks, and so the rebuild on import, need a cache device of at
# least this size; the 1G file falls just short of the default.
param l2arc_rebuild_blocks_min_l2size 0

sudo truncate -s 4G /dev/shm/l2m-data
sudo truncate -s 1G /dev/shm/l2m-cache
sudo "$src"/zpool create -f -O compression=off -O recordsize=8K \
    -O atime=off $POOL /dev/shm/l2m-data cache /dev/shm/l2m-cache
sudo dd if=/dev/urandom of=/$POOL/a bs=1M count=1536 2>/dev/null
sync
readback a
settle

sudo "$src"/zpool export $POOL
sudo "$src"/zpool import -d /dev/shm $POOL
settle

limit=$((ARC_MAX / 100))
hdr0=$(stat l2_hdr_size)
param l2arc_meta_percent 1

# Ten seconds of feed iterations against the lowered limit.
printf 't\tl2_hdr_size\tl2_hdr_pruned\tl2_abort_lowmem\n' > "$out"/trace.tsv
t=0
while [ $t -le 10 ]; do
	printf '%d\t%s\t%s\t%s\n' $t "$(stat l2_hdr_size)" \
	    "$(stat l2_hdr_pruned || true)" "$(stat l2_abort_lowmem)" \
	    >> "$out"/trace.tsv
	sleep 1
	t=$((t + 1))
done
hdr1=$(stat l2_hdr_size)

# What the pruning cost: L2ARC hits when the first file is read again,
# before anything new is written that would move the write hand.
h0=$(stat l2_hits) m0=$(stat l2_misses)
sudo dd if=/$POOL/a of=/dev/null bs=1M 2>/dev/null
h1=$(stat l2_hits) m1=$(stat l2_misses)

# Does the L2ARC take new data?
w0=$(stat l2_write_bytes)
sudo dd if=/dev/urandom of=/$POOL/b bs=1M count=256 2>/dev/null
sync
readback b
sleep 5
w1=$(stat l2_write_bytes)

sudo "$src"/zpool destroy $POOL
sudo rm -f /dev/shm/l2m-data /dev/shm/l2m-cache

cat > "$out"/result.tsv <<RESULT
side	$side
c_min	$(stat c_min)
c_max	$c_max
c_at_end	$(stat c)
ignored	$(wc -l < "$out"/ignored.txt)
limit	$limit
hdr_after_import	$hdr0
hdr_after_10s	$hdr1
pruned	$(awk -F'\t' 'END { print $3 }' "$out"/trace.tsv)
l2_written_after	$((w1 - w0))
l2_hits_reread	$((h1 - h0))
l2_misses_reread	$((m1 - m0))
RESULT
cat "$out"/result.tsv

if [ "$side" = head ]; then
	base_out=$(dirname "$out")/base
	{
		echo "### l2hdr (PR 19383)"
		echo
		echo "| | base | head |"
		echo "|---|---|---|"
		paste "$base_out"/result.tsv "$out"/result.tsv |
		    awk -F'\t' 'NR > 1 { printf "| %s | %s | %s |\n", $1, $2, $4 }'
	} > "$out"/summary.md
fi
