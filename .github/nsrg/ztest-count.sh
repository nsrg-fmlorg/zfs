#!/bin/sh
# ztest-count.sh <label> <runs>: run .github/nsrg/ztest.sh <runs> times,
# counting opens of /dev/zfs with bpftrace (only pool_active() makes
# them, so they mark passes that took the import path), and report
# each run's exit status.  bpftrace watches from outside: LeakSanitizer
# refuses to run under ptrace, so strace would change the test.  Root.
set -u
label=$1
runs=$2
out=/var/tmp/zcount-$label
mkdir -p "$out"
i=1
while [ "$i" -le "$runs" ]; do
	rm -rf /var/tmp/ztest
	bpftrace -q -e 'tracepoint:syscalls:sys_enter_openat
	    /str(args->filename) == "/dev/zfs"/
	    { printf("%s %d\n", comm, pid); }' > "$out/opens$i" 2>&1 &
	bt=$!
	sleep 5
	.github/nsrg/ztest.sh > "$out/ztest$i.log" 2>&1
	rc=$?
	kill "$bt"
	wait "$bt" 2>/dev/null
	opens=$(grep -c '^ztest ' "$out/opens$i")
	fails=$(grep -c 'no pools found' "$out/ztest$i.log")
	echo "$label run$i exit=$rc ztest_dev_zfs_opens=$opens" \
	    "no_pools_found=$fails"
	i=$((i + 1))
done
