#!/bin/sh
# ztest-import.sh <label>: force ztest through ztest_import_impl() and
# report whether it finds the pool.  "ztest -E" removes zpool.cache and
# imports the pool left by the previous run, so every attempt takes the
# path that fails intermittently in the sanitize job.  Run as root,
# as zloop.sh is.
set -u
label=$1
dir=/var/tmp/zti-$label
rm -rf "$dir"
mkdir -p "$dir"
PATH=$(pwd):$PATH
export PATH

echo "== $label: /dev/zfs $(ls -l /dev/zfs 2>&1)"
./ztest -T 15 -f "$dir" > "$dir/create.log" 2>&1
echo "$label create exit=$?"
for i in 1 2 3; do
	./ztest -E -T 15 -f "$dir" > "$dir/import$i.log" 2>&1
	rc=$?
	echo "$label import$i exit=$rc" \
	    "$(grep -m1 -E 'failed to find config|no pools found' \
	    "$dir/import$i.log")"
done
