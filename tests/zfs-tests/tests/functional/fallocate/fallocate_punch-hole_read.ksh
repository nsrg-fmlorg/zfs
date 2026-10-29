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
. $STF_SUITE/include/blkdev.shlib

#
# DESCRIPTION:
# A range freed by PUNCH_HOLE, or by truncating and extending a file, reads
# back as zeroes at once, before the txg that records the free has synced,
# even when the old blocks are still in the ARC.
#
# STRATEGY:
# 1. Hold txgs open by raising zfs_txg_timeout.
# 2. Write a file, sync it, and read it twice with the page cache dropped
#    in between, so its blocks sit in the ARC with no dbuf data attached.
# 3. Punch out the second record and read it straight back: it must be zero.
# 4. Do the same with truncate down and back up instead of a punch.
# 5. Do the same on a zvol with a discard, reading with O_DIRECT so that
#    the block device's page cache stays out of the way.
#
# The parent block pointer still names the old block until the txg syncs;
# only dnode_block_freed() knows the range is gone.
#

verify_runnable "global"

if is_freebsd; then
	log_unsupported "FreeBSD has no PUNCH_HOLE fallocate."
fi

FILE=$TESTDIR/$TESTFILE0
VOL=$TESTPOOL/punchvol
DEV=$ZVOL_DEVDIR/$VOL
BLKSZ=$((128 * 1024))
PASSES=20

function cleanup
{
	restore_tunable TXG_TIMEOUT
	log_must zfs inherit recordsize $TESTPOOL/$TESTFS
	log_must zfs inherit compression $TESTPOOL/$TESTFS
	[[ -e $TESTDIR ]] && rm -f $FILE
	datasetexists $VOL && destroy_dataset $VOL
}

function warm
{
	log_must dd if=/dev/urandom of=$FILE bs=$BLKSZ count=8 status=none
	sync_pool $TESTPOOL
	log_must cat $FILE > /dev/null
	echo 3 > /proc/sys/vm/drop_caches
	log_must cat $FILE > /dev/null
}

function second_record_zero
{
	cmp -s -n $BLKSZ -i $BLKSZ:0 $FILE /dev/zero
}

log_assert "A freed range reads as zeroes before its txg syncs"
log_onexit cleanup

log_must save_tunable TXG_TIMEOUT
log_must set_tunable64 TXG_TIMEOUT 300
log_must zfs set recordsize=$BLKSZ $TESTPOOL/$TESTFS
log_must zfs set compression=off $TESTPOOL/$TESTFS

stale=0
for i in $(seq $PASSES); do
	warm
	log_must punch_hole $BLKSZ $BLKSZ $FILE
	second_record_zero || stale=$((stale + 1))
done
log_note "stale reads after punch: $stale/$PASSES"
[[ $stale -eq 0 ]] || log_fail "$stale/$PASSES reads after punch were stale"

stale=0
for i in $(seq $PASSES); do
	warm
	log_must truncate -s $BLKSZ $FILE
	log_must truncate -s $((BLKSZ * 8)) $FILE
	second_record_zero || stale=$((stale + 1))
done
log_note "stale reads after truncate and extend: $stale/$PASSES"
[[ $stale -eq 0 ]] || \
    log_fail "$stale/$PASSES reads after truncate and extend were stale"

log_must zfs create -V $((BLKSZ * 8)) -o volblocksize=$BLKSZ \
    -o compression=off $VOL
block_device_wait $DEV

stale=0
for i in $(seq $PASSES); do
	log_must dd if=/dev/urandom of=$DEV bs=$BLKSZ count=8 oflag=direct \
	    status=none
	sync_pool $TESTPOOL
	log_must dd if=$DEV of=/dev/null bs=$BLKSZ iflag=direct status=none
	echo 3 > /proc/sys/vm/drop_caches
	log_must dd if=$DEV of=/dev/null bs=$BLKSZ iflag=direct status=none
	log_must blkdiscard -o $BLKSZ -l $BLKSZ $DEV
	dd if=$DEV bs=$BLKSZ skip=1 count=1 iflag=direct status=none | \
	    cmp -s -n $BLKSZ - /dev/zero || stale=$((stale + 1))
done
log_note "stale reads after zvol discard: $stale/$PASSES"
[[ $stale -eq 0 ]] || \
    log_fail "$stale/$PASSES reads after zvol discard were stale"

log_pass "A freed range reads as zeroes before its txg syncs"
