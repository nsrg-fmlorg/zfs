#!/bin/sh
# summarise.sh <outdir>: one table row per config and workload: clat
# mean, p99 and p99.9 in microseconds (mean of the repeats, with the
# min-max of the per-repeat means), IOPS, and the host ARC data size
# before and after the boot.
set -eu
OUT=$1

echo '## QD=1/QD=32 4k latency in a KVM guest (runner disk, not NVMe)'
echo
echo '| config | workload | clat mean us (min-max) | p99 us | p99.9 us | IOPS | ARC data MiB before→after | ARC hit % |'
echo '|---|---|---|---|---|---|---|---|'
for d in "$OUT"/*/; do
	name=$(basename "$d")
	[ -f "$d"/status ] || { echo "| $name | (no results) |||||||"; continue; }
	db=$(awk '$1 == "data_size" { print int($2 / 1048576) }' "$d"/arc.before)
	da=$(awk '$1 == "data_size" { print int($2 / 1048576) }' "$d"/arc.after)
	hit=$(paste "$d"/arc.before "$d"/arc.after | awk '
	    $1 == "hits" { h = $4 - $2 } $1 == "misses" { m = $4 - $2 }
	    END { if (h + m > 0) printf "%.0f", 100 * h / (h + m); else print "-" }')
	for w in qd1-randread qd1-randwrite qd1-fsyncwrite qd32-randread qd32-randwrite; do
		ls "$d"/$w.*.json >/dev/null 2>&1 || continue
		dir="read"
		case $w in *write) dir="write" ;; esac
		for j in "$d"/"$w".*.json; do
			jq -r --arg d "$dir" '.jobs[0][$d] |
			    [.clat_ns.mean / 1000,
			     (.clat_ns.percentile["99.000000"] // 0) / 1000,
			     (.clat_ns.percentile["99.900000"] // 0) / 1000,
			     .iops] | @tsv' "$j"
		done | awk -F'\t' -v n="$name" -v w="$w" -v db="$db" -v da="$da" -v hit="$hit" '
		    { m += $1; p += $2; q += $3; i += $4; c++
		      if (c == 1 || $1 < lo) lo = $1
		      if (c == 1 || $1 > hi) hi = $1 }
		    END { printf "| %s | %s | %.1f (%.1f-%.1f) | %.1f | %.1f | %.0f | %s→%s | %s |\n",
		      n, w, m / c, lo, hi, p / c, q / c, i / c, db, da, hit }'
	done
done
echo
echo '## fsync latency (fio sync lat, qd1-fsyncwrite)'
echo
echo '| config | fsync mean us (min-max) | p99 us | p99.9 us | write clat + fsync mean us |'
echo '|---|---|---|---|---|'
for d in "$OUT"/*/; do
	name=$(basename "$d")
	ls "$d"/qd1-fsyncwrite.*.json >/dev/null 2>&1 || continue
	for j in "$d"/qd1-fsyncwrite.*.json; do
		jq -r '.jobs[0] | [(.sync.lat_ns.mean // 0) / 1000,
		    (.sync.lat_ns.percentile["99.000000"] // 0) / 1000,
		    (.sync.lat_ns.percentile["99.900000"] // 0) / 1000,
		    .write.clat_ns.mean / 1000] | @tsv' "$j"
	done | awk -F'\t' -v n="$name" '
	    { m += $1; p += $2; q += $3; w += $4; c++
	      if (c == 1 || $1 < lo) lo = $1
	      if (c == 1 || $1 > hi) hi = $1 }
	    END { printf "| %s | %.1f (%.1f-%.1f) | %.1f | %.1f | %.1f |\n",
	      n, m / c, lo, hi, p / c, q / c, (m + w) / c }'
done
echo
echo '## ARC limits'
echo
echo '```'
cat "$OUT"/arc-limits.txt 2>/dev/null || echo "no arc-limits.txt"
echo '```'
echo
echo '## block cloning'
echo
echo '```'
cat "$OUT"/reflink.txt 2>/dev/null || echo "no reflink results"
echo '```'
