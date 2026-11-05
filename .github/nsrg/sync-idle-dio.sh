#!/bin/sh
# sync-idle-dio.sh: zvol_request_sync_idle together with zvol Direct I/O,
# under load.  One tree, on a pool on a loop device over /dev/shm, with
# direct=always and direct=standard, tunable off, on, and off again as
# an A/A, in an order that rotates each round, because later runs
# measure lower.  Each volume ends with a write and verify at depth 16.
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=5
RUNTIME=10
VBS=16k
mkdir -p "$OUT"
"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"

param() {	# param <name> <value>
	echo "$2" | sudo tee /sys/module/zfs/parameters/"$1" >/dev/null
}

sudo truncate -s 3G /dev/shm/vdev
VDEV=$(sudo losetup -f --show /dev/shm/vdev)

run() {		# run <label> <direct>
	for qd in 1 4 16 1x4; do
		j=${qd#*x}
		[ "$j" != "$qd" ] || j=1
		for mode in randwrite-osync randrw; do
			case $mode in
			randwrite-osync) a="--rw=randwrite --sync=1" ;;
			randrw)	a="--rw=randrw --rwmixread=70" ;;
			esac
			# shellcheck disable=SC2086,SC2024
			sudo fio --name=sq --filename="$VOL" $a --bs=$VBS \
			    --direct=1 --ioengine=libaio --iodepth="${qd%x*}" \
			    --numjobs="$j" --group_reporting --size=1G \
			    --time_based --runtime="$RUNTIME" --randrepeat=0 \
			    --output-format=json > "$OUT"/last.json
			jq -r --arg l "$1" --arg d "$2" --arg q "$qd" \
			    --arg m "$mode" '.jobs[0] as $j
			    | [$d, $q, $m, $l,
			    (($j.read.iops + $j.write.iops) | floor)]
			    | @tsv' "$OUT"/last.json >> "$OUT"/raw.tsv
		done
	done
}

i=0
while [ $i -lt $ROUNDS ]; do
	case $((i % 3)) in
	0)	order="off on aa" ;;
	1)	order="on aa off" ;;
	2)	order="aa off on" ;;
	esac
	for direct in always standard; do
		for v in $order; do
			sudo "$HERE"/zpool create -f -O compression=off sq \
			    "$VDEV"
			sudo "$HERE"/zfs create -V 1G -o volblocksize=$VBS \
			    -o compression=off -o direct=$direct sq/vol \
			    2>/dev/null
			sudo udevadm settle
			VOL=/dev/$(ls /sys/block | grep '^zd' | head -1)
			sudo dd if=/dev/urandom of="$VOL" bs=1M count=1024 \
			    oflag=direct status=none
			[ "$v" != on ] || param zvol_request_sync_idle 1
			[ "$v" = on ] || param zvol_request_sync_idle 0
			run "$v" $direct
			sudo fio --name=verify --filename="$VOL" --bs=$VBS \
			    --direct=1 --rw=randwrite --ioengine=libaio \
			    --iodepth=16 --size=256M --verify=sha1 \
			    --do_verify=1 --randrepeat=0 >/dev/null
			param zvol_request_sync_idle 0
			t=0
			until sudo "$HERE"/zpool destroy sq; do
				t=$((t + 1))
				[ $t -lt 10 ] || exit 1
				sudo udevadm settle
				sleep 2
			done
		done
	done
	i=$((i + 1))
done
sudo losetup -d "$VDEV"
sudo rm -f /dev/shm/vdev

awk -F'\t' '
    {
	k = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
	n[k]++; s[k] += $5
	if (!(k in lo) || $5 < lo[k]) lo[k] = $5
	if (!(k in hi) || $5 > hi[k]) hi[k] = $5
    }
    END {
	for (k in n) {
		split(k, a, SUBSEP)
		b = a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP "off"
		printf "%s\t%s\t%s\t%s\t%d\t%d-%d\t%.3f\n", a[1], a[2], a[3],
		    a[4], s[k] / n[k], lo[k], hi[k], (s[k] / n[k]) / (s[b] / n[b])
	}
    }' "$OUT"/raw.tsv | sort > "$OUT"/sorted.tsv
{
	printf 'direct\tqd\tmode\tlabel\tiops\tmin-max\tvs off\n'
	cat "$OUT"/sorted.tsv
} > "$OUT"/summary.tsv
column -t -s "$(printf '\t')" "$OUT"/summary.tsv |
    tee -a "$GITHUB_STEP_SUMMARY"
