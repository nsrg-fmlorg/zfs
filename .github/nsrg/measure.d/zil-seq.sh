#!/bin/sh
# zil-seq.sh <base|head> <srcdir> <outdir>: the new test has to fail on
# base, a release build where nothing asserts, and pass on head.
set -u
side=$1 src=$2 out=$3
t=tests/zfs-tests/tests/functional/slog/slog_replay_volume_reopen.ksh
[ -e "$src/$t" ] || cp "$t" "$src/$t"
"$(dirname "$0")"/../load.sh "$src"
cd "$src" || exit 1
scripts/zfs-tests.sh -vK -s 3G \
    -t tests/functional/slog/slog_replay_volume_reopen > "$out/zts.out" 2>&1
rc=$?
tail -20 "$out/zts.out"
find /var/tmp/test_results -name 'merged' -path '*reopen*' -exec tail -8 {} +
echo "zil-seq: $side rc $rc"
case $side in
base)	[ $rc -ne 0 ] ;;
head)	[ $rc -eq 0 ] ;;
esac
