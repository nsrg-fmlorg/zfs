#!/bin/sh
# dbufmem.sh: dbuf cache held after writing in 1k parts with
# primarycache=none, base ($BASE) against this tree, three rounds each.
# The pool sits in /dev/shm; only the memory left cached is of interest.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/dbufmem
HERE=$(pwd)
ROUNDS=3
SIZE_MB=256

# measure <label> <srcdir>: appends <label> <cached l0 dbufs> <dbuf bytes>
measure() {
	label=$1
	src=$2
	"$HERE"/.github/nsrg/load.sh "$src"
	sudo truncate -s 2G /dev/shm/vdev
	sudo "$src"/zpool create -f -O compression=off -O recordsize=128k \
	    -O primarycache=none -O atime=off dm /dev/shm/vdev
	sudo dd if=/dev/urandom of=/dm/f bs=1024 \
	    count=$((SIZE_MB * 1024)) status=none
	sudo "$src"/zpool sync dm
	sudo "$src"/zpool sync dm
	os=$(sudo "$src"/zfs get -Hpo value objsetid dm)
	obj=$(stat -c %i /dm/f)
	DBUFS=$OUT/dbufs.$label
	sudo cat /proc/spl/kstat/zfs/dbufs | tee "$DBUFS" >/dev/null
	# Columns of the dbufs kstat: pool objset object level ...
	l0=$(awk -v s="$os" -v o="$obj" \
	    '$1 == "dm" && $2 == s && $3 == o && $4 == 0' \
	    "$DBUFS" | wc -l)
	# The dbufs kstat is readable by root only; read without sudo it
	# came back empty and counted 0 on both trees.  Keep what the
	# filter saw so a wrong count shows.
	{
		echo "== $label objset=$os object=$obj"
		awk '$1 == "dm" { print $2, $3, $4 }' "$DBUFS" |
		    sort | uniq -c
	} >> "$OUT"/dbufs-seen.txt
	bytes=$(awk '$1 == "cache_size_bytes" { print $3 }' \
	    /proc/spl/kstat/zfs/dbufstats)
	printf '%s\t%s\t%s\n' "$label" "$l0" "$bytes" >> "$OUT"/raw.tsv
	sudo "$src"/zpool destroy dm
	sudo rm -f /dev/shm/vdev
}

mkdir -p "$OUT"
base=$(mktemp -d /var/tmp/base.XXXXXX)
git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master
git worktree add -q --detach "$base" "$BASE"
"$HERE"/.github/nsrg/build.sh "$base" release
"$HERE"/.github/nsrg/build.sh "$HERE" release

i=0
while [ $i -lt $ROUNDS ]; do
	measure base "$base"
	measure head "$HERE"
	i=$((i + 1))
done

{
	printf 'tree\tcached l0 dbufs (of %d)\tdbuf cache bytes\n' \
	    $((SIZE_MB * 8))
	cat "$OUT"/raw.tsv
} | column -t -s "$(printf '\t')" | tee -a "$GITHUB_STEP_SUMMARY"
