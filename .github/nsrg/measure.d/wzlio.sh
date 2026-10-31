#!/bin/sh
# wzlio.sh <label> <srcdir> <outdir>: an iSCSI initiator writing zeroes
# to a LIO target whose backstore is a zvol.  The initiator's
# BLKZEROOUT becomes a WRITE SAME, and LIO's iblock backend answers a
# zero payload with blkdev_issue_zeroout() on the zvol.
set -eu
label=$1 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=.github/nsrg/wz/common.sh
. "$here"/.github/nsrg/wz/common.sh
iqn=iqn.2026-10.org.example:wz
sudo apt-get install -y -qq targetcli-fb open-iscsi bpftrace >/dev/null
for m in target_core_mod target_core_iblock iscsi_target_mod; do
	if ! sudo modprobe "$m"; then
		echo "== $label: module $m is not available on $(uname -r)" |
		    tee -a "$out"/summary.md
		exit 0
	fi
done
sudo systemctl start iscsid
cleanup() {
	sudo iscsiadm -m node -T "$iqn" -p 127.0.0.1 --logout \
	    >/dev/null 2>&1 || true
	sudo targetcli clearconfig confirm=True >/dev/null 2>&1 || true
	sudo "$src"/zpool destroy -f wz 2>/dev/null || true
	sudo rm -f /var/tmp/wz-vdev
}
trap cleanup EXIT
wz_setup "$2"
sudo targetcli /backstores/block create name=wz dev=/dev/"$dev" >/dev/null
sudo targetcli /iscsi create "$iqn" >/dev/null
sudo targetcli /iscsi/"$iqn"/tpg1/luns create /backstores/block/wz >/dev/null
sudo targetcli /iscsi/"$iqn"/tpg1 set attribute authentication=0 \
    demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1 \
    >/dev/null
sudo iscsiadm -m discovery -t st -p 127.0.0.1 >/dev/null
sudo iscsiadm -m node -T "$iqn" -p 127.0.0.1 --login >/dev/null
sudo udevadm settle
sd=$(basename "$(readlink -f /dev/disk/by-path/*"$iqn"-lun-0)")
sudo dd if=/dev/urandom of=/dev/"$sd" bs=1M count=64 oflag=direct status=none
before=$(wz_ref)
wz_trace_start "$out"/bios.txt
sudo blkdiscard -z -o 0 -l 64M /dev/"$sd"
sync
wz_trace_stop
after=$(wz_ref)
{
	echo "== $label $(uname -r) zvol $dev, initiator disk $sd"
	echo "initiator write_zeroes_max_bytes $(cat /sys/block/"$sd"/queue/write_zeroes_max_bytes)"
	echo "referenced: before $before, after $after"
	echo "bios reaching the zvol by op (1=write 3=discard 9=write-zeroes):"
	grep '@op' "$out"/bios.txt || cat "$out"/bios.txt
} | tee "$out"/summary.md
