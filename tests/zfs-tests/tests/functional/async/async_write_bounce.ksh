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
. $STF_SUITE/tests/functional/async/async.cfg
. $STF_SUITE/tests/functional/async/async.kshlib
. $STF_SUITE/tests/functional/direct/dio.kshlib

#
# DESCRIPTION:
#	The async Direct I/O write path honours the per-handle bounce
#	that zpl_iter_write() keeps: once a write on a handle fails
#	checksum verify and is redone from a private copy, every later
#	Direct I/O write on that handle is copied first, so verify fails
#	exactly once per handle, as dio_write_verify_bounce checks for
#	synchronous writes.
#
# STRATEGY:
#	1. Turn on zfs_vdev_direct_write_verify, turn off compression
#	2. Write a file with 128K async O_DIRECT writes, one block each,
#	   from one handle while another thread changes the buffer
#	3. Every write must return its full length
#	4. If no write fails verify, repeat from a new handle, up to ten
#	   tries
#	5. Verify must fail exactly once, and the pool must count every
#	   write plus the one redone
#

verify_runnable "global"

log_assert "Async Direct I/O writes keep copying after a verify failure"

typeset -i NUMBLOCKS=300
typeset -i MAXTRIES=10
typeset -i BS=$((128 * 1024))
typeset mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)
typeset f="$mntpnt/async-bounce"
typeset -i writes fails try before after fails_before fails_after

function cleanup
{
	rm -f $f
	log_must zpool clear $TESTPOOL
	log_must zpool events -c
	log_must restore_tunable VDEV_DIRECT_WR_VERIFY
	log_must zfs set recordsize=$ASYNC_BS_HR $TESTPOOL/$TESTFS
}
log_onexit cleanup

log_must save_tunable VDEV_DIRECT_WR_VERIFY
log_must set_tunable32 VDEV_DIRECT_WR_VERIFY 1
log_must zfs set compression=off recordsize=128k $TESTPOOL/$TESTFS

for ((try = 1; try <= MAXTRIES; try++)); do
	log_must file_write -o create -f $f -b $BS -c $NUMBLOCKS -w
	before=$(kstat_pool $TESTPOOL iostats.direct_write_count)
	fails_before=$(get_zpool_status_chksum_verify_failures \
	    $TESTPOOL "raidz")
	log_must aio_dio_bounce $f $BS $NUMBLOCKS
	after=$(kstat_pool $TESTPOOL iostats.direct_write_count)
	fails_after=$(get_zpool_status_chksum_verify_failures \
	    $TESTPOOL "raidz")
	((writes = after - before))
	((fails = fails_after - fails_before))
	log_note "Try $try: Direct I/O writes $writes," \
	    "checksum verify failures $fails"
	((fails > 0)) && break
done

if ((fails == 0)); then
	log_fail "no write failed verify in $MAXTRIES tries"
fi
if ((fails != 1)); then
	log_fail "$fails checksum verify failures, expected 1"
fi
if ((writes != NUMBLOCKS + fails)); then
	log_fail "$writes Direct I/O writes, expected $((NUMBLOCKS + fails))"
fi

log_must stride_dd -i $f -o /dev/null -b $BS -c $NUMBLOCKS
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "Async Direct I/O writes keep copying after a verify failure"
