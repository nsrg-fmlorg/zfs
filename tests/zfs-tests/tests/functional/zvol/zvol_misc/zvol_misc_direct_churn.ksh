#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright (c) 2026, Showta Ishizaki.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/zvol/zvol_common.shlib

#
# DESCRIPTION:
#	Direct I/O on a volume survives concurrent and disruptive load:
#	the cases #18661's review ran by hand.
#
# STRATEGY:
#	For volblocksize 4K, 16K and 128K, on the blk-mq and bio paths:
#	1. Aligned and sub-block, block-straddling direct writes run
#	   concurrently on disjoint halves of one volume, and each half
#	   verifies.
#	2. Direct I/O runs while snapshots and clones are taken and
#	   destroyed, the volume is rolled back, and zfs_dio_enabled and
#	   the direct property are flipped.
#	3. zfs destroy and zpool export are attempted with direct I/O in
#	   flight; whatever they answer, the pool stays consistent.
#	4. The kernel log shows no assertion, BUG or WARNING, and a scrub
#	   finds nothing.
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "Direct I/O on volumes is implemented on Linux only"
fi

ZVOL="$TESTPOOL/churn"
ZDEV="$ZVOL_DEVDIR/$ZVOL"
CPOOL=dio_churn
CDIR="$TEST_BASE_DIR/zvol_dio_churn"
VOLSZ=$((256 * 1024 * 1024))
RUNTIME=20
SAVED_DIO=$(get_tunable DIO_ENABLED)

function cleanup
{
	pkill -x fio >/dev/null 2>&1
	set_tunable32 DIO_ENABLED $SAVED_DIO
	poolexists $CPOOL && destroy_pool $CPOOL
	datasetexists $ZVOL && destroy_dataset $ZVOL -Rf
	block_device_wait
	rm -rf "$CDIR"
}

# fio_dio <device> <seconds> <extra fio options...>: time-bounded direct
# I/O; aligned on the lower half, 512-byte multiples at 512-byte offsets
# on the upper.
function fio_dio
{
	typeset dev=$1 secs=$2
	shift 2
	fio --name=aligned --filename="$dev" --direct=1 --rw=randwrite \
	    --bs=$VBS --offset=0 --size=$((VOLSZ / 2)) \
	    --time_based --runtime=$secs --ioengine=psync "$@" \
	    --name=straddle --filename="$dev" --direct=1 --rw=randwrite \
	    --bsrange=512-$((2 * VBS)) --blockalign=512 \
	    --offset=$((VOLSZ / 2)) --size=$((VOLSZ / 2)) \
	    --time_based --runtime=$secs --ioengine=psync "$@" \
	    --minimal >/dev/null
}

# Only what this test added to the kernel log counts.
DMESG_START=$(dmesg | wc -l)

function check_kernel_log
{
	if dmesg | tail -n +$((DMESG_START + 1)) | \
	    grep -E 'VERIFY|PANIC|BUG:|WARNING:|ASSERT'; then
		log_fail "kernel log shows a failure"
	fi
}

