#!/bin/sh
# l2shrink.sh <base|head> <srcdir> <outdir>
#
# Rebuilt L2ARC-only headers when the ARC target falls (PR 19383).
# The headers are restored on import below l2arc_meta_percent of
# c_max, which is what the limit is measured from until the ARC first
# meets memory pressure.  Then the target falls in two ways:
#
#   arcmax    zfs_arc_min and then zfs_arc_max are lowered, which moves
#             c_max as well as c (arc_tuning_update())
#   pressure  a process takes most of free memory for a while, so the
#             kernel shrinks the ARC and arc_warm is set; c falls and
#             c_max does not
#
# and the script records c, c_max, the headers and how many were pruned.
set -eu

side=$1 src=$2 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
P=/sys/module/zfs/parameters
K=/proc/spl/kstat/zfs/arcstats
MIB=$((1024 * 1024))
POOL=l2s

stat() {
	awk -v n="$1" '$1 == n { print $3 }' $K
}

param() {
	echo "$2" | sudo tee "$P/$1" >/dev/null
}

snap() {	# snap <case> <when>
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(stat c)" \
	    "$(stat c_max)" "$(stat l2_hdr_size)" \
	    "$(stat l2_hdr_pruned || echo -)" >> "$out"/trace.tsv
}

setup() {	# fill the L2ARC, then import so the headers are L2ARC-only
	param zfs_arc_min $((64 * MIB))
	param zfs_arc_max $((512 * MIB))
	param l2arc_meta_percent 2
	param l2arc_noprefetch 0
	param l2arc_dwpd_limit 0
	param l2arc_rebuild_blocks_min_l2size 0
	sudo truncate -s 4G /dev/shm/l2s-data
	sudo truncate -s 1G /dev/shm/l2s-cache
	sudo "$src"/zpool create -f -O compression=off -O recordsize=8K \
	    $POOL /dev/shm/l2s-data cache /dev/shm/l2s-cache
	sudo dd if=/dev/urandom of=/$POOL/a bs=1M count=1024 2>/dev/null
	sync
	sudo dd if=/$POOL/a of=/dev/null bs=1M 2>/dev/null
	sleep 20
	sudo "$src"/zpool export $POOL
	sudo "$src"/zpool import -d /dev/shm $POOL
	sleep 10
}

teardown() {
	sudo "$src"/zpool destroy $POOL
	sudo rm -f /dev/shm/l2s-data /dev/shm/l2s-cache
}

"$here"/.github/nsrg/load.sh "$src"
printf 'case\twhen\tc\tc_max\tl2_hdr_size\tl2_hdr_pruned\n' > "$out"/trace.tsv

setup
snap arcmax before
param zfs_arc_min $((32 * MIB))
param zfs_arc_max $((128 * MIB))
sleep 15
snap arcmax after
teardown

"$here"/.github/nsrg/load.sh "$src"
setup
snap pressure before
# Take all but 128M of available memory and hold it until the ARC target
# has fallen below half of c_max, or 60 seconds; then let go.  Whether c
# fell is in the trace: a run in which it did not shows nothing.
python3 -c '
import time
def kstat(name):
    for line in open("/proc/spl/kstat/zfs/arcstats"):
        f = line.split()
        if f and f[0] == name:
            return int(f[2])
def avail():
    for line in open("/proc/meminfo"):
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) * 1024
hold = []
chunk = 64 * 1024 * 1024
deadline = time.time() + 60
while time.time() < deadline and kstat("c") >= kstat("c_max") // 2:
    if avail() > 128 * 1024 * 1024 + chunk:
        hold.append(bytearray(b"\x01") * chunk)
    else:
        time.sleep(0.5)
'
snap pressure after
sleep 10
snap pressure later
teardown

cat "$out"/trace.tsv

if [ "$side" = head ]; then
	base_out=$(dirname "$out")/base
	{
		echo "### l2shrink (PR 19383)"
		echo
		echo "| side | case | when | c | c_max | l2_hdr_size | pruned |"
		echo "|---|---|---|---|---|---|---|"
		for s in base head; do
			d=$base_out; [ $s = head ] && d=$out
			awk -F'\t' -v s=$s 'NR > 1 { printf "| %s | %s | %s | %s | %s | %s | %s |\n", s, $1, $2, $3, $4, $5, $6 }' "$d"/trace.tsv
		done
	} > "$out"/summary.md
fi
