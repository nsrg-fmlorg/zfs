#!/bin/sh
# zvol-qd1.sh: per-I/O latency of a zvol at queue depth 1, as a guest of
# KVM or NVMM sees it, against the same medium used without ZFS.
#
# All vdevs and the raw baseline are loop devices over files in /dev/shm:
# not NVMe, and not the runner's disk.  The device time is therefore near
# zero and what is measured is the software path.  Loop is used so that
# the pool goes through vdev_disk, as it would on a real disk.
#
# Part 1 measures clat (mean, p50, p99, p99.9) for 4k random reads,
# writes and O_SYNC writes, over several variants, ROUNDS times each.
# Part 2 traces one round with bpftrace and splits the time by stage.
set -eu

OUT=/var/tmp/qd1
HERE=$(pwd)
ROUNDS=3
RUNTIME=10
SIZE=2G
# .github/nsrg/qd1-parts may name a subset of "clat trace".
PARTS=$(cat .github/nsrg/qd1-parts 2>/dev/null || echo clat trace)
mkdir -p "$OUT"

sudo apt-get install -y -q bpftrace >/dev/null 2>&1 ||
    echo "bpftrace could not be installed" | tee -a "$OUT"/notes

"$HERE"/.github/nsrg/build.sh "$HERE" release

param() {	# param <name> <value>
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
}

loopdev() {	# loopdev <name>: a loop device over a file in /dev/shm
	sudo truncate -s 4G /dev/shm/"$1"
	sudo losetup -f --show /dev/shm/"$1"
}

ctxt() { awk '/^ctxt/ { print $2 }' /proc/stat; }

# fio_qd1 <label> <target> <rw> [extra fio args]: one result line,
# (later arguments override the queue depth 1 defaults),
# label rw iops mean p50 p99 p999 (usec) ctxsw-per-io
fio_qd1() {
	label=$1 target=$2 rw=$3
	shift 3
	c0=$(ctxt)
	# last.json belongs to us, not to root.
	# shellcheck disable=SC2024
	sudo fio --name=qd1 --filename="$target" --rw="$rw" --bs=4k \
	    --iodepth=1 --numjobs=1 --direct=1 --ioengine=psync \
	    --size="$SIZE" --time_based --runtime="$RUNTIME" \
	    --randrepeat=0 --output-format=json "$@" > "$OUT"/last.json
	c1=$(ctxt)
	jq -r --arg l "$label" --arg rw "$rw" --argjson cs $((c1 - c0)) '
	    .jobs[0] as $j
	    | (if $rw == "randread" then $j.read else $j.write end) as $d
	    | [$l, $rw, ($d.iops | floor),
	       ($d.clat_ns.mean / 1000 | floor),
	       ($d.clat_ns.percentile["50.000000"] / 1000 | floor),
	       ($d.clat_ns.percentile["99.000000"] / 1000 | floor),
	       ($d.clat_ns.percentile["99.900000"] / 1000 | floor),
	       (($cs / ($d.total_ios + 1)) * 100 | floor / 100)]
	    | @tsv' "$OUT"/last.json >> "$OUT"/raw.tsv
}

workloads() {	# workloads <label> <target>
	fio_qd1 "$1" "$2" randread
	fio_qd1 "$1" "$2" randwrite
	fio_qd1 "$1"-osync "$2" randwrite --sync=1
}

"$HERE"/.github/nsrg/load.sh "$HERE"
RAW=$(loopdev raw)
VDEV=$(loopdev vdev)

# make_zvol <volblocksize>: fresh pool and zvol; reads go to the vdev,
# not the ARC, because a guest's working set is usually larger.
make_zvol() {
	sudo "$HERE"/zpool destroy qd1 2>/dev/null || true
	sudo "$HERE"/zpool create -f -O compression=off qd1 "$VDEV"
	sudo "$HERE"/zfs create -V "$SIZE" -o volblocksize="$1" \
	    -o primarycache=metadata -o compression=off qd1/vol
	sudo udevadm settle
	sudo dd if=/dev/urandom of=/dev/zvol/qd1/vol bs=1M count=2048 \
	    oflag=direct status=none
}

make_file() {	# make_file <recordsize>: a file on a dataset, O_DIRECT
	sudo "$HERE"/zpool destroy qd1 2>/dev/null || true
	sudo "$HERE"/zpool create -f -O compression=off qd1 "$VDEV"
	sudo "$HERE"/zfs create -o recordsize="$1" -o primarycache=metadata \
	    -o direct=always qd1/fs
	sudo dd if=/dev/urandom of=/qd1/fs/img bs=1M count=2048 status=none
}

