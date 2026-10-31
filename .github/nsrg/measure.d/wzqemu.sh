#!/bin/sh
# wzqemu.sh <label> <srcdir> <outdir>: QEMU's block layer writing zeroes
# to a zvol.  With detect-zeroes=unmap it turns an all-zero write into a
# write-zeroes that may unmap; with detect-zeroes=off it writes the data.
# qemu-io goes through the same block layer a guest's disk does.
set -eu
label=$1 out=$3
here=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=.github/nsrg/wz/common.sh
. "$here"/.github/nsrg/wz/common.sh
sudo apt-get install -y -qq qemu-utils bpftrace >/dev/null
wz_setup "$2"
for dz in off unmap; do
	sudo dd if=/dev/urandom of=/dev/"$dev" bs=1M count=64 \
	    oflag=direct status=none
	before=$(wz_ref)
	wz_trace_start "$out"/bios-$dz.txt
	sudo qemu-io -n --image-opts \
	    "driver=host_device,filename=/dev/$dev,discard=unmap,detect-zeroes=$dz" \
	    -c "write -P 0 0 64M" >/dev/null
	wz_trace_stop
	after=$(wz_ref)
	{
		echo "== $label $(uname -r) $dev detect-zeroes=$dz"
		echo "referenced: before $before, after $after"
		echo "bios by op (1=write 3=discard 9=write-zeroes):"
		grep '@op' "$out"/bios-$dz.txt || cat "$out"/bios-$dz.txt
	} | tee -a "$out"/summary.md
done
qemu-io --version | head -1 | tee -a "$out"/summary.md
wz_teardown
