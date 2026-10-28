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
fio --version > fio-version

common="--filename=$D --direct=1 --size=1G --time_based --runtime=$RUNTIME
    --buffer_compress_percentage=$PCT --refill_buffers --randrepeat=0
    --output-format=json"

# Precondition the region so reads hit allocated blocks.
# shellcheck disable=SC2086
fio --name=fill --filename=$D --direct=1 --size=1G --rw=write --bs=1M \
    --ioengine=libaio --iodepth=8 --buffer_compress_percentage=$PCT \
    --refill_buffers --output-format=json > fill.json

r=1
while [ $r -le "$REPEATS" ]; do
	# shellcheck disable=SC2086
	{
	fio --name=qd1-randread $common --rw=randread --bs=4k \
	    --ioengine=libaio --iodepth=1 > qd1-randread.$r.json
	fio --name=qd1-randwrite $common --rw=randwrite --bs=4k \
	    --ioengine=libaio --iodepth=1 > qd1-randwrite.$r.json
	fio --name=qd1-fsyncwrite $common --rw=randwrite --bs=4k \
	    --ioengine=psync --fsync=1 > qd1-fsyncwrite.$r.json
	fio --name=qd32-randread $common --rw=randread --bs=4k \
	    --ioengine=libaio --iodepth=32 > qd32-randread.$r.json
	fio --name=qd32-randwrite $common --rw=randwrite --bs=4k \
	    --ioengine=libaio --iodepth=32 > qd32-randwrite.$r.json
	}
	r=$((r + 1))
done
echo finished > status
