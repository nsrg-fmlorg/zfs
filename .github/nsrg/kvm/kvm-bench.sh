#!/bin/sh
# kvm-bench.sh: O_SYNC 4k random writes from a KVM guest whose virtio-blk
# disk is a zvol with cache=none, at queue depth 1, 4 and 16, with
# zvol_request_sync_idle off, on, and off again as an A/A, for aio=native
# and aio=threads, on the bio and blk-mq paths.  The pool is on a loop
# device over /dev/shm: on the runner's disk a queue depth 1 write took
# 3.5 ms and two identical runs differed by 30%, which hides the path
# being measured.  The order of the variants rotates each round, because
# later runs measure lower.  A boot at queue depth 1 alone then counts
# how many of a guest's requests really ran inline.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ZFS=$(pwd)/zfs
ZPOOL=$(pwd)/zpool
OUT=/var/tmp/kvm
T=/sys/kernel/tracing
RUNTIME=${RUNTIME:-10}
ROUNDS=${ROUNDS:-5}
IMG_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

mkdir -p "$OUT"
if [ -d /mnt ] && [ "$(df -BG --output=avail /mnt | tail -1 | tr -dc 0-9)" -gt 40 ]; then
	WORK=/mnt/kvm
else
	WORK=/var/tmp/kvmwork
fi
sudo mkdir -p "$WORK"
sudo chown "$(id -u)" "$WORK"
sudo chmod 666 /dev/kvm

curl -fsSL -o "$WORK"/base.img "$IMG_URL"
qemu-img create -q -f qcow2 -F qcow2 -b "$WORK"/base.img "$WORK"/root.qcow2 8G
cloud-localds "$WORK"/seed.iso "$HERE"/user-data
timeout 900 qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 2048 \
    -display none -serial file:"$OUT"/firstboot.log -no-reboot \
    -drive file="$WORK"/root.qcow2,if=virtio,format=qcow2 \
    -drive file="$WORK"/seed.iso,media=cdrom -nic user
echo "first boot done"

sudo truncate -s 5G /dev/shm/pool.img
POOLDEV=$(sudo losetup -f --show /dev/shm/pool.img)
sudo "$ZPOOL" create -f -o ashift=12 -O atime=off tank "$POOLDEV"
echo $((256 * 1024 * 1024)) |
    sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null

param() {	# param <name> <value>
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
}

# Requests that went to the taskq, of all that entered the driver
# zvol_request_impl() is inlined; these two are its callers.
sudo sh -c "echo 'p:kv/kvwt zvol_write_task' >> $T/kprobe_events
    echo 'p:kv/kvbio zvol_submit_bio' >> $T/kprobe_events
    echo 'p:kv/kvmq zvol_mq_queue_rq' >> $T/kprobe_events
    echo 1 > $T/events/kv/enable"
hits() {
	sudo awk -v e="$1" '$1 == e || $1 == "kv/" e { n = $2 }
	    END { print n + 0 }' $T/kprobe_profile
}
requests() { echo $(($(hits kvbio) + $(hits kvmq))); }

