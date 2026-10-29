#!/bin/sh
# async.sh: what zfs_async_dio_enabled does to 4k O_DIRECT IOPS.
#
# One release build; the tunable is flipped at run time between rounds,
# so both sides run the same module on the same runner.  "off2" is a
# second pass with the tunable off: the A/A noise.  The pool is a stripe
# of four brd ramdisks (non-rotational block devices, as fork M's
# iops.sh uses), not NVMe.  Context switches per I/O come from the
# ctxt line of /proc/stat over the run.
set -eu

OUT=/var/tmp/async
RUNTIME=10
ROUNDS=2
PARAM=/sys/module/zfs/parameters/zfs_async_dio_enabled
mkdir -p "$OUT"

.github/nsrg/build.sh . release
.github/nsrg/load.sh .
[ -w "$PARAM" ] || sudo test -e "$PARAM" ||
    { echo "async.sh: $PARAM missing" >&2; exit 1; }

sudo modprobe brd rd_nr=4 rd_size=$((2048 * 1024))
sudo ./zpool create -f -O compression=off -O recordsize=4k -O atime=off \
    -O primarycache=metadata bench /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3
sudo fio --name=fill --directory=/bench --size=2G --rw=write --bs=1M \
    --numjobs=1 --end_fsync=1 >/dev/null

ctxt() { awk '/^ctxt/ { print $2 }' /proc/stat; }

# run <mode> <engine> <rw> <jobs> <qd> <round>
run() {
	before=$(ctxt)
	json=$(sudo fio --name=t --directory=/bench --filename=fill.0.0 \
	    --size=2G --rw="$3" --bs=4k --direct=1 --ioengine="$2" \
	    --iodepth="$5" --numjobs="$4" --time_based --runtime=$RUNTIME \
	    --group_reporting --output-format=json)
	after=$(ctxt)
	echo "$json" | jq -r --arg m "$1" --arg e "$2" --arg w "$3" \
	    --arg j "$4" --arg q "$5" --arg r "$6" \
	    --argjson cs "$((after - before))" '
	    .jobs[0] as $jb | ($jb.read.iops + $jb.write.iops) as $iops |
	    (if $jb.read.iops > 0 then $jb.read else $jb.write end) as $d |
	    [$m, $e, $w, $j, $q, $r, ($iops | floor),
	    ($d.clat_ns.mean / 1000 | floor),
	    ($d.clat_ns.percentile["99.000000"] / 1000 | floor),
	    (($cs / ($iops * '"$RUNTIME"' + 1)) * 100 | floor) / 100] |
	    @tsv' >> "$OUT"/raw.tsv
}

printf 'mode\tengine\trw\tjobs\tqd\tround\tiops\tclat_us\tp99_us\tcs_per_io\n' \
    > "$OUT"/raw.tsv
for round in $(seq 1 $ROUNDS); do
	for mode in off on off2; do
		case $mode in on) v=1 ;; *) v=0 ;; esac
		echo $v | sudo tee "$PARAM" >/dev/null
		for engine in libaio io_uring; do
			for rw in randread randwrite; do
				for jq in "1 1" "1 32" "4 1" "4 32" "16 1" \
				    "16 32"; do
					# shellcheck disable=SC2086
					set -- $jq
					run $mode $engine $rw "$1" "$2" "$round"
				done
			done
		done
	done
done
echo 0 | sudo tee "$PARAM" >/dev/null
sudo ./zpool destroy bench

# mean (min-max) of IOPS over rounds per configuration
awk -F'\t' 'NR > 1 {
	k = $2 "\t" $3 "\t" $4 "\t" $5 "\t" $1
	s[k] += $7; n[k]++; c[k] += $8; x[k] += $10
	if (!(k in lo) || $7 < lo[k]) lo[k] = $7
	if (!(k in hi) || $7 > hi[k]) hi[k] = $7
    } END {
	for (k in s)
		printf "%s\t%d (%d-%d)\t%d\t%.2f\n", k, s[k] / n[k], lo[k],
		    hi[k], c[k] / n[k], x[k] / n[k]
    }' "$OUT"/raw.tsv | sort > "$OUT"/summary.tsv
{
	echo '| engine | rw | jobs | qd | mode | IOPS mean (min-max) | clat µs | cs/IO |'
	echo '|---|---|---|---|---|---|---|---|'
	sed 's/\t/ | /g; s/^/| /; s/$/ |/' "$OUT"/summary.tsv
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
