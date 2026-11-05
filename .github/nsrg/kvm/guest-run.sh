#!/bin/sh
# guest-run.sh: runs inside the guest from the CTRL disk.  The disk
# under test has serial TEST.  Results go back on the CTRL disk.
set -u
C=/mnt/c
D=/dev/disk/by-id/virtio-TEST
# shellcheck source=/dev/null
. "$C"/conf
cd "$C" || exit 1
uname -r > kernel
fio --name=fill --filename=$D --direct=1 --size=1G --rw=write --bs=1M \
    --ioengine=libaio --iodepth=8 --output-format=json > fill.json
for q in $QDS; do
	fio --name=q$q --filename=$D --direct=1 --sync=1 --size=1G \
	    --time_based --runtime="$RUNTIME" --randrepeat=0 --rw=randwrite \
	    --bs=4k --ioengine=libaio --iodepth=$q --output-format=json \
	    > qd$q.json
done
echo finished > status
