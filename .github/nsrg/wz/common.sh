# shellcheck shell=sh disable=SC2154
# Sourced by the wz*.sh measure scripts.  Make a pool and a sparse,
# uncompressed zvol, count the bios that reach it by operation
# (REQ_OP_WRITE=1, REQ_OP_DISCARD=3, REQ_OP_WRITE_ZEROES=9), and read its
# referenced space.
wz_setup() {	# wz_setup <srcdir>
	src=$1
	"$here"/.github/nsrg/load.sh "$src"
	sudo truncate -s 6G /var/tmp/wz-vdev
	sudo "$src"/zpool create -f wz /var/tmp/wz-vdev
	sudo "$src"/zfs create -s -V 4G -o volblocksize=16k \
	    -o compression=off wz/vol
	sudo udevadm settle
	dev=$(basename "$(readlink -f /dev/zvol/wz/vol)")
}

wz_trace_start() {	# wz_trace_start <file>
	# The file is ours; only bpftrace needs root.
	# shellcheck disable=SC2024
	sudo bpftrace -e "kprobe:submit_bio {
		\$b = (struct bio *)arg0;
		if (\$b->bi_bdev->bd_disk->disk_name == \"$dev\") {
			@op[\$b->bi_opf & 0xff] = count();
		}
	}" > "$1" 2>&1 &
	bt=$!
	sleep 5
}

wz_trace_stop() {
	sudo kill -INT "$bt"
	wait "$bt" || true
}

wz_ref() {
	sudo "$src"/zpool sync wz
	sudo "$src"/zfs get -Hpo value referenced wz/vol
}

wz_teardown() {
	sudo "$src"/zpool destroy wz
	sudo rm -f /var/tmp/wz-vdev
}