i=0
case " $PARTS " in *" clat "*) ;; *) i=$ROUNDS ;; esac
while [ $i -lt $ROUNDS ]; do
	sudo dd if=/dev/urandom of="$RAW" bs=1M count=2048 oflag=direct \
	    status=none
	workloads raw "$RAW"
	for vbs in 16k 4k; do
		make_zvol $vbs
		workloads zvol$vbs /dev/zvol/qd1/vol
		workloads zvol$vbs-aa /dev/zvol/qd1/vol
		param zvol_request_sync 1
		workloads zvol$vbs-reqsync /dev/zvol/qd1/vol
		param zfs_vdev_disk_calling_thread_io 1
		workloads zvol$vbs-reqsync-callthr /dev/zvol/qd1/vol
		param zvol_request_sync 0
		param zfs_vdev_disk_calling_thread_io 0
		param zvol_request_sync_idle 1
		workloads zvol$vbs-syncidle /dev/zvol/qd1/vol
		param zfs_vdev_disk_calling_thread_io 1
		workloads zvol$vbs-syncidle-callthr /dev/zvol/qd1/vol
		param zfs_vdev_disk_calling_thread_io 0
		# The point of syncidle over reqsync: overlapping requests
		# from one submitter still go to the taskq.
		for v in default reqsync syncidle; do
			case $v in
			reqsync)	param zvol_request_sync 1 ;;
			syncidle)	param zvol_request_sync 0
					param zvol_request_sync_idle 1 ;;
			esac
			fio_qd1 zvol$vbs-$v-qd8 /dev/zvol/qd1/vol randread \
			    --ioengine=libaio --iodepth=8
		done
		param zvol_request_sync 0
		param zvol_request_sync_idle 0
		param zvol_use_blk_mq 1
		make_zvol $vbs
		workloads zvol$vbs-blkmq /dev/zvol/qd1/vol
		param zvol_use_blk_mq 0
		make_file $vbs
		workloads file$vbs-odirect /qd1/fs/img
	done
	i=$((i + 1))
done

# label rw: mean of each column, with min-max of the mean clat
[ ! -s "$OUT"/raw.tsv ] || awk -F'\t' '
    {
	k = $1 SUBSEP $2; n[k]++; order[k] = NR
	for (c = 3; c <= 8; c++) s[k, c] += $c
	if (!(k in lo) || $4 < lo[k]) lo[k] = $4
	if (!(k in hi) || $4 > hi[k]) hi[k] = $4
    }
    END {
	printf "label\trw\tiops\tmean\tmean min-max\tp50\tp99\tp99.9\tctxsw/io\n"
	for (k in n) {
		split(k, a, SUBSEP)
		printf "%s\t%s\t%d\t%d\t%d-%d\t%d\t%d\t%d\t%.2f\n",
		    a[1], a[2], s[k, 3] / n[k], s[k, 4] / n[k], lo[k], hi[k],
		    s[k, 5] / n[k], s[k, 6] / n[k], s[k, 7] / n[k],
		    s[k, 8] / n[k]
	}
    }' "$OUT"/raw.tsv | sort > "$OUT"/summary.tsv
[ ! -s "$OUT"/summary.tsv ] ||
    column -t -s "$(printf '\t')" "$OUT"/summary.tsv |
    tee -a "$GITHUB_STEP_SUMMARY"

# Part 2: stage breakdown, zvol 16k, default and fully inline.
if command -v bpftrace >/dev/null &&
    case " $PARTS " in *" trace "*) true ;; *) false ;; esac; then
	make_zvol 16k
	for v in default inline; do
		if [ $v = inline ]; then
			param zvol_request_sync 1
			param zfs_vdev_disk_calling_thread_io 1
		fi
		for w in randread "randwrite --sync=1" randwrite; do
			# shellcheck disable=SC2086
			"$HERE"/.github/nsrg/qd1-trace.sh "$v $w" \
			    "$OUT"/trace.txt sudo fio --name=t \
			    --filename=/dev/zvol/qd1/vol --rw=${w%% *} \
			    ${w#"${w%% *}"} --bs=4k --iodepth=1 --direct=1 \
			    --ioengine=psync --size="$SIZE" --time_based \
			    --runtime="$RUNTIME" --randrepeat=0
		done
	done
	param zvol_request_sync 0
	param zfs_vdev_disk_calling_thread_io 0
	tee -a "$GITHUB_STEP_SUMMARY" < "$OUT"/trace.txt
fi

sudo "$HERE"/zpool destroy qd1 || true
sudo losetup -d "$RAW" "$VDEV"
sudo rm -f /dev/shm/raw /dev/shm/vdev
