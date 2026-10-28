#!/bin/sh
# mkguest.sh <outdir>: a minimal Linux guest that runs one fio job on
# /dev/vda and powers off.  The same kernel and initramfs are booted
# under KVM on the runner and under NVMM inside the NetBSD VM, so the
# two numbers differ only in the hypervisor path.
set -eu
out=$1
mkdir -p "$out"
work=$(mktemp -d)

sudo apt-get install -y -q busybox-static zstd libaio-dev >/dev/null

# fio, static, so the initramfs needs no libraries.
git clone -q --depth 1 --branch fio-3.42 https://github.com/axboe/fio.git \
    "$work/fio"
(cd "$work/fio" && ./configure --build-static --disable-native >/dev/null &&
    make -s -j"$(nproc)" fio)

kver=$(uname -r)
# /boot/vmlinuz-* is mode 600 on the runner.
sudo cp "/boot/vmlinuz-$kver" "$out/vmlinuz"
sudo chmod 644 "$out/vmlinuz"

root=$work/root
mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys" "$root/lib/mod"
cp /bin/busybox "$root/bin/busybox"
cp "$work/fio/fio" "$root/bin/fio"

# virtio_blk and virtio_pci, when the runner kernel builds them as
# modules: dependency order from modprobe, decompressed for busybox.
: > "$root/lib/mod/order"
modprobe --show-depends virtio_pci virtio_blk 2>/dev/null |
    awk '$1 == "insmod" { print $2 }' | awk '!seen[$0]++' |
    while read -r ko; do
	name=$(basename "$ko" | sed 's/\.zst$//; s/\.xz$//')
	case $ko in
	*.zst)	zstd -q -d -c "$ko" > "$root/lib/mod/$name" ;;
	*.xz)	xz -d -c "$ko" > "$root/lib/mod/$name" ;;
	*)	cp "$ko" "$root/lib/mod/$name" ;;
	esac
	echo "$name" >> "$root/lib/mod/order"
    done
echo "modules: $(tr '\n' ' ' < "$root/lib/mod/order")"
sudo grep -E '^CONFIG_VIRTIO_(BLK|PCI)=' "/boot/config-$kver" || true

cat > "$root/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
while read -r m; do insmod "/lib/mod/$m"; done < /lib/mod/order
sleep 1
fio --name=warm --filename=/dev/vda --rw=read --bs=1M --direct=1 \
    --ioengine=psync --size=1G > /dev/null
echo FIO-BEGIN
fio --name=qd1 --filename=/dev/vda --rw=randread --bs=4k --direct=1 \
    --ioengine=psync --iodepth=1 --size=1G --time_based --runtime=20 \
    --output-format=json
echo FIO-END
poweroff -f
INIT
chmod +x "$root/init"
(cd "$root" && find . | cpio -o -H newc 2>/dev/null | gzip -1) \
    > "$out/initrd.gz"
ls -l "$out"
