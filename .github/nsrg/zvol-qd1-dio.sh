#!/bin/sh
# zvol-qd1-dio.sh: zvol latency at queue depth 1 with the inline request
# handling (zvol_request_sync_idle, zfs_vdev_disk_calling_thread_io) and
# Direct I/O (direct=always) combined, against a raw loop device.
#
# Vdevs and the raw baseline are loop devices over /dev/shm files: not
# NVMe.  The device time is near zero, so the software path is measured.
# Every tunable is read back after it is written and recorded with the
# result, with the ARC limit in force and any tunable the kernel refused.
set -eu

OUT=/var/tmp/qd1
HERE=$(pwd)
ROUNDS=3
RUNTIME=10
SIZE=2G
mkdir -p "$OUT"

"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"

param() {	# param <name> <value>: write, then fail if it did not take
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
	[ "$(cat /sys/module/zfs/parameters/"$1")" = "$2" ] || {
		echo "param $1=$2 did not take" >&2
		exit 1
	}
}

# Hold the ARC to 1G so a run reflects the cache it is given; arc.c
# ignores zfs_arc_max unless it is above arc_c_min, so lower that first.
param zfs_arc_min $((64 * 1024 * 1024))
param zfs_arc_max $((1024 * 1024 * 1024))

arcstat() { awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/arcstats; }
iostat() { awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/qd1/iostats; }
ctxt() { awk '/^ctxt/ { print $2 }' /proc/stat; }

loopdev() {
	sudo truncate -s 4G /dev/shm/"$1"
	sudo losetup -f --show /dev/shm/"$1"
}

# fio_qd1 <label> <target> <rw> [fio args]: appends
# label rw iops mean p50 p99 p99.9 (usec) ctxsw/io data_size(MiB) dio
fio_qd1() {
	label=$1 target=$2 rw=$3
	shift 3
	c0=$(ctxt)
	d0=0
	[ "$target" = "$RAW" ] ||
	    d0=$(($(iostat direct_read_count) + $(iostat direct_write_count)))
	# last.json belongs to us, not to root.
	# shellcheck disable=SC2024
	sudo fio --name=qd1 --filename="$target" --rw="$rw" --bs=4k \
	    --iodepth=1 --numjobs=1 --direct=1 --ioengine=psync \
	    --size="$SIZE" --time_based --runtime="$RUNTIME" \
	    --randrepeat=0 --output-format=json "$@" > "$OUT"/last.json
	c1=$(ctxt)
	dio=0
	[ "$target" = "$RAW" ] ||
	    dio=$(($(iostat direct_read_count) + $(iostat direct_write_count) -
	    d0))
	jq -r --arg l "$label" --arg rw "$rw" --argjson cs $((c1 - c0)) \
	    --argjson ds $(($(arcstat data_size) / 1048576)) \
	    --argjson dio "$dio" '
	    .jobs[0] as $j
	    | (if $rw == "randread" then $j.read else $j.write end) as $d
	    | [$l, $rw, ($d.iops | floor),
	       ($d.clat_ns.mean / 1000 | floor),
	       ($d.clat_ns.percentile["50.000000"] / 1000 | floor),
	       ($d.clat_ns.percentile["99.000000"] / 1000 | floor),
	       ($d.clat_ns.percentile["99.900000"] / 1000 | floor),
	       (($cs / ($d.total_ios + 1)) * 100 | floor / 100), $ds, $dio]
	    | @tsv' "$OUT"/last.json >> "$OUT"/raw.tsv
}

workloads() {	# workloads <label> <target>
	fio_qd1 "$1" "$2" randread
	fio_qd1 "$1" "$2" randwrite
	fio_qd1 "$1"-osync "$2" randwrite --sync=1
}

