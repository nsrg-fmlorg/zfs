#!/bin/sh
# Tags come from the dispatch input, else from .github/nsrg/tags on the
# branch, so each branch names the tests that cover what it changes.
set -eu
tags=${TAGS:-}
[ -n "$tags" ] || tags=$(cat .github/nsrg/tags 2>/dev/null || echo arc,cache)
.github/nsrg/load.sh .
scripts/zfs-tests.sh -vK -s 3G -T "$tags"
