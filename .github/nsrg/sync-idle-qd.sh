#!/bin/sh
# sync-idle-qd.sh: 4k random writes on a zvol at queue depth 1, 4 and
# 16, and four jobs at depth 1, $BASE against this tree with
# zvol_request_sync_idle off and on.
#
# The vdev is a loop device over a file in /dev/shm, so the device time
# is near zero and what is measured is the software path.  Both trees'
# modules are loaded in turn on the same runner and the variants
# alternate within each round, so runner-to-runner variance does not
# enter the comparison.
set -eu

: "${BASE:?set BASE to the ref to compare against}"
OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=4
RUNTIME=10
SIZE=1G
mkdir -p "$OUT"

git remote get-url upstream >/dev/null 2>&1 ||
    git remote add upstream https://github.com/openzfs/zfs.git
git fetch -q upstream master
base=$(mktemp -d /var/tmp/base.XXXXXX)
git worktree add -q --detach "$base" "$BASE"
"$HERE"/.github/nsrg/build.sh "$base" release
"$HERE"/.github/nsrg/build.sh "$HERE" release

param() {	# param <name> <value>
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
}

sudo truncate -s 3G /dev/shm/vdev
VDEV=$(sudo losetup -f --show /dev/shm/vdev)

# make_zvol <src> <volblocksize>
make_zvol() {
	sudo "$1"/zpool destroy sq 2>/dev/null || true
	sudo "$1"/zpool create -f -O compression=off sq "$VDEV"
	sudo "$1"/zfs create -V "$SIZE" -o volblocksize="$2" \
	    -o compression=off sq/vol
	sudo udevadm settle
	# The base tree's udev rules do not make /dev/zvol links when it
	# lives outside the checkout; the pool has only this one zvol.
	VOL=/dev/$(ls /sys/block | grep '^zd' | head -1)
	sudo dd if=/dev/urandom of="$VOL" bs=1M count=1024 \
	    oflag=direct status=none
}

# destroy <src>: udev can still hold the zvol open just after fio
destroy() {
	t=0
	until sudo "$1"/zpool destroy sq; do
		t=$((t + 1))
		[ $t -lt 10 ] || exit 1
		sudo udevadm settle
		sleep 2
	done
}

# run <label> <vbs>: one line per queue depth and write mode,
# label vbs qd mode iops clat-mean p99 (usec)
run() {
	# 1x4: four jobs at queue depth 1 each, as a guest with four vCPUs
	for qd in 1 4; do
		j=${qd#*x}
		[ "$j" != "$qd" ] || j=1
		for mode in osync plain; do
			s=0
			[ $mode = plain ] || s=1
			# last.json belongs to us, not to root.
			# shellcheck disable=SC2024
			sudo fio --name=sq --filename="$VOL" \
			    --rw=randwrite --bs=4k --direct=1 --sync=$s \
			    --ioengine=libaio --iodepth="${qd%x*}" \
			    --numjobs="$j" --group_reporting \
			    --size="$SIZE" --time_based --runtime="$RUNTIME" \
			    --randrepeat=0 --output-format=json \
			    > "$OUT"/last.json
			jq -r --arg l "$1" --arg v "$2" --arg q "$qd" \
			    --arg m "$mode" '.jobs[0].write as $d
			    | [$l, $v, $q, $m, ($d.iops | floor),
			    ($d.clat_ns.mean / 1000 | floor),
			    ($d.clat_ns.percentile["99.000000"] / 1000 |
			    floor)] | @tsv' "$OUT"/last.json >> "$OUT"/raw.tsv
		done
	done
}

i=0
while [ $i -lt $ROUNDS ]; do
	for vbs in 4k 16k; do
		"$HERE"/.github/nsrg/load.sh "$base"
		make_zvol "$base" $vbs
		run base $vbs
		destroy "$base"
		"$HERE"/.github/nsrg/load.sh "$HERE"
		make_zvol "$HERE" $vbs
		param zvol_request_sync_idle 1
		for d in 64 1024 16384; do
			param zvol_request_sync_idle_delay $d
			run head-d$d $vbs
		done
		param zvol_request_sync_idle_delay 64
		param zvol_request_sync_idle_probe 16
		run head-p16 $vbs
		param zvol_request_sync_idle_probe 64
		param zvol_request_sync_idle 0
		destroy "$HERE"
	done
	i=$((i + 1))
done
sudo losetup -d "$VDEV"
sudo rm -f /dev/shm/vdev

# vbs qd mode label: mean iops, min-max iops, mean clat, mean p99, and
# the ratio of mean iops to base.  Overlapping ranges are noise.
awk -F'\t' '
    {
	k = $2 SUBSEP $3 SUBSEP $4 SUBSEP $1
	n[k]++; s[k] += $5; c[k] += $6; p[k] += $7
	if (!(k in lo) || $5 < lo[k]) lo[k] = $5
	if (!(k in hi) || $5 > hi[k]) hi[k] = $5
    }
    END {
	for (k in n) {
		split(k, a, SUBSEP)
		b = a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP "base"
		printf "%s\t%s\t%s\t%s\t%d\t%d-%d\t%d\t%d\t%.3f\n",
		    a[1], a[2], a[3], a[4], s[k] / n[k], lo[k], hi[k],
		    c[k] / n[k], p[k] / n[k], (s[k] / n[k]) / (s[b] / n[b])
	}
    }' "$OUT"/raw.tsv | sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 -k4,4 \
    > "$OUT"/sorted.tsv
{
	printf 'vbs\tqd\tmode\tlabel\tiops\tmin-max\tclat\tp99\tvs base\n'
	cat "$OUT"/sorted.tsv
} > "$OUT"/summary.tsv
column -t -s "$(printf '\t')" "$OUT"/summary.tsv | tee -a "$GITHUB_STEP_SUMMARY"
