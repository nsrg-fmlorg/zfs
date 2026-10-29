#!/bin/sh
# zilcopy.sh: what WR_COPIED's second copy costs, measured with the
# existing zil_maxcopied tunable.
#
# A sync write up to zil_maxcopied bytes is logged WR_COPIED: copied
# from the dbuf into the itx at write() time, then from the itx into
# the log block at commit.  With zil_maxcopied=0 it is logged
# WR_NEED_COPY instead: copied once, straight into the log block, but
# under a range lock and dbuf hold taken at commit (zfs_get_data).
# PR 15353 picked 7.5K as the crossover; this measures it here with a
# slog, where WR_INDIRECT is never used.
#
# The tunable is changed at run time on one loaded module, so the
# modes alternate within each round.  "def2" repeats the default as an
# A/A control.  Writes of 16k and 64k exceed the default limit and are
# WR_NEED_COPY in every mode, a second control.  Buffered writes with
# fsync are logged WR_NEED_COPY whatever the limit (no commit is
# pending at write() time), a third.  The zil kstat counters show
# which state each run actually used.
#
# The pool sits in /dev/shm: the numbers are the cost of the code path,
# not of a log device.
set -eu

OUT=/var/tmp/bench
ROUNDS=3
RUNTIME=10
MODES="def zero def2"
SIZES="4k 7k 16k 64k"

mkdir -p "$OUT"
.github/nsrg/build.sh . release
.github/nsrg/load.sh .

param=/sys/module/zfs/parameters/zil_maxcopied
default=$(cat $param)

sudo truncate -s 4G /dev/shm/data
sudo truncate -s 1G /dev/shm/log
sudo ./zpool create -f -O compression=off -O atime=off \
    zc /dev/shm/data log /dev/shm/log

busy_jiffies() {
	awk '/^cpu / { print $2 + $3 + $4 + $7 + $8 }' /proc/stat
}

zilstat() {	# zilstat <counter>
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/zil
}

# run <mode> <kind> <bs> <jobs>: one fio run, one line of raw.tsv
run() {
	mode=$1 kind=$2 bs=$3 jobs=$4
	case $mode in
	zero)	echo 0 ;;
	*)	echo "$default" ;;
	esac | sudo tee $param >/dev/null

	case $kind in
	osync)	sync="--sync=1" ;;
	fsync)	sync="--fsync=1" ;;
	esac

	sudo rm -f /zc/f.*
	c0=$(zilstat zil_itx_copied_count)
	n0=$(zilstat zil_itx_needcopy_count)
	j0=$(busy_jiffies)
	# shellcheck disable=SC2086
	sudo fio --name=f --directory=/zc --rw=write --bs="$bs" \
	    --size=256m --numjobs="$jobs" --time_based \
	    --runtime=$RUNTIME --ioengine=psync $sync --group_reporting \
	    --output-format=json | tee "$OUT"/last.json >/dev/null
	j1=$(busy_jiffies)
	c1=$(zilstat zil_itx_copied_count)
	n1=$(zilstat zil_itx_needcopy_count)

	jq -r --arg m "$mode" --arg k "$kind" --arg b "$bs" \
	    --arg j "$jobs" --arg p "$(cat $param)" \
	    --arg cpu "$((j1 - j0))" --arg cp "$((c1 - c0))" \
	    --arg nc "$((n1 - n0))" '
	    .jobs[0].write as $w |
	    [$m, $k, $b, $j, $p, $w.total_ios,
	    ($w.clat_ns.mean / 1000 | floor),
	    ($w.clat_ns.percentile["99.000000"] / 1000 | floor),
	    ($w.clat_ns.percentile["99.900000"] / 1000 | floor),
	    $cpu, $cp, $nc] | @tsv' "$OUT"/last.json >> "$OUT"/raw.tsv
}

printf 'mode\tkind\tbs\tjobs\tmaxcopied\tios\tclat_us\tp99_us\tp999_us\tbusy_jiffies\tcopied\tneedcopy\n' \
    > "$OUT"/raw.tsv
r=0
while [ $r -lt $ROUNDS ]; do
	for kind in osync fsync; do
		for jobs in 1 8; do
			for bs in $SIZES; do
				for mode in $MODES; do
					run "$mode" "$kind" "$bs" "$jobs"
				done
			done
		done
	done
	r=$((r + 1))
done

echo "$default" | sudo tee $param >/dev/null
sudo ./zpool destroy zc
sudo rm -f /dev/shm/data /dev/shm/log

# Per (kind, bs, jobs, mode): mean, min and max of clat over the rounds,
# mean p99/p99.9, CPU per write in microseconds (USER_HZ is 100), and
# the share of writes logged WR_COPIED.
awk -F'\t' 'NR > 1 {
	k = $2 "\t" $3 "\t" $4 "\t" $1
	n[k]++; s[k] += $7; p99[k] += $8; p999[k] += $9
	if (!(k in lo) || $7 < lo[k]) lo[k] = $7
	if (!(k in hi) || $7 > hi[k]) hi[k] = $7
	ios[k] += $6; cpu[k] += $10; cp[k] += $11; nc[k] += $12
	mc[k] = $5
    }
    END {
	print "kind\tbs\tjobs\tmode\tmaxcopied\tclat_us\tmin-max\tp99\tp99.9\tiops\tcpu_us/write\tcopied%"
	for (k in n) {
		printf "%s\t%s\t%d\t%d-%d\t%d\t%d\t%d\t%.1f\t%.0f\n", k, mc[k],
		    s[k] / n[k], lo[k], hi[k], p99[k] / n[k], p999[k] / n[k],
		    ios[k] / n[k] / '"$RUNTIME"', cpu[k] * 10000 / ios[k],
		    (cp[k] + nc[k]) ? 100 * cp[k] / (cp[k] + nc[k]) : 0
	}
    }' "$OUT"/raw.tsv | sort > "$OUT"/summary.tsv
column -t -s "$(printf '\t')" "$OUT"/summary.tsv | tee -a "$GITHUB_STEP_SUMMARY"
