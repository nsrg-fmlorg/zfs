#!/bin/sh
# run-nvmm.sh <guestdir>: the same guest under qemu -accel nvmm in the
# NetBSD VM.  dtrace counts qemu's ioctl(2) calls (each VCPU_RUN return
# is one exit handled in userspace) and the time spent in them.
# execname is p_comm, cut to MAXCOMLEN (16): "qemu-system-x86_".
set -u
g=$1
truncate -s 1G "$g/disk.img"
for m in solaris dtrace dtrace_systrace systrace fbt sdt; do
	modload "$m" 2>/dev/null || true
done
modstat | grep -E 'dtrace|systrace|fbt' || true
dtrace -q -o "$g/nvmm.dtrace" -n '
syscall::ioctl:entry /execname == "qemu-system-x86_"/ { self->t = timestamp; }
syscall::ioctl:return /self->t/ {
	@n["ioctl calls"] = count();
	@s["ioctl ns total"] = sum(timestamp - self->t);
	@q["ioctl ns"] = quantize(timestamp - self->t);
	self->t = 0;
}' &
dpid=$!
sleep 3
start=$(date +%s)
timeout 180 qemu-system-x86_64 -accel nvmm -smp 1 -m 512 \
    -display none -no-reboot -serial "file:$g/nvmm.serial" \
    -kernel "$g/vmlinuz" -initrd "$g/initrd.gz" \
    -append "console=ttyS0 quiet" \
    -drive "file=$g/disk.img,if=virtio,format=raw"
echo "qemu exit: $? after $(( $(date +%s) - start ))s"
kill -INT "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
cat "$g/nvmm.dtrace" 2>/dev/null || echo "no dtrace output"
rm -f "$g/disk.img"
