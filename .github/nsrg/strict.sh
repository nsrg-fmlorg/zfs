#!/bin/sh
# strict.sh: build with the strictest warnings and fail on any warning
# that lands on a line this branch changed relative to $BASE.
#
# Upstream code is not clean at these levels, so the whole-tree output is
# kept as an artifact but only our own lines decide the result.
#
#   kernel     Kbuild W=123, and sparse (C=1)
#   userspace  gcc -Wall -Wextra plus the checks below; libzpool compiles
#              the module/zfs sources too, so they are seen twice
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/strict
mkdir -p "$OUT"

git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master

# Changed lines as "file:line", one per line.
git diff -U0 "$BASE"...HEAD -- '*.c' '*.h' | awk '
    /^\+\+\+ b\// { file = substr($0, 7) }
    /^@@/ {
	split($3, r, ",")
	start = substr(r[1], 2)
	count = (r[2] == "") ? 1 : r[2]
	for (i = 0; i < count; i++)
		print file ":" start + i
    }' | sort -u > "$OUT"/changed

USER_WARN="-Wall -Wextra -Wshadow -Wcast-qual -Wpointer-arith \
    -Wstrict-prototypes -Wmissing-prototypes -Wformat=2 -Wundef \
    -Wvla -Wwrite-strings -Wnull-dereference -Wduplicated-cond \
    -Wlogical-op -Wimplicit-fallthrough -Wsign-compare"

sh autogen.sh >/dev/null
./configure -q --enable-debug CFLAGS="$USER_WARN"
make -s -j"$(nproc)" -k W=123 C=1 2> "$OUT"/build.log || true

# A warning is ours when its file:line is one we changed.
grep -E '^[^ :]+:[0-9]+:([0-9]+:)? (warning|error):' "$OUT"/build.log |
    sed -E 's#^\./##; s#^.*/(module|lib|cmd|include|tests)/#\1/#' |
    sort -u > "$OUT"/all
awk -F: 'NR == FNR { ours[$0] = 1; next }
    ($1 ":" $2) in ours' "$OUT"/changed "$OUT"/all > "$OUT"/ours

echo "warnings in tree: $(wc -l < "$OUT"/all), on changed lines: $(wc -l < "$OUT"/ours)" |
    tee -a "$GITHUB_STEP_SUMMARY"
if [ -s "$OUT"/ours ]; then
	cat "$OUT"/ours
	exit 1
fi
