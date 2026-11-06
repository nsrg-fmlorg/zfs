#!/bin/sh
# qd1.sh: what does dropping the ARC cost a volume when a write covers part
# of a block?  /dev/shm hides the read of the old block, so the file vdev
# sleeps per I/O, 80us read and 20us write, roughly an NVMe drive.
# fio randwrite QD=1, 15s, three rounds.
set -u
OUT=/var/tmp/qd1
HERE=$(pwd)
mkdir -p "$OUT"
P=/sys/module/zfs/parameters
VOL=bench/vol
DEV=/dev/zvol/$VOL

param() { echo "$2" | sudo tee "$P/$1" >/dev/null; }

setup() { # setup <primarycache> <volblocksize>
	sudo truncate -s 6G /dev/shm/vdev
	sudo "$HERE"/zpool create -f -O compression=off bench /dev/shm/vdev
	sudo "$HERE"/zfs create -V 3G -b "$2" -o primarycache="$1" \
	    -o direct=standard $VOL
	udevadm settle
	sudo dd if=/dev/urandom of=$DEV bs=1M count=3072 oflag=direct \
	    status=none
	sudo "$HERE"/zpool sync bench
}

teardown() {
	udevadm settle
	n=0
	until sudo "$HERE"/zpool destroy bench 2>/dev/null; do
		n=$((n + 1))
		[ $n -lt 15 ] || { echo "destroy failed"; exit 1; }
		sleep 2
	done
	sudo rm -f /dev/shm/vdev
}

arc() { # peak MiB of data_size, anon_size and arc size over the samples
	while :; do
		awk '$1=="data_size"{d=$3} $1=="anon_size"{a=$3}
		    $1=="size"{s=$3} END{print d, a, s}' \
		    /proc/spl/kstat/zfs/arcstats
		sleep 1
	done
}

round() { # round <label> <bs> <sync> <odirect>
	arc > "$OUT"/arc.txt &
	ap=$!
	sudo timeout 120 fio --name=w --filename=$DEV --direct=1 \
	    --rw=randwrite --bs="$2" --sync="$3" --iodepth=1 --size=3G \
	    --ioengine=libaio --randrepeat=0 --time_based --runtime=15 \
	    --output-format=json > "$OUT"/fio.json
	kill $ap
	wait $ap 2>/dev/null
	peak=$(awk '$1>d{d=$1} $2>a{a=$2} $3>s{s=$3} END{
	    printf "%d\t%d\t%d", d/1048576, a/1048576, s/1048576}' \
	    "$OUT"/arc.txt)
	line=$(jq -r '.jobs[0] | [(.write.iops|floor),
	    (.write.clat_ns.mean/1000|floor),
	    (.write.clat_ns.percentile["99.000000"]/1000|floor),
	    .sys_cpu] | @tsv' "$OUT"/fio.json)
	printf '%s\t%s\t%s\n' "$1" "$line" "$peak" | tee -a "$OUT"/raw.tsv
}

"$HERE"/.github/nsrg/load.sh "$HERE"
param zfs_arc_max $((512 * 1024 * 1024))
param zvol_request_sync 0

misses() { awk '$1=="demand_data_misses"{print $3}' /proc/spl/kstat/zfs/arcstats; }

case1() { # case1 <read_us> <write_us> <vbs> <bs> <sync> <primarycache>
	param vdev_file_read_delay_us "$1"
	param vdev_file_write_delay_us "$2"
	l="r$1w$2/v$3/b$4/sync$5/$6"
	setup "$6" "$3"
	for r in 1 2 3; do
		m0=$(misses)
		round "$l" "$4" "$5" 1
		echo "MISS $l $(($(misses) - m0))" | tee -a "$OUT"/miss.txt
	done
	teardown
}

# Control: the delay has to show, or nothing below measures it.
for pc in all metadata; do
	case1 0 0 16k 4k 0 $pc
	case1 0 0 16k 16k 0 $pc
done
for v in 16k 64k 128k 1M; do
	for b in 4k 16k 64k; do
		case "$v/$b" in 16k/64k) continue;; esac
		for s in 0 1; do
			for pc in all metadata; do
				case1 80 20 $v $b $s $pc
			done
		done
	done
done

{
	echo "label iops clat_us p99_us sys data_peak anon_peak arc_peak"
	awk -F'\t' '{ k=$1; n[k]++
	    i[k]+=$2; c[k]+=$3; p[k]+=$4; u[k]+=$5
	    if ($6>d[k]) d[k]=$6; if ($7>a[k]) a[k]=$7; if ($8>s[k]) s[k]=$8 }
	    END { for (k in n) printf "%s %d %d %d %.1f %d %d %d (n=%d)\n", k,
	    i[k]/n[k], c[k]/n[k], p[k]/n[k], u[k]/n[k], d[k], a[k], s[k], n[k] }' \
	    "$OUT"/raw.tsv | sort
} > "$OUT"/summary.tsv
sed 's/^/SUM /' "$OUT"/summary.tsv
sed "s/^/SUM /" "$OUT"/miss.txt
sudo chmod -R a+r "$OUT"
