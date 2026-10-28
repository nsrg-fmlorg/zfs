#!/bin/sh
# load.sh <srcdir>: unload whatever is loaded, load the tree's modules,
# with this branch's .github/nsrg/bench-options if it has any.
#
# zfs.sh cannot pass options: an in-tree build has it insmod zfs.ko by
# path (scripts/Makefile.am exports LDMOD=/sbin/insmod and KMOD_ZFS into
# common.sh, overriding the environment), and /etc/modprobe.d is not
# read on that path.  So zfs is loaded again by hand with the options.
set -eu
opts=$(cat "$(dirname "$0")"/bench-options 2>/dev/null || true)
cd "$1"
sudo scripts/zfs.sh -u >/dev/null 2>&1 || true
sudo scripts/zfs-helpers.sh -i >/dev/null
sudo scripts/zfs.sh
if [ -n "$opts" ]; then
	sudo rmmod zfs
	# shellcheck disable=SC2086
	sudo insmod module/zfs.ko $opts
fi
