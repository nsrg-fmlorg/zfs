#!/bin/sh
# ztest-count.sh <label> <runs>: run .github/nsrg/ztest.sh <runs> times
# under strace, counting opens of /dev/zfs (only pool_active() makes
# them, so they mark passes that took the import path), and report
# each run's exit status.  Run as root.
set -u
label=$1
runs=$2
out=/var/tmp/zcount-$label
mkdir -p "$out"
i=1
while [ "$i" -le "$runs" ]; do
	rm -rf /var/tmp/ztest
	strace -f --seccomp-bpf -qq -e trace=openat -P /dev/zfs \
	    -o "$out/strace$i" .github/nsrg/ztest.sh > "$out/ztest$i.log" 2>&1
	rc=$?
	opens=$(cat "$out"/strace"$i"* 2>/dev/null | grep -c '/dev/zfs')
	fails=$(grep -c 'no pools found' "$out/ztest$i.log")
	echo "$label run$i exit=$rc dev_zfs_opens=$opens no_pools_found=$fails"
	i=$((i + 1))
done
