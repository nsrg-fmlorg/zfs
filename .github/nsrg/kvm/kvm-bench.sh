#!/bin/sh
# kvm-bench.sh: boot a KVM guest once per line of ./configs with its test
# disk on the named backing, run guest-run.sh inside, and collect fio
# results and host arcstats.  Everything sits on one medium, recorded in
# medium.txt; it is the runner's disk, not an NVMe device.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# The in-tree commands, matching the modules load.sh loaded.
ZFS=$(pwd)/zfs
ZPOOL=$(pwd)/zpool
export ZFS ZPOOL
OUT=/var/tmp/kvm
RUNTIME=${RUNTIME:-10}
REPEATS=${REPEATS:-2}
IMG_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

mkdir -p "$OUT"
if [ -d /mnt ] && [ "$(df -BG --output=avail /mnt | tail -1 | tr -dc 0-9)" -gt 40 ]; then
	WORK=/mnt/kvm
else
	WORK=/var/tmp/kvmwork
fi
sudo mkdir -p "$WORK"
sudo chown "$(id -u)" "$WORK"
{
	echo "work dir: $WORK"
	df -h "$WORK"
	findmnt -T "$WORK"
	lsblk -o NAME,SIZE,ROTA,MODEL,TRAN
	nproc
	qemu-system-x86_64 --version | head -1
} > "$OUT"/medium.txt 2>&1
cat "$OUT"/medium.txt

sudo chmod 666 /dev/kvm

# Guest image, first boot installs fio.
curl -fsSL -o "$WORK"/base.img "$IMG_URL"
qemu-img create -q -f qcow2 -F qcow2 -b "$WORK"/base.img "$WORK"/root.qcow2 8G
cloud-localds "$WORK"/seed.iso "$HERE"/user-data
timeout 900 qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
    -display none -serial file:"$OUT"/firstboot.log -no-reboot \
    -drive file="$WORK"/root.qcow2,if=virtio,format=qcow2 \
    -drive file="$WORK"/seed.iso,media=cdrom -nic user
echo "first boot done"

# The pool and the baseline both sit on loop devices with direct I/O
# over files on the same file system, so neither gets the host page
# cache.
truncate -s 24G "$WORK"/pool.img "$WORK"/plain.img
POOLDEV=$(sudo losetup --direct-io=on -f --show "$WORK"/pool.img)
PLAINDEV=$(sudo losetup --direct-io=on -f --show "$WORK"/plain.img)
# A first run set zfs_arc_max=256M at run time and still saw 1 GiB of ARC
# data.  Record what the module did with the value, set at run time and
# then at load time, before relying on either.
ARC_MAX=$((256 * 1024 * 1024))
arc_limits() {	# arc_limits <label>
	{
		echo "== $1"
		echo "zfs_arc_max parameter: $(cat /sys/module/zfs/parameters/zfs_arc_max)"
		awk '$1 ~ /^(c|c_min|c_max|size)$/ { print $1, $3 }' \
		    /proc/spl/kstat/zfs/arcstats
	} >> "$OUT"/arc-limits.txt
}
free -b > "$OUT"/arc-limits.txt
arc_limits "module loaded with defaults"
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
arc_limits "after writing $ARC_MAX at run time"
{ sudo dmesg | grep -i "ignoring tunable" || echo "(no ignoring-tunable message)"; } \
    >> "$OUT"/arc-limits.txt
sudo ./scripts/zfs.sh -u
echo "options zfs zfs_arc_max=$ARC_MAX" | sudo tee /etc/modprobe.d/zfs-arc.conf
"$HERE"/../load.sh .
arc_limits "after loading with zfs_arc_max=$ARC_MAX in modprobe.d"
# scripts/zfs.sh hands modprobe the path of the in-tree zfs.ko, so the
# modprobe.d line may not reach the module; the values above show
# whether it did.  arc_tuning_update() takes zfs_arc_min first and only
# accepts a maximum above arc_c_min, so lower the minimum, then set the
# maximum.
echo $((ARC_MAX / 2)) | sudo tee /sys/module/zfs/parameters/zfs_arc_min >/dev/null
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
arc_limits "after writing zfs_arc_min=$((ARC_MAX / 2)) then zfs_arc_max=$ARC_MAX at run time"
cat "$OUT"/arc-limits.txt

