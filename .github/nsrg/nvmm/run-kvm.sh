#!/bin/sh
# run-kvm.sh <guestdir>: reference run of the guest under KVM on the
# runner, with KVM's exit counters read before and after.
set -eu
g=$1
truncate -s 1G "$g/disk.img"
sudo chmod 666 /dev/kvm
d=/sys/kernel/debug/kvm
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
snap() { for f in exits io_exits mmio_exits halt_exits; do
	printf '%s=%s ' "$f" "$(sudo cat "$d/$f" 2>/dev/null || echo NA)"; done; echo; }
# debugfs sums over live VMs only, so sample while the guest runs.
timeout 180 qemu-system-x86_64 -enable-kvm -cpu host -smp 1 -m 512 \
    -display none -no-reboot -serial "file:$g/kvm.serial" \
    -kernel "$g/vmlinuz" -initrd "$g/initrd.gz" \
    -append "console=ttyS0 quiet" \
    -drive "file=$g/disk.img,if=virtio,format=raw" &
qpid=$!
sleep 12
echo "t=12s: $(snap)"
sleep 10
echo "t=22s: $(snap)"
wait "$qpid"
.github/nsrg/nvmm/summary.sh "$g/kvm.serial"