function do_test
{
	log_must zfs create -V $VOLSZ -b $VBS -o direct=always \
	    -o compression=off $ZVOL
	block_device_wait $ZDEV

	log_note "1. concurrent aligned and straddling direct writes, verified"
	# The straddling job writes sequentially: random writes of varying
	# size overlap one another and overwrite fio's verify headers, which
	# reads as corruption that is not there.  Sizes stay multiples of
	# 512, as O_DIRECT on a block device requires; starting 512 bytes
	# into a block, they still straddle block boundaries.
	log_must fio --name=aligned --filename="$ZDEV" --direct=1 \
	    --rw=randwrite --bs=$VBS --offset=0 --size=$((VOLSZ / 2)) \
	    --verify=crc32c --do_verify=1 --ioengine=psync \
	    --name=straddle --filename="$ZDEV" --direct=1 --rw=write \
	    --bsrange=512-$((2 * VBS)) --blockalign=512 \
	    --offset=$((VOLSZ / 2 + 512)) --size=$((VOLSZ / 4)) \
	    --verify=crc32c --do_verify=1 --ioengine=psync \
	    --output-format=terse

	log_note "2. snapshot, clone, rollback and tunable churn under load"
	fio_dio "$ZDEV" $RUNTIME &
	typeset fpid=$!
	typeset i=0
	while kill -0 $fpid 2>/dev/null; do
		log_must zfs snapshot $ZVOL@s$i
		log_must zfs clone $ZVOL@s$i $ZVOL-c$i
		block_device_wait "$ZVOL_DEVDIR/$ZVOL-c$i"
		log_must dd if="$ZVOL_DEVDIR/$ZVOL-c$i" of=/dev/null \
		    iflag=direct bs=1M count=8 status=none
		log_must_busy zfs destroy $ZVOL-c$i
		if ((i % 3 == 2)); then
			log_must zfs rollback $ZVOL@s$i
		fi
		log_must zfs destroy $ZVOL@s$i
		set_tunable32 DIO_ENABLED $((i % 2))
		log_must zfs set direct=$( ((i % 4 == 3)) && echo standard ||
		    echo always) $ZVOL
		((i++))
	done
	wait $fpid
	log_must set_tunable32 DIO_ENABLED $SAVED_DIO
	log_must zfs set direct=always $ZVOL
	log_note "$i churn rounds"
	check_kernel_log

	log_must_busy zfs destroy -r $ZVOL
}

function disrupt_test
{
	typeset dev="$ZVOL_DEVDIR/$CPOOL/vol"

	log_must mkdir -p "$CDIR"
	log_must truncate -s 512M "$CDIR/a" "$CDIR/b" "$CDIR/c"
	log_must zpool create $CPOOL raidz1 "$CDIR/a" "$CDIR/b" "$CDIR/c"
	log_must zfs create -V $VOLSZ -b 16K -o direct=always \
	    -o compression=off $CPOOL/vol
	block_device_wait $dev

	log_note "3a. zfs destroy -f with direct I/O in flight"
	fio_dio "$dev" 10 &
	typeset fpid=$!
	sleep 3
	# The volume is open, so EBUSY is the expected answer; the point is
	# that asking does no harm to the I/O in flight.
	zfs destroy -f $CPOOL/vol
	log_note "zfs destroy -f answered $?"
	wait $fpid
	datasetexists $CPOOL/vol && log_must_busy zfs destroy $CPOOL/vol

	log_must zfs create -V $VOLSZ -b 16K -o direct=always \
	    -o compression=off $CPOOL/vol
	block_device_wait $dev

	log_note "3b. zpool export -f with direct I/O in flight"
	fio_dio "$dev" 10 &
	fpid=$!
	sleep 3
	zpool export -f $CPOOL
	log_note "zpool export -f answered $?"
	wait $fpid
	poolexists $CPOOL || log_must zpool import -d "$CDIR" $CPOOL
	log_must zpool scrub -w $CPOOL
	log_must test "$(zpool status -x $CPOOL)" = \
	    "pool '$CPOOL' is healthy"
	log_must destroy_pool $CPOOL
	check_kernel_log
}

log_assert "Direct I/O on a volume survives concurrent and disruptive load"
log_onexit cleanup

for blk_mq in 0 1; do
	set_blk_mq $blk_mq
	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	for VBS in 4096 16384 131072; do
		log_note "zvol_use_blk_mq=$blk_mq volblocksize=$VBS"
		do_test
	done
done
disrupt_test

log_must zpool scrub -w $TESTPOOL
log_must test "$(zpool status -x $TESTPOOL)" = \
    "pool '$TESTPOOL' is healthy"

log_pass "Direct I/O on a volume survives concurrent and disruptive load"
