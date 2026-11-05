#!/bin/sh
# qd1.sh: where does a QD=1 write spend its time on a direct=always zvol?
# Each case is fio randwrite for 15s on a pool in /dev/shm, two rounds
# untraced, then a traced round of stage latencies for selected cases.
set -u
OUT=/var/tmp/qd1
HERE=$(pwd)
mkdir -p "$OUT"
P=/sys/module/zfs/parameters
VOL=bench/vol
DEV=/dev/zvol/$VOL

param() { echo "$2" | sudo tee "$P/$1" >/dev/null; }

setup() { # setup <direct> <volblocksize>
	sudo truncate -s 5G /dev/shm/vdev
	sudo "$HERE"/zpool create -f -O compression=off bench /dev/shm/vdev
	sudo "$HERE"/zfs create -V 3G -b "$2" -o direct="$1" $VOL
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

fio1() { # fio1 <bs> <sync 0|1> <depth>
	sudo timeout 120 fio --name=w --filename=$DEV --direct=1 --rw=randwrite \
	    --bs="$1" --sync="$2" --iodepth="$3" --size=3G --ioengine=libaio \
	    --randrepeat=0 --time_based --runtime=15 --output-format=json \
	    > "$OUT"/fio.json
}

report() { # report <label>
	jq -r --arg l "$1" '.jobs[0] | [$l, (.write.bw_bytes/1048576|floor),
	    (.write.iops|floor), (.write.clat_ns.mean/1000|floor),
	    (.write.clat_ns.percentile["99.000000"]/1000|floor),
	    .usr_cpu, .sys_cpu] | @tsv' "$OUT"/fio.json |
	    tee -a "$OUT"/raw.tsv
}

# stages: latency of each traced function, and off-CPU time per comm.
stages() { # stages <label> <bs> <sync>
	f="$OUT/$1.bt"
	: > "$f"
	for fn in zvol_write dmu_write_uio_dnode \
	    dmu_write_uio_direct dmu_write_abd_impl dmu_write_direct \
	    zfs_uio_get_dio_pages_alloc zfs_uio_free_dio_pages \
	    abd_alloc_from_pages dmu_buf_hold_array_by_dnode \
	    dmu_buf_will_clone_or_dio dmu_buf_will_fill_flags \
	    dmu_tx_assign dmu_tx_commit zfs_rangelock_enter zvol_log_write \
	    zil_commit zio_wait zio_checksum_compute zio_checksum_error \
	    zio_vdev_io_start vdev_file_io_strategy metaslab_alloc \
	    zio_write_compress zio_done; do
		if sudo timeout 20 bpftrace -e \
		    "kretprobe:$fn { exit(); } interval:ms:100 { exit(); }" \
		    >/dev/null 2>&1; then
			cat >> "$f" <<-BT
			kprobe:$fn { @s_$fn[tid] = nsecs; }
			kretprobe:$fn /@s_$fn[tid]/ {
				@ns_$fn = stats(nsecs - @s_$fn[tid]);
				delete(@s_$fn[tid]);
			}
			BT
		else
			echo "$1: no probe $fn"
		fi
	done
	cat >> "$f" <<-'BT'
	tracepoint:sched:sched_wakeup { @wk[args->pid] = nsecs; }
	tracepoint:sched:sched_switch /@wk[args->next_pid]/ {
		@runq[args->next_comm] = stats(nsecs - @wk[args->next_pid]);
		delete(@wk[args->next_pid]);
	}
	tracepoint:sched:sched_switch {
		@off[args->prev_pid] = nsecs;
		@name[args->prev_pid] = args->prev_comm;
		if (@off[args->next_pid]) {
			@offcpu[@name[args->next_pid]] =
			    sum(nsecs - @off[args->next_pid]);
			delete(@off[args->next_pid]);
		}
	}
	interval:s:18 { exit(); }
	END { clear(@off); clear(@name); clear(@wk); }
	BT
	for m in $(grep -o '@s_[a-z_0-9]*' "$f" | sort -u); do
		sed -i "s/^\tEND {/\tEND { clear($m);/;s/^END {/END { clear($m);/" "$f"
	done
	sudo BPFTRACE_MAX_BPF_PROGS=512 bpftrace "$f" > "$OUT/$1.stages" 2>&1 &
	bp=$!
	sleep 3
	fio1 "$2" "$3" 1
	wait $bp
	sed "s/^/$1: /" "$OUT/$1.stages" | grep -E '@ns_|@runq|@offcpu|ERROR'
}

# case <label> <direct> <vbs> <bs> <sync> [verify] [request_sync]
case1() {
	l=$1
	param zfs_vdev_direct_write_verify "${6:-1}"
	param zvol_request_sync "${7:-0}"
	setup "$2" "$3"
	for r in 1 2; do
		fio1 "$4" "$5" 1
		report "$l"
	done
	teardown
}

"$HERE"/.github/nsrg/load.sh "$HERE"
param zfs_arc_max $((512 * 1024 * 1024))

# Stage latency, one traced round each.
sudo apt-get install -y -qq bpftrace >/dev/null
for t in "standard 128k 128k 0" "always 128k 128k 0" "always 128k 1M 0" \
    "always 4k 4k 0" "standard 4k 4k 0"; do
	set -- $t
	param zfs_vdev_direct_write_verify 1
	param zvol_request_sync 0
	setup "$1" "$2"
	stages "$1-v$2-b$3" "$3" "$4"
	report "traced/$1/v$2/b$3"
	teardown
done

echo "label MiB/s iops clat_us p99_us usr sys" > "$OUT"/summary.tsv
awk -F'\t' '{ k=$1; b[k]+=$2; i[k]+=$3; c[k]+=$4; p[k]+=$5; u[k]+=$6; s[k]+=$7;
    n[k]++ } END { for (k in n) printf "%s %d %d %d %d %.1f %.1f (n=%d)\n", k,
    b[k]/n[k], i[k]/n[k], c[k]/n[k], p[k]/n[k], u[k]/n[k], s[k]/n[k], n[k] }' \
    "$OUT"/raw.tsv | sort >> "$OUT"/summary.tsv
sed 's/^/SUM /' "$OUT"/summary.tsv
sudo chmod -R a+r "$OUT"
