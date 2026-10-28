#!/bin/sh
# summary.sh <serial>...: clat of the qd1 job from each guest's console.
for f in "$@"; do
	sed -n '/^FIO-BEGIN/,/^FIO-END/p' "$f" | sed '1d;$d' | tr -d '\r' |
	    jq -r --arg f "$(basename "$f")" '.jobs[0].read |
	    [$f, .iops, .clat_ns.mean / 1000,
	    .clat_ns.percentile["99.000000"] / 1000,
	    .clat_ns.percentile["99.900000"] / 1000] |
	    "\(.[0])\tIOPS \(.[1] | floor)\tclat mean \(.[2] | floor)us\tp99 \(.[3] | floor)us\tp99.9 \(.[4] | floor)us"' ||
	    echo "$f: no fio result"
done