sudo "$ZPOOL" create -f -o ashift=12 -O atime=off tank "$POOLDEV"

arc() {	# arc <file>: snapshot of the arcstats fields we report
	awk '$1 ~ /^(c|c_max|size|data_size|metadata_size|dbuf_size|hits|misses)$/ \
	    { print $1, $3 }' /proc/spl/kstat/zfs/arcstats > "$1"
}

boot() {	# boot <name> <device> <iothread> <aio> <pct>
	name=$1 dev=$2 iot=$3 aio=$4 pct=$5
	d="$OUT/$name"
	mkdir -p "$d" "$WORK/ctrl"
	rm -rf "${WORK:?}"/ctrl/*
	cp "$HERE"/guest-run.sh "$WORK"/ctrl/run.sh
	printf 'PCT=%s\nRUNTIME=%s\nREPEATS=%s\n' "$pct" "$RUNTIME" \
	    "$REPEATS" > "$WORK"/ctrl/conf
	rm -f "$WORK"/ctrl.img
	mke2fs -q -t ext4 -d "$WORK"/ctrl "$WORK"/ctrl.img 64M

	if [ "$iot" = 1 ]; then
		iobj="-object iothread,id=io1"
		idev=",iothread=io1"
	else
		iobj=""
		idev=""
	fi

	arc "$d"/arc.before
	# shellcheck disable=SC2086
	if ! sudo timeout 420 qemu-system-x86_64 -enable-kvm -cpu host \
	    -smp 2 -m 2048 -display none -serial file:"$d"/serial.log \
	    -no-reboot -nic none $iobj \
	    -drive file="$WORK"/root.qcow2,if=none,id=r,format=qcow2 \
	    -device virtio-blk-pci,drive=r,bootindex=0 \
	    -drive file="$dev",format=raw,if=none,id=t,cache=none,aio="$aio" \
	    -device virtio-blk-pci,drive=t,serial=TEST$idev \
	    -drive file="$WORK"/ctrl.img,format=raw,if=none,id=c \
	    -device virtio-blk-pci,drive=c,serial=CTRL \
	    2> "$d"/qemu.err; then
		echo "$name: qemu failed: $(head -3 "$d"/qemu.err)"
	fi
	arc "$d"/arc.after
	# Copy the guest's files back out of the CTRL image.
	debugfs -R 'ls -p /' "$WORK"/ctrl.img 2>/dev/null |
	    awk -F/ '$6 != "" && $6 != "." && $6 != ".." && $6 != "lost+found" \
	    { print $6 }' | while read -r f; do
		debugfs -R "dump /$f $d/$f" "$WORK"/ctrl.img >/dev/null 2>&1
	done
	if [ ! -f "$d"/status ]; then
		echo "$name: no results"
		return 1
	fi
}

first=1
grep -v '^#' "$HERE"/configs | while read -r name be bs iot aio direct comp pct; do
	[ -n "$name" ] || continue
	echo "== $name"
	case $be in
	loop)
		dev=$PLAINDEV
		;;
	zvol)
		sudo "$ZFS" create -V 2G -o volblocksize="$bs" \
		    -o compression="$comp" -o direct="$direct" tank/vol
		sudo udevadm settle
		dev=/dev/zvol/tank/vol
		;;
	file)
		sudo "$ZFS" create -o recordsize="$bs" -o compression="$comp" \
		    -o direct="$direct" tank/fs
		sudo truncate -s 2G /tank/fs/disk.img
		dev=/tank/fs/disk.img
		;;
	esac
	# A failure on the first configuration is the rig, not the backing;
	# stop rather than spend the job on timeouts.
	if ! boot "$name" "$dev" "$iot" "$aio" "$pct" && [ "$first" = 1 ]; then
		echo "first configuration failed; stopping"
		exit 1
	fi
	first=0
	# Output is ours; only the zfs command needs root.
	{ sudo "$ZFS" get -H -o name,property,value compression,compressratio,direct \
	    tank/vol tank/fs 2>/dev/null || true; } > "$OUT/$name/zfs.props"
	sudo "$ZFS" destroy tank/vol 2>/dev/null || true
	sudo "$ZFS" destroy tank/fs 2>/dev/null || true
done

"$HERE"/reflink.sh "$OUT" || echo "reflink step failed"
"$HERE"/summarise.sh "$OUT" | tee "$OUT"/summary.md |
    tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
