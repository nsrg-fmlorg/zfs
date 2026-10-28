#!/bin/sh
# build.sh <srcdir> <release|debug|sanitize> [make target]
#
# debug turns on ASSERTs and, through DEBUG_CFLAGS in config/zfs-build.m4,
# -Werror.  The Ubuntu kernel is built with gcc, so under clang only the
# userspace half is built; the module would not load anyway.
#
# Under the sanitizers upstream's zdb.c does not build with -Werror
# (-Warray-bounds on ddt_stat_t), so the sanitize job names ztest as the
# target and builds only what that needs.
set -eu
cd "$1"
case $2 in
release)	opts="--enable-debug=no" ;;
debug)		opts="--enable-debug" ;;
sanitize)	opts="--enable-debug --enable-asan --enable-ubsan
		    --with-config=user" ;;
*)		echo "build.sh: unknown flavour $2" >&2; exit 2 ;;
esac
[ "${CC:-gcc}" = gcc ] || opts="$opts --with-config=user"
sh autogen.sh >/dev/null
# shellcheck disable=SC2086
./configure -q $opts
make -s -j"$(nproc)" ${3:+"$3"}