record() {	# record <label>: the tunables a result ran with
	{
		printf '%s' "$1"
		for p in zvol_request_sync zvol_request_sync_idle \
		    zfs_vdev_disk_calling_thread_io zfs_arc_max; do
			printf ' %s=%s' "$p" \
			    "$(cat /sys/module/zfs/parameters/$p)"
		done
		printf ' c_max=%s direct=%s\n' "$(arcstat c_max)" \
		    "$(sudo "$HERE"/zfs get -H -o value direct qd1/vol)"
	} >> "$OUT"/params.txt
}

RAW=$(loopdev raw)
VDEV=$(loopdev vdev)

# Reads go to the vdev, not the ARC: a guest's working set is usually
# larger than the cache it gets.
make_zvol() {	# make_zvol <volblocksize>
	sudo "$HERE"/zpool destroy qd1 2>/dev/null || true
	sudo "$HERE"/zpool create -f -O compression=off qd1 "$VDEV"
	sudo "$HERE"/zfs create -V "$SIZE" -o volblocksize="$1" \
	    -o primarycache=metadata -o compression=off qd1/vol
	sudo udevadm settle
	sudo dd if=/dev/urandom of=/dev/zvol/qd1/vol bs=1M count=2048 \
	    oflag=direct status=none
}

variant() {	# variant <default|syncidle|syncidle-callthr>
	param zvol_request_sync 0
	param zvol_request_sync_idle 0
	param zfs_vdev_disk_calling_thread_io 0
	case $1 in
	syncidle)		param zvol_request_sync_idle 1 ;;
	syncidle-callthr)	param zvol_request_sync_idle 1
				param zfs_vdev_disk_calling_thread_io 1 ;;
	esac
}

i=0
while [ $i -lt $ROUNDS ]; do
	sudo dd if=/dev/urandom of="$RAW" bs=1M count=2048 oflag=direct \
	    status=none
	workloads raw "$RAW"
	for vbs in 16k 4k; do
		make_zvol $vbs
		for d in standard always; do
			sudo "$HERE"/zfs set direct=$d qd1/vol
			for v in default syncidle syncidle-callthr; do
				variant $v
				record "zvol$vbs-$d-$v"
				workloads "zvol$vbs-$d-$v" /dev/zvol/qd1/vol
			done
		done
		# A/A: the first configuration again, for the noise.
		sudo "$HERE"/zfs set direct=standard qd1/vol
		variant default
		workloads "zvol$vbs-standard-default-aa" /dev/zvol/qd1/vol
	done
	i=$((i + 1))
done
variant default

sudo dmesg | grep -iE 'ignoring tunable|unknown parameter' \
    >> "$OUT"/params.txt || true

awk -F'\t' '
    {
	k = $1 SUBSEP $2; n[k]++
	for (c = 3; c <= 10; c++) s[k, c] += $c
	if (!(k in lo) || $4 < lo[k]) lo[k] = $4
	if (!(k in hi) || $4 > hi[k]) hi[k] = $4
    }
    END {
	printf "label\trw\tiops\tmean\tmean min-max\tp50\tp99\tp99.9\tctxsw/io\tdata MiB\tdio\n"
	for (k in n) {
		split(k, a, SUBSEP)
		printf "%s\t%s\t%d\t%d\t%d-%d\t%d\t%d\t%d\t%.2f\t%d\t%d\n",
		    a[1], a[2], s[k, 3] / n[k], s[k, 4] / n[k], lo[k], hi[k],
		    s[k, 5] / n[k], s[k, 6] / n[k], s[k, 7] / n[k],
		    s[k, 8] / n[k], s[k, 9] / n[k], s[k, 10] / n[k]
	}
    }' "$OUT"/raw.tsv | sort > "$OUT"/summary.tsv
column -t -s "$(printf '\t')" "$OUT"/summary.tsv | tee -a "$GITHUB_STEP_SUMMARY"
sort -u "$OUT"/params.txt | tee -a "$GITHUB_STEP_SUMMARY"

sudo "$HERE"/zpool destroy qd1 || true
sudo losetup -d "$RAW" "$VDEV"
sudo rm -f /dev/shm/raw /dev/shm/vdev
