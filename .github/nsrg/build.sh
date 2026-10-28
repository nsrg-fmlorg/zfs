#!/bin/sh
# build.sh <srcdir> <release|debug|sanitize> [make target]
#
# debug turns on ASSERTs and, through DEBUG_CFLAGS in config/zfs-build.m4,
# -Werror.  The Ubuntu kernel is built with gcc, so under clang only the
# userspace half is built; the module would not load anyway.
#
# Under the sanitizers gcc reports -Warray-bounds on ddt_stat_t in
# upstream's zdb.c, and ztest runs zdb to check the pool it leaves, so
# that one warning is kept as a warning rather than an error.
set -eu
cd "$1"
case $2 in
release)	opts="--enable-debug=no" ;;
debug)		opts="--enable-debug" ;;
sanitize)	opts="--enable-debug --enable-asan --enable-ubsan
		    --with-config=user"
		export CFLAGS="${CFLAGS:-} -Wno-error=array-bounds" ;;
*)		echo "build.sh: unknown flavour $2" >&2; exit 2 ;;
esac
[ "${CC:-gcc}" = gcc ] || opts="$opts --with-config=user"
sh autogen.sh >/dev/null
# shellcheck disable=SC2086
./configure -q $opts
make -s -j"$(nproc)" ${3:+"$3"}
