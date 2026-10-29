#!/bin/sh
# abdorder-summary.sh <dir>: means over rounds, with min-max, from the
# files abdorder.sh writes.
set -eu
d=$1

echo "throughput MiB/s, mean (min-max), and sys CPU %"
awk -F'\t' '
    {
	k = $1 "\t" $2 "\t" $4
	s[k] += $5; n[k]++; c[k] += $6
	if (!(k in lo) || $5 < lo[k]) lo[k] = $5
	if (!(k in hi) || $5 > hi[k]) hi[k] = $5
    }
    END {
	for (k in s)
		printf "%s\t%d (%d-%d)\t%.1f\n", k, s[k] / n[k], lo[k],
		    hi[k], c[k] / n[k]
    }' "$d"/perf.tsv | sort

echo
echo "free order>=9 blocks before/after, compact stalls/fails, ARC bytes"
awk -F'\t' '
    {
	k = $1 "\t" $2
	b[k] += $4; a[k] += $5; st[k] += $6; f[k] += $7; z[k] += $8; n[k]++
    }
    END {
	for (k in n)
		printf "%s\t%d\t%d\t%d\t%d\t%d\n", k, b[k] / n[k],
		    a[k] / n[k], st[k] / n[k], f[k] / n[k], z[k] / n[k]
    }' "$d"/frag.tsv | sort

echo
echo "2M huge pages afterwards: asked, got (min-max), ms"
awk -F'\t' '
    {
	k = $1 "\t" $2
	w[k] += $4; g[k] += $5; t[k] += $6; n[k]++
	if (!(k in lo) || $5 < lo[k]) lo[k] = $5
	if (!(k in hi) || $5 > hi[k]) hi[k] = $5
    }
    END {
	for (k in n)
		printf "%s\t%d\t%d (%d-%d)\t%d\n", k, w[k] / n[k],
		    g[k] / n[k], lo[k], hi[k], t[k] / n[k]
    }' "$d"/hugepages.tsv | sort

echo
echo "ABD scatter chunks by order (sum over rounds)"
awk -F'\t' '{ s[$1 "\t" $2 "\t" $4] += $5 }
    END { for (k in s) printf "%s\t%d\n", k, s[k] }' "$d"/orders.tsv | sort
