#!/bin/sh
# qd1-trace.sh <label> <outfile> <command...>: run the command (fio at
# queue depth 1 on a zvol) under bpftrace and append the mean time per
# I/O spent in each stage of the zvol path.
#
# With one I/O in flight the stages follow each other, so one set of
# timestamps is enough.  The request is the bio handed to
# zvol_submit_bio(); it ends when bio_endio() is called on that bio.
#
#   hop     zvol_submit_bio -> zvol_read/zvol_write: taskq hand-off
#   issue   -> first vdev_disk_io_start: DMU, dbuf, ZIO issue stages
#   device  -> vbio_completion: loop device on /dev/shm, not NVMe
#   wakeup  -> last zio_wait return: zio_done, interrupt taskq, wakeup
#   finish  -> bio_endio: copy to the bio, unlock
#
# and, summed over each I/O: checksum, CoW allocation (metaslab_alloc),
# dmu_tx_assign, zil_commit, uiomove copies, taskq dispatches.  Only
# functions listed as traceable are probed; the rest are named.
set -eu
label=$1 out=$2
shift 2

traceable=$(mktemp)
sudo cat /sys/kernel/tracing/available_filter_functions \
    /sys/kernel/debug/tracing/available_filter_functions 2>/dev/null |
    awk '{ print $1 }' | sort -u > "$traceable"
have() { grep -qx "$1" "$traceable"; }

pick() {	# pick <name>...: the first traceable one
	for f in "$@"; do
		if have "$f"; then echo "$f"; return; fi
	done
}

entry=$(pick zvol_submit_bio zvol_request)
rtask=$(pick zvol_read zvol_read_task)
wtask=$(pick zvol_write zvol_write_task)
missing=
for v in entry rtask wtask; do
	eval "f=\$$v"
	[ -n "$f" ] || missing="$missing $v"
done

prog=$(mktemp)
{
	cat <<BT
kprobe:$entry /comm == "fio"/ {
	@bio = arg0; @t_req = nsecs; @t_task = 0; @t_iss = 0; @t_dev = 0;
	@t_zw = 0; @inio = 1;
}
kprobe:$rtask, kprobe:$wtask /@inio && @t_task == 0/ {
	@t_task = nsecs; @tid = tid; @hop += nsecs - @t_req;
}
BT
	cat <<'BT'
kprobe:vdev_disk_io_start /@inio && @t_task && @t_iss == 0/ {
	@t_iss = nsecs; @issue += nsecs - @t_task;
}
kprobe:vbio_completion /@inio && @t_iss && @t_dev == 0/ {
	@t_dev = nsecs; @device += nsecs - @t_iss;
}
kretprobe:zio_wait /@inio && tid == @tid/ { @t_zw = nsecs; }
kprobe:bio_endio /@inio && arg0 == @bio/ {
	if (@t_dev && @t_zw > @t_dev) {
		@wakeup += @t_zw - @t_dev; @finish += nsecs - @t_zw;
		@nio_dev++;
	}
	@total += nsecs - @t_req; @nio++; @inio = 0;
}
kprobe:taskq_dispatch, kprobe:taskq_dispatch_ent /@inio/ { @dispatches++; }
BT
	for f in zio_checksum_compute zio_checksum_error metaslab_alloc \
	    dmu_tx_assign zil_commit zfs_uiomove; do
		if ! have $f; then
			missing="$missing $f"
			continue
		fi
		cat <<BT
kprobe:$f /@inio/ { @s_${f}[tid] = nsecs; }
kretprobe:$f /@inio && @s_${f}[tid]/ {
	@sum_$f += nsecs - @s_${f}[tid]; delete(@s_${f}[tid]);
}
BT
	done
	cat <<'BT'
END {
	$n = (uint64)@nio; if ($n == 0) { $n = 1; }
	$d = (uint64)@nio_dev; if ($d == 0) { $d = 1; }
	printf("ios %d (reaching the device %d)\n", @nio, @nio_dev);
	printf("total   %6d ns\n", (uint64)@total / $n);
	printf("hop     %6d ns\n", (uint64)@hop / $n);
	printf("issue   %6d ns  (I/Os reaching the device)\n",
	    (uint64)@issue / $d);
	printf("device  %6d ns\n", (uint64)@device / $d);
	printf("wakeup  %6d ns\n", (uint64)@wakeup / $d);
	printf("finish  %6d ns\n", (uint64)@finish / $d);
	printf("taskq dispatches per 100 I/O %d\n",
	    (uint64)@dispatches * 100 / $n);
BT
	for f in zio_checksum_compute zio_checksum_error metaslab_alloc \
	    dmu_tx_assign zil_commit zfs_uiomove; do
		case " $missing " in *" $f "*) continue ;; esac
		# $n is a bpftrace variable, not a shell one.
		# shellcheck disable=SC2016
		printf '\tprintf("%s %%d ns per I/O\\n", (uint64)@sum_%s / $n);\n' "$f" "$f"
	done
	echo "	clear(@t_req); clear(@t_task); clear(@t_iss); clear(@t_dev);"
	echo "	clear(@t_zw); clear(@tid); clear(@inio); clear(@bio);"
	echo "}"
} > "$prog"

{
	echo "== $label"
	[ -z "$missing" ] || echo "not traced (not traceable):$missing"
} >> "$out"
sudo bpftrace -q --no-warnings "$prog" -c "$*" 2>&1 |
    grep -vE '^@|^$' >> "$out" || echo "bpftrace failed" >> "$out"
rm -f "$prog" "$traceable"
