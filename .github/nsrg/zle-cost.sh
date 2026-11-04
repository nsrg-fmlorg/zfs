#!/bin/sh
# zle-cost.sh: what compression=zle and lz4 cost against compression=off
# on data that is not zero, on an unmodified tree.
#
# The vdev is a loop device over a file in /dev/shm, written out once so
# that no run pays for tmpfs first touch.  The device time is near zero
# and what is measured is the software path.  A sync write is logged as
# WR_COPIED and compressed later in spa_sync, so its latency need not
# show the cost: the host's CPU over fio plus zpool sync does, through
# /proc/stat, because the time is spent in taskq threads and not in fio.
#
# Within each condition the settings alternate, in an order rotated by
# round, and off runs twice: the second, off2, is the A/A control that
# says how much of a difference is noise.  One pass under bpftrace comes
# after the measured rounds so that the probes do not touch the numbers.
set -eu

OUT=/var/tmp/bench
HERE=$(pwd)
ROUNDS=5
RUNTIME=10
SIZE=1G
ARC_MAX=$((2 * 1024 * 1024 * 1024))
SETTINGS="off zle lz4 off2"
# target:pattern; a target is zvol, or the recordsize of a dataset.
CONDS="zvol:rand4k zvol:seq 128k:rand4k 128k:seq 128k:direct 1M:rand4k
    1M:seq 1M:direct"
mkdir -p "$OUT"

sudo apt-get install -y -q bpftrace >/dev/null 2>&1 ||
    echo "bpftrace could not be installed" | tee -a "$OUT"/notes
"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null

sudo dd if=/dev/zero of=/dev/shm/vdev bs=1M count=4096 status=none
VDEV=$(sudo losetup -f --show /dev/shm/vdev)

zpool() { sudo "$HERE"/zpool "$@"; }
zfs() { sudo "$HERE"/zfs "$@"; }

# make_target <target> <compression>: sets DEV, the fio filename
make_target() {
	zpool create -f -o ashift=12 -O compression=off -O atime=off \
	    sq "$VDEV"
	if [ "$1" = zvol ]; then
		zfs create -V "$SIZE" -o volblocksize=16k -o compression="$2" \
		    sq/t
		sudo udevadm settle
		# The udev rules for /dev/zvol are not installed on a tree
		# run from its checkout; the pool has only this one zvol.
		DEV=/dev/$(ls /sys/block | grep '^zd' | head -1)
		[ -b "$DEV" ]
	else
		zfs create -o recordsize="$1" -o compression="$2" sq/t
		DEV=/sq/t/f
	fi
}

# udev can still hold the zvol open just after fio
destroy() {
	n=0
	until zpool destroy sq; do
		n=$((n + 1))
		[ $n -lt 10 ] || exit 1
		sudo udevadm settle
		sleep 2
	done
}

data_opts() {
	case $1 in
	random)	echo "--refill_buffers=1" ;;
	half)	echo "--refill_buffers=1 --buffer_compress_percentage=50" ;;
	esac
}

# Sets FIO_OPTS for <target> <pattern>.  The buffered sequential case
# has no real queue: libaio blocks in submission on a buffered file.
pattern_opts() {
	case $1 in
	zvol)	bs=16k direct=1 ;;
	*)	bs=$1 direct=0 ;;
	esac
	case $2 in
	rand4k)	FIO_OPTS="--rw=randwrite --bs=4k --iodepth=1 --sync=1
		    --direct=$direct --norandommap" ;;
	seq)	FIO_OPTS="--rw=write --bs=$bs --iodepth=16 --sync=0
		    --direct=$direct" ;;
	direct)	FIO_OPTS="--rw=write --bs=$bs --iodepth=16 --sync=0
		    --direct=1" ;;
	esac
}

prefill() {	# prefill <data>
	d=0
	[ -b "$DEV" ] && d=1
	# shellcheck disable=SC2046
	sudo fio --name=fill --filename="$DEV" --rw=write --bs=1M \
	    --size="$SIZE" --ioengine=libaio --iodepth=4 --direct=$d \
	    $(data_opts "$1") >/dev/null
	zpool sync sq
}

