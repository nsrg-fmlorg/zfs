#!/bin/sh
# measure.sh: build this tree and $BASE (release), then run every
# .github/nsrg/measure.d/*.sh once against each, as
#	<script> <label> <srcdir> <outdir>
# A branch adds a script there when its change needs a measurement of
# its own rather than the fio throughput bench.sh takes.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/measure
HERE=$(pwd)

set -- .github/nsrg/measure.d/*.sh
[ -e "$1" ] || { echo "measure.sh: nothing in measure.d"; exit 0; }

git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master
base=$(mktemp -d /var/tmp/base.XXXXXX)
git worktree add -q --detach "$base" "$BASE"
"$HERE"/.github/nsrg/build.sh "$base" release
"$HERE"/.github/nsrg/build.sh "$HERE" release

for script in "$@"; do
	name=$(basename "$script" .sh)
	for side in base head; do
		if [ $side = base ]; then src=$base; else src=$HERE; fi
		mkdir -p "$OUT/$name/$side"
		"$HERE/$script" $side "$src" "$OUT/$name/$side"
	done
	if [ -f "$OUT/$name/head/summary.md" ]; then
		cat "$OUT/$name/head/summary.md" >> "$GITHUB_STEP_SUMMARY"
	fi
done
