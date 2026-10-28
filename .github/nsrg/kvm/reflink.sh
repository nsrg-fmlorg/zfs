#!/bin/sh
# reflink.sh <outdir>: clone a 4 GiB VM image with block cloning and
# record the time and the space it takes.
set -eu
: "${ZFS:?}" "${ZPOOL:?}"
OUT=$1
f=$OUT/reflink.txt
p=/sys/module/zfs/parameters/zfs_bclone_enabled
{
	echo "zfs_bclone_enabled=$(cat $p)"
	if [ "$(cat $p)" != 1 ]; then
		echo 1 | sudo tee $p >/dev/null
		echo "set zfs_bclone_enabled=1"
	fi
	sudo "$ZFS" create -o compression=off tank/img
	sudo dd if=/dev/urandom of=/tank/img/a.img bs=1M count=4096 status=none
	sudo "$ZPOOL" sync tank
	echo "before:"
	sudo "$ZFS" list -Hp -o name,used tank/img
	sudo "$ZPOOL" get -Hp bcloneused,bclonesaved tank
	s=$(date +%s.%N)
	sudo cp --reflink=always /tank/img/a.img /tank/img/b.img
	sudo "$ZPOOL" sync tank
	e=$(date +%s.%N)
	echo "clone seconds: $(echo "$e - $s" | bc)"
	echo "after:"
	sudo "$ZFS" list -Hp -o name,used tank/img
	sudo "$ZPOOL" get -Hp bcloneused,bclonesaved tank
	cmp /tank/img/a.img /tank/img/b.img && echo "contents equal"
} > "$f" 2>&1
cat "$f"
