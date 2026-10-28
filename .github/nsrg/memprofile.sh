#!/bin/sh
# memprofile.sh: throughput and ARC footprint of the cache-bypassing
# paths, on one release build.
#
# The pool sits in /dev/shm, the ARC is capped at ARC_MAX and the working
# set is twice that, so a configuration that caches fills the ARC and one
# that bypasses it does not.  arcstats is sampled every second during each
# fio run; the peak and the value at the end are kept.  "default" runs
# twice per round as an A/A control for the noise.
set -eu

OUT=/var/tmp/mem
HERE=$(pwd)
ROUNDS=3
ARC_MAX=$((2 * 1024 * 1024 * 1024))
SIZE=4G
RUNTIME=20
CONFIGS="default default2 pc_metadata direct_always fio_direct fio_uncached
    fio_noreuse"
mkdir -p "$OUT"

# fio_has <option>: does this fio know the option?  --cmdhelp indents
# the name, and the full list is checked too, so one miss is not the
# answer.
fio_has() {
	fio --cmdhelp="$1" 2>/dev/null | grep -q "^ *$1:" ||
	    fio --cmdhelp=all 2>/dev/null | grep -q "^ *$1 "
}

{
	fio --version
	uname -r
	for o in uncached fadvise_hint; do
		if fio_has "$o"; then echo "fio option $o: yes"; else
		    echo "fio option $o: no"; fi
	done
	fio --cmdhelp=fadvise_hint 2>&1 | sed -n '1,12p'
} | tee "$OUT"/env.txt

arc() {	# arc <stat>
	awk -v k="$1" '$1 == k { print $3 }' /proc/spl/kstat/zfs/arcstats
}

# sample <file>: one line per second until killed
sample() {
	while :; do
		printf '%s %s %s %s\n' "$(arc size)" "$(arc data_size)" \
		    "$(arc metadata_size)" "$(arc dbuf_size)" >> "$1"
		sleep 1
	done
}

pool_create() {	# pool_create <config>
	sudo truncate -s 8G /dev/shm/vdev
	props="-O compression=off -O recordsize=1M -O atime=off"
	case $1 in
	pc_metadata)	props="$props -O primarycache=metadata" ;;
	direct_always)	props="$props -O direct=always" ;;
	esac
	# shellcheck disable=SC2086
	sudo ./zpool create -f $props bench /dev/shm/vdev
}

pool_cycle() {	# drop the ARC contents for this pool
	sudo ./zpool export bench
	sudo ./zpool import -d /dev/shm bench
}

fio_opts() {	# fio_opts <config>
	case $1 in
	fio_direct)	echo "--direct=1" ;;
	fio_uncached)	echo "--uncached=1" ;;
	fio_noreuse)	echo "--fadvise_hint=noreuse" ;;
	*)		echo "" ;;
	esac
}

# measure <round> <config> <rw> <bs>
measure() {
	s="$OUT/samples.$1.$2.$3"
	rm -f "$s"
	sample "$s" &
	spid=$!
	# The JSON goes to a file we own, so the redirect is meant to be ours.
	# shellcheck disable=SC2046,SC2024
	sudo fio --name="$3" --directory=/bench --filename=data \
	    --size=$SIZE --rw="$3" --bs="$4" --numjobs=1 --iodepth=1 \
	    --time_based --runtime=$RUNTIME --output-format=json \
	    $(fio_opts "$2") > "$s.json"
	kill "$spid"
	wait "$spid" 2>/dev/null || true
	bw=$(jq '(.jobs[0].read.bw_bytes + .jobs[0].write.bw_bytes)
	    / 1048576 | floor' "$s.json")
	peak=$(awk 'BEGIN { m = 0 } $1 > m { m = $1 } END { print int(m / 1048576) }' "$s")
	pdata=$(awk 'BEGIN { m = 0 } $2 > m { m = $2 } END { print int(m / 1048576) }' "$s")
	end=$(tail -1 "$s" | awk '{ printf "%d\t%d\t%d\t%d", $1/1048576, $2/1048576, $3/1048576, $4/1048576 }')
	printf '%s\t%s\t%s/%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" \
	    "$bw" "$peak" "$pdata" "$end" >> "$OUT"/raw.tsv
}

"$HERE"/.github/nsrg/build.sh "$HERE" release
"$HERE"/.github/nsrg/load.sh "$HERE"
echo "$ARC_MAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null

printf 'round\tconfig\tworkload\tMiB/s\tpeak_size\tpeak_data\tend_size\tend_data\tend_meta\tend_dbuf\n' > "$OUT"/raw.tsv

r=1
while [ $r -le $ROUNDS ]; do
	for c in $CONFIGS; do
		if [ "$c" = fio_uncached ] && ! fio_has uncached; then
			continue
		fi
		if [ "$c" = fio_noreuse ] &&
		    ! fio --cmdhelp=fadvise_hint | grep -q noreuse; then
			continue
		fi
		pool_create "$c"
		sudo fio --name=fill --directory=/bench --filename=data \
		    --size=$SIZE --rw=write --bs=1M --end_fsync=1 >/dev/null
		pool_cycle
		measure $r "$c" write 1M
		measure $r "$c" randwrite 128k
		pool_cycle
		measure $r "$c" read 1M
		pool_cycle
		measure $r "$c" randread 128k
		sudo ./zpool destroy bench
		sudo rm -f /dev/shm/vdev
	done
	r=$((r + 1))
done

# config/workload: mean, min-max of MiB/s and of peak ARC size
awk -F'\t' 'NR > 1 {
	k = $2 "\t" $3
	n[k]++; s[k] += $4; p[k] += $5
	if (!(k in bl) || $4 < bl[k]) bl[k] = $4
	if (!(k in bh) || $4 > bh[k]) bh[k] = $4
	if (!(k in pl) || $5 < pl[k]) pl[k] = $5
	if (!(k in ph) || $5 > ph[k]) ph[k] = $5
    }
    END {
	print "config\tworkload\tMiB/s mean\tMiB/s min-max\tpeak ARC MiB mean\tpeak min-max"
	for (k in n)
		printf "%s\t%d\t%d-%d\t%d\t%d-%d\n", k, s[k] / n[k], bl[k],
		    bh[k], p[k] / n[k], pl[k], ph[k]
    }' "$OUT"/raw.tsv | sort | tee "$OUT"/summary.tsv |
    column -t -s "$(printf '\t')" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
