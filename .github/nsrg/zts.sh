#!/bin/sh
# Tags come from the dispatch input, else from .github/nsrg/tags on the
# branch, so each branch names the tests that cover what it changes.
#
# upload-artifact refuses the results directory (ZTS names groups like
# "zvol_misc:Linux"), so the log of each failed test goes to the job
# output instead.
set -eu
tags=${TAGS:-}
[ -n "$tags" ] || tags=$(cat .github/nsrg/tags 2>/dev/null || echo arc,cache)
.github/nsrg/load.sh .
out=/var/tmp/zts.out
if scripts/zfs-tests.sh -vK -s 3G -T "$tags" > "$out" 2>&1; then
	cat "$out"
	exit 0
fi
cat "$out"
sed -n 's/^    FAIL \([^ ]*\) .*/\1/p' "$out" | while read -r t; do
	echo "::group::log of $t"
	find /var/tmp/test_results -path "*/$(basename "$t")/*" -type f \
	    -exec sh -c 'for f; do echo "== $f"; cat "$f"; done' sh {} +
	echo "::endgroup::"
done
exit 1