cpu() {		# system+irq+softirq and user+nice, USER_HZ
	awk '$1 == "cpu" { print $4 + $7 + $8, $2 + $3 }' /proc/stat
}

run_fio() {
	# last.json belongs to us, not to root.
	# shellcheck disable=SC2024,SC2086
	sudo fio --name=sq --filename="$DEV" $FIO_OPTS $DATA_OPTS \
	    --ioengine=libaio --size="$SIZE" --time_based \
	    --runtime="$RUNTIME" --randrepeat=0 --output-format=json \
	    > "$OUT"/last.json
}

# one <round> <target> <pattern> <data> <label>
one() {
	comp=${5%2}
	make_target "$2" "$comp"
	prefill "$4"
	pattern_opts "$2" "$3"
	DATA_OPTS=$(data_opts "$4")
	set -- "$@" "$(cpu)"
	t0=$(date +%s.%N)
	run_fio
	zpool sync sq
	t1=$(date +%s.%N)
	c1=$(cpu)
	# A run that does not show what it exercised proves nothing:
	# direct_write_count says whether O_DIRECT stayed direct, and
	# compressratio that the setting took effect.
	dw=$(awk '$1 == "direct_write_count" { print $3 }' \
	    /proc/spl/kstat/zfs/sq/iostats 2>/dev/null) || dw=na
	props=$(zfs get -Hpo value used,compressratio sq/t | paste -s -)
	jq -r --arg k "$(printf '%s\t' "$1" "$2" "$3" "$4" "$5")" \
	    --arg c0 "$6" --arg c1 "$c1" --arg w "$t0 $t1" --arg p "$props" \
	    --arg dw "$dw" '.jobs[0].write as $d
	    | ($c0 | split(" ") | map(tonumber)) as $a
	    | ($c1 | split(" ") | map(tonumber)) as $b
	    | ($w | split(" ") | map(tonumber)) as $t
	    | ($d.total_ios) as $n
	    | $k + ([($d.iops | floor), ($d.bw_bytes / 1048576 | floor),
	    ($d.bw_bytes * $d.runtime / 1000 / ($t[1] - $t[0]) / 1048576
	    | floor),
	    ($d.clat_ns.percentile["50.000000"] / 1000 | floor),
	    ($d.clat_ns.percentile["99.000000"] / 1000 | floor),
	    $n, (($t[1] - $t[0]) * 100 | floor) / 100,
	    (($b[0] - $a[0]) * 10000 / $n * 100 | floor) / 100,
	    (($b[1] - $a[1]) * 10000 / $n * 100 | floor) / 100, $dw, $p]
	    | map(tostring) | join("\t"))' "$OUT"/last.json >> "$OUT"/raw.tsv
	destroy
}

printf 'round\ttarget\tpattern\tdata\tsetting\tiops\tbw_mib\teff_mib\tp50_us\tp99_us\tios\twall_s\tsys_us_io\tusr_us_io\tdirect_writes\tused\tratio\n' \
    > "$OUT"/raw.tsv

