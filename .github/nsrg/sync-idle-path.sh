#!/bin/sh
# sync-idle-path.sh: prove which path zvol_request_sync_idle sends each
# request down, on the bio and the blk-mq paths.  zvol_write_task and
# zvol_read_task are reached only through the taskq, so with N requests
# of known depth the kprobe hits count what was not run inline.  A
# control with the tunable off must count every request, which shows
# the probes work.  Fails if a count is outside its expected range.
set -eu

HERE=$(pwd)
OUT=/var/tmp/bench
T=/sys/kernel/tracing
N=65536		# requests of 4k in 256M
SIZE=256M
mkdir -p "$OUT"
"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"

param() {	# param <name> <value>
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
}

sudo sh -c "echo 'p:sip/sipwt zvol_write_task' >> $T/kprobe_events
    echo 'p:sip/siprt zvol_read_task' >> $T/kprobe_events
    echo 1 > $T/events/sip/enable"

hits() {	# hits <event>
	sudo awk -v e="$1" '$1 == e || $1 == "sip/" e { print $2 }' \
	    $T/kprobe_profile
}

sudo truncate -s 2G /dev/shm/vdev
VDEV=$(sudo losetup -f --show /dev/shm/vdev)
fail=0

# phase <name> <event> <lo> <hi> <fio args>: one fixed-size fio run
phase() {
	name=$1 ev=$2 lo=$3 hi=$4
	shift 4
	h0=$(hits "$ev")
	sudo fio --name=p --filename="$VOL" --bs=4k --size=$SIZE --direct=1 \
	    --randrepeat=0 --group_reporting "$@" >/dev/null
	h1=$(hits "$ev")
	c=$((h1 - h0))
	r=ok
	if [ "$c" -lt "$lo" ] || [ "$c" -gt "$hi" ]; then
		r=FAIL
		fail=1
	fi
	printf 'blk_mq=%s\t%s\t%s\ttaskq=%d\texpect %d-%d\t%s\n' "$mq" "$name" \
	    "$ev" "$c" "$lo" "$hi" "$r" | tee -a "$OUT"/path.txt
}

for mq in 0 1; do
	param zvol_use_blk_mq $mq
	param zvol_request_sync_idle 0
	sudo "$HERE"/zpool create -f -O compression=off sq "$VDEV"
	sudo "$HERE"/zfs create -V 512M -o volblocksize=4k \
	    -o compression=off sq/vol 2>/dev/null
	sudo udevadm settle
	VOL=/dev/$(ls /sys/block | grep '^zd' | head -1)

	phase control-off sipwt "$N" "$N" --rw=randwrite --ioengine=psync
	param zvol_request_sync_idle 1
	# One in 64 is a probe.  The first arrivals may still be in the
	# state the fill left.
	phase qd1-inline sipwt 950 1250 --rw=randwrite --ioengine=psync
	phase qd1-read siprt 950 1250 --rw=randread --ioengine=psync
	# Overlap: nearly everything to the taskq, after at most a probe
	phase qd16-overlap sipwt $((N * 99 / 100)) "$N" --rw=randwrite \
	    --ioengine=libaio --iodepth=16
	# Sustained idle returns: 64 to the taskq, then one in 64 again
	phase qd1-recovered sipwt 950 1350 --rw=randwrite --ioengine=psync
	phase jobs4-overlap sipwt $((N * 4 * 9 / 10)) $((N * 4)) \
	    --rw=randwrite --ioengine=libaio --iodepth=1 --numjobs=4
	param zvol_request_sync_idle 0
	sudo "$HERE"/zpool destroy sq
done
param zvol_use_blk_mq 0
sudo sh -c "echo 0 > $T/events/sip/enable; echo > $T/kprobe_events" || true
sudo losetup -d "$VDEV"
sudo rm -f /dev/shm/vdev
tee -a "$GITHUB_STEP_SUMMARY" < "$OUT"/path.txt
exit $fail
