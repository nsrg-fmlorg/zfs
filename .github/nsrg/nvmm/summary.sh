#!/bin/sh
# summary.sh <serial>...: the qd1 job's IOPS and completion latency, as
# fio printed them on each guest's console.
for f in "$@"; do
	echo "== $(basename "$f")"
	sed -n '/^FIO-BEGIN/,/^FIO-END/p' "$f" 2>/dev/null | tr -d '\r' |
	    grep -E 'IOPS=| clat |clat percentiles|50\.00th|99\.00th|99\.90th' ||
	    echo "no fio result"
done
