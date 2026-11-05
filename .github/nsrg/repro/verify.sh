#!/bin/sh
# verify.sh: bad checksums from a buffer changed during a Direct I/O
# write, zvol against a file, zfs_vdev_direct_write_verify 0 and 1.
# Control: same tool on a dataset.  mmap: page cache pages changed under
# writeback on a zvol, the case stable writes would cover.
set -u
OUT=/var/tmp/verify
HERE=$(pwd)
mkdir -p "$OUT"
P=/sys/module/zfs/parameters
MUB=$HERE/tests/zfs-tests/cmd/manipulate_user_buffer
gcc -O2 -pthread -o "$OUT"/mmapflip .github/nsrg/repro/mmapflip.c
[ -x "$MUB" ] || (cd tests/zfs-tests/cmd && make -s manipulate_user_buffer)
ls -l "$MUB" || MUB=$(find . -name manipulate_user_buffer -type f -perm -u+x | head -1)
Z="sudo $HERE/zpool"
F="sudo $HERE/zfs"

result() { # result <label>
	$Z sync vp
	echo "$1: status before scrub:"
	$Z status -dpv vp | sed -n '/NAME/,/errors:/p' | sed "s/^/$1:   /"
	dmesg_n=$(sudo dmesg | grep -c 'WARNING\|PANIC')
	$Z scrub -w vp
	echo "$1: after scrub (dmesg warnings $dmesg_n):"
	$Z status -dpv vp | sed -n '/NAME/,$p' | sed "s/^/$1:   /"
	sudo sh -c 'cat /proc/spl/kstat/zfs/vp/iostats' |
	    awk -v l="$1" '/direct_write_count|direct_read_count/ { print l ": " $1, $3 }'
}

pool() {
	sudo rm -f /dev/shm/vd
	sudo truncate -s 3G /dev/shm/vd
	$Z create -f -O compression=off vp /dev/shm/vd
}

finish() {
	udevadm settle
	n=0
	until $Z destroy vp 2>/dev/null; do
		n=$((n + 1)); [ $n -lt 15 ] || exit 1
		sleep 2
	done
}

"$HERE"/.github/nsrg/load.sh "$HERE"
for v in 0 1; do
	echo "$v" | sudo tee $P/zfs_vdev_direct_write_verify >/dev/null

	pool
	$F create -o recordsize=128k -o direct=always -o primarycache=none vp/fs
	sudo truncate -s 256M /vp/fs/f
	sudo timeout 60 "$MUB" -f /vp/fs/f -n 400 -b 131072 -w
	echo "file v=$v exit $?"
	result "file-v$v"
	finish

	pool
	$F create -V 256M -b 128k -o direct=always -o primarycache=none vp/vol
	udevadm settle
	sudo timeout 60 "$MUB" -f /dev/zvol/vp/vol -n 400 -b 131072 -w
	echo "zvol v=$v exit $?"
	result "zvol-v$v"
	finish

	pool
	$F create -V 128M -b 4k -o direct=always -o primarycache=none vp/vol
	udevadm settle
	sudo timeout 60 "$OUT"/mmapflip /dev/zvol/vp/vol 20
	echo "mmap-direct v=$v exit $?"
	result "mmap-direct-v$v"
	finish

	pool
	$F create -V 128M -b 4k -o primarycache=none vp/vol
	udevadm settle
	sudo timeout 60 "$OUT"/mmapflip /dev/zvol/vp/vol 20
	echo "mmap-standard v=$v exit $?"
	result "mmap-standard-v$v"
	finish
done
sudo chmod -R a+r "$OUT"
