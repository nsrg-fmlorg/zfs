#!/bin/sh
# wzext4.sh <label> <srcdir> <outdir>: ext4 on a zvol.  ext4lazyinit
# zeroes inode tables with sb_issue_zeroout(), and splitting an
# unwritten extent zeroes the small pieces with ext4_issue_zeroout().
set -eu
label=$1 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=.github/nsrg/wz/common.sh
. "$here"/.github/nsrg/wz/common.sh
sudo apt-get install -y -qq bpftrace >/dev/null
wz_setup "$2"
r0=$(wz_ref)
sudo mkfs.ext4 -q -F -E nodiscard,lazy_itable_init=1 /dev/"$dev"
r1=$(wz_ref)

# 1: inode tables, zeroed by ext4lazyinit right after mount.
wz_trace_start "$out"/bios-lazyinit.txt
sudo mkdir -p /mnt/wz
sudo mount -o init_itable=0 /dev/"$dev" /mnt/wz
i=0
while [ $i -lt 120 ] && pgrep -x ext4lazyinit >/dev/null; do
	sleep 1
	i=$((i + 1))
done
sync
wz_trace_stop
r2=$(wz_ref)

# 2: an unwritten extent, split by a small direct write in its middle;
# pieces under extent_max_zeroout_kb are zeroed instead of split.
wz_trace_start "$out"/bios-extent.txt
sudo fallocate -l 64M /mnt/wz/f
sudo dd if=/dev/urandom of=/mnt/wz/f bs=4k count=1 seek=3 \
    oflag=direct conv=notrunc status=none
sync
wz_trace_stop
sudo umount /mnt/wz
r3=$(wz_ref)

{
	echo "== $label $(uname -r) $dev"
	echo "referenced: empty $r0, mkfs $r1, after lazyinit $r2 (${i}s), after extent split $r3"
	echo "lazyinit bios by op (1=write 3=discard 9=write-zeroes):"
	grep '@op' "$out"/bios-lazyinit.txt || cat "$out"/bios-lazyinit.txt
	echo "extent split bios by op:"
	grep '@op' "$out"/bios-extent.txt || cat "$out"/bios-extent.txt
} | tee "$out"/summary.md
wz_teardown