boot() {	# boot <dir> <aio>
	d=$1 aio=$2
	mkdir -p "$d" "$WORK/ctrl"
	rm -rf "${WORK:?}"/ctrl/*
	cp "$HERE"/guest-run.sh "$WORK"/ctrl/run.sh
	printf 'RUNTIME=%s\nQDS="%s"\n' "$RUNTIME" "$QDS" > "$WORK"/ctrl/conf
	rm -f "$WORK"/ctrl.img
	mke2fs -q -t ext4 -d "$WORK"/ctrl "$WORK"/ctrl.img 64M
	if ! sudo timeout 420 qemu-system-x86_64 -enable-kvm -cpu host \
	    -smp 2 -m 2048 -display none -serial file:"$d"/serial.log \
	    -no-reboot -nic none \
	    -drive file="$WORK"/root.qcow2,if=none,id=r,format=qcow2 \
	    -device virtio-blk-pci,drive=r,bootindex=0 \
	    -drive file=/dev/zvol/tank/vol,format=raw,if=none,id=t,cache=none,aio="$aio" \
	    -device virtio-blk-pci,drive=t,serial=TEST \
	    -drive file="$WORK"/ctrl.img,format=raw,if=none,id=c \
	    -device virtio-blk-pci,drive=c,serial=CTRL \
	    2> "$d"/qemu.err; then
		echo "$d: qemu failed: $(head -3 "$d"/qemu.err)"
	fi
	debugfs -R 'ls -p /' "$WORK"/ctrl.img 2>/dev/null |
	    awk -F/ '$6 != "" && $6 != "." && $6 != ".." && $6 != "lost+found" \
	    { print $6 }' | while read -r f; do
		debugfs -R "dump /$f $d/$f" "$WORK"/ctrl.img >/dev/null 2>&1
	done
	if [ ! -f "$d"/status ]; then
		echo "$d: no results"
		return 1
	fi
}

one() {	# one <round> <variant> <aio> <mq>
	r=$1 v=$2 aio=$3 mq=$4
	case $v in
	on)	param zvol_request_sync_idle 1 ;;
	*)	param zvol_request_sync_idle 0 ;;
	esac
	param zvol_use_blk_mq "$mq"
	sudo "$ZFS" create -V 2G -o volblocksize=4k -o compression=off \
	    tank/vol 2>/dev/null
	sudo udevadm settle
	d="$OUT/r$r-$v-$aio-mq$mq"
	w0=$(hits kvwt)
	q0=$(requests)
	boot "$d" "$aio"
	w=$(($(hits kvwt) - w0))
	q=$(($(requests) - q0))
	for qd in 1 4 16; do
		[ -f "$d"/qd$qd.json ] || continue
		jq -r --arg v "$v" --arg a "$aio" --arg m "$mq" --arg q "$qd" \
		    --arg r "$r" '.jobs[0].write as $d | [$v, $a, $m, $q, $r,
		    ($d.iops | floor), ($d.clat_ns.mean / 1000 | floor),
		    ($d.clat_ns.percentile["99.000000"] / 1000 | floor)]
		    | @tsv' "$d"/qd$qd.json >> "$OUT"/raw.tsv
	done
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$aio" "$mq" "$r" "$w" "$q" \
	    >> "$OUT"/path.tsv
	param zvol_request_sync_idle 0
	sudo "$ZFS" destroy tank/vol
}

QDS="1 4 16"
r=0
while [ "$r" -lt "$ROUNDS" ]; do
	case $((r % 3)) in
	0)	order="off on aa" ;;
	1)	order="on aa off" ;;
	2)	order="aa off on" ;;
	esac
	for mq in 0 1; do
		for aio in native threads; do
			for v in $order; do
				one "$r" "$v" "$aio" "$mq"
			done
		done
	done
	r=$((r + 1))
done
QDS=1
for mq in 0 1; do
	for aio in native threads; do
		one qd1 on "$aio" "$mq"
	done
done
param zvol_use_blk_mq 0
sudo "$ZPOOL" destroy tank
sudo sh -c "echo 0 > $T/events/kv/enable; echo > $T/kprobe_events" || true
sudo losetup -d "$POOLDEV"
sudo rm -f /dev/shm/pool.img

awk -F'\t' '
    $5 != "qd1" {
	k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $1
	n[k]++; s[k] += $6; c[k] += $7; p[k] += $8
	if (!(k in lo) || $6 < lo[k]) lo[k] = $6
	if (!(k in hi) || $6 > hi[k]) hi[k] = $6
    }
    END {
	for (k in n) {
		split(k, a, SUBSEP)
		b = a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP "off"
		printf "%s\t%s\t%s\t%s\t%d\t%d\t%d-%d\t%d\t%d\t%.3f\n",
		    a[1], a[2], a[3], a[4], n[k], s[k] / n[k], lo[k], hi[k],
		    c[k] / n[k], p[k] / n[k], (s[k] / n[k]) / (s[b] / n[b])
	}
    }' "$OUT"/raw.tsv | sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3n -k4,4 \
    > "$OUT"/sorted.tsv
{
	printf 'aio\tmq\tqd\tlabel\tn\tiops\tmin-max\tclat\tp99\tvs off\n'
	cat "$OUT"/sorted.tsv
} > "$OUT"/summary.tsv
awk -F'\t' '$4 == "qd1" { printf "qd1 %s mq%s: taskq %d of %d requests\n",
    $2, $3, $5, $6 }' "$OUT"/path.tsv | sort > "$OUT"/path.txt
column -t -s "$(printf '\t')" "$OUT"/summary.tsv |
    tee -a "$GITHUB_STEP_SUMMARY"
tee -a "$GITHUB_STEP_SUMMARY" < "$OUT"/path.txt