r=0
while [ $r -lt "$ROUNDS" ]; do
	for c in $CONDS; do
		for data in random half; do
			# shellcheck disable=SC2086
			set -- $SETTINGS
			i=$((r % $#))
			while [ "$i" -gt 0 ]; do
				x=$1
				shift
				set -- "$@" "$x"
				i=$((i - 1))
			done
			for s in "$@"; do
				one $r "${c%:*}" "${c#*:}" $data "$s"
			done
		done
	done
	r=$((r + 1))
done

# All zeros, on a fresh target with no prefill: nothing should be stored
# under zle or lz4.
printf 'target\taccess\tsetting\tlogicalused\tused\treferenced\n' \
    > "$OUT"/zero.tsv
for t in zvol 128k 1M; do
	for s in off zle lz4; do
		for a in default direct; do
			if [ "$t" = zvol ]; then
				bs=16k
				[ $a = direct ] || continue
			else
				bs=$t
			fi
			d=0
			[ $a != direct ] || d=1
			make_target "$t" "$s"
			sudo fio --name=z --filename="$DEV" --rw=write \
			    --bs="$bs" --size=256M --ioengine=libaio \
			    --iodepth=4 --direct=$d --zero_buffers=1 \
			    >/dev/null
			zpool sync sq
			printf '%s\t%s\t%s\t%s\n' "$t" "$a" "$s" "$(zfs get \
			    -Hpo value logicalused,used,referenced sq/t |
			    paste -s -)" >> "$OUT"/zero.tsv
			destroy
		done
	done
done

# Per block time, in a pass of its own.  The key is the compress enum
# and the size: metadata goes through zio_compress_data as lz4 whatever
# the dataset says.  retval == s_len means the block did not shrink.
if command -v bpftrace >/dev/null; then
	prog=$OUT/compress.bt
	cat > "$prog" <<'BT'
kprobe:zio_compress_data {
	@s[tid] = nsecs; @c[tid] = arg0; @l[tid] = arg3;
}
kretprobe:zio_compress_data /@s[tid]/ {
	@data_ns[@c[tid], @l[tid]] = sum(nsecs - @s[tid]);
	@data_n[@c[tid], @l[tid]] = count();
	if (retval == @l[tid]) { @data_noshrink[@c[tid], @l[tid]] = count(); }
	delete(@s[tid]); delete(@c[tid]); delete(@l[tid]);
}
kprobe:abd_cmp_zero_off { @zs[tid] = nsecs; @zl[tid] = arg2; }
kretprobe:abd_cmp_zero_off /@zs[tid]/ {
	@zero_ns[@zl[tid]] = sum(nsecs - @zs[tid]);
	@zero_n[@zl[tid]] = count();
	delete(@zs[tid]); delete(@zl[tid]);
}
kprobe:zio_write_compress { @ws[tid] = nsecs; }
kretprobe:zio_write_compress /@ws[tid]/ {
	@stage_ns = sum(nsecs - @ws[tid]); @stage_n = count();
	delete(@ws[tid]);
}
END { clear(@s); clear(@c); clear(@l); clear(@zs); clear(@zl); clear(@ws); }
BT
	for c in $CONDS; do
		for data in random half; do
			for s in off zle lz4; do
				t=${c%:*} p=${c#*:}
				make_target "$t" "$s"
				prefill $data
				pattern_opts "$t" "$p"
				DATA_OPTS=$(data_opts $data)
				echo "== $t $p $data $s" >> "$OUT"/trace.txt
				# shellcheck disable=SC2086
				sudo bpftrace -q --no-warnings "$prog" -c \
				    "/usr/bin/fio --name=sq --filename=$DEV \
				    $(echo $FIO_OPTS $DATA_OPTS) \
				    --ioengine=libaio --size=$SIZE \
				    --time_based --runtime=$RUNTIME \
				    --randrepeat=0 --output=/dev/null" \
				    2>&1 | grep -E '^@|rror' \
				    >> "$OUT"/trace.txt ||
				    echo "bpftrace failed" >> "$OUT"/trace.txt
				zpool sync sq
				destroy
			done
		done
	done
fi
sudo losetup -d "$VDEV"
sudo rm -f /dev/shm/vdev

{
	cat /sys/module/zfs/parameters/zfs_arc_max
	awk '$1 == "c_max" { print "c_max", $3 }' /proc/spl/kstat/zfs/arcstats
	cat "$OUT"/notes 2>/dev/null || true
} > "$OUT"/params.txt
python3 .github/nsrg/zle-cost-sum.py "$OUT"/raw.tsv | tee "$OUT"/summary.tsv
{
	echo '```'
	cat "$OUT"/params.txt "$OUT"/zero.tsv "$OUT"/summary.tsv
	echo '```'
} >> "$GITHUB_STEP_SUMMARY"
