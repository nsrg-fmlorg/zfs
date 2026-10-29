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
. $STF_SUITE/tests/functional/l2arc/l2arc.cfg

#
# DESCRIPTION:
#	With l2arc_keep_hot_pct set, blocks kept ahead of the write hand
#	read back intact, also after the L2ARC is rebuilt.
#
# STRATEGY:
#	1. Shrink the ARC and set l2arc_keep_hot_pct=50.
#	2. Create a pool with a small cache device, a small hot file and a
#	   cold file several times the size of the cache device.
#	3. Read the cold file to lap the cache device, reading the hot file
#	   between laps so that it is read from the L2ARC and kept.
#	4. Verify that blocks were kept (l2_keep_hot > 0).
#	5. Verify both files against their digests, export and import the
#	   pool so the L2ARC is rebuilt, verify again, and scrub.
#

verify_runnable "global"

log_assert "Blocks kept by l2arc_keep_hot_pct read back intact."

function cleanup
{
	if poolexists $TESTPOOL ; then
		destroy_pool $TESTPOOL
	fi

	restore_tunable L2ARC_KEEP_HOT_PCT
	restore_tunable L2ARC_NOPREFETCH
	restore_tunable L2ARC_WRITE_MAX
	restore_tunable L2ARC_DWPD_LIMIT
	restore_tunable ARC_MAX
	restore_tunable ARC_MIN
}
log_onexit cleanup

save_tunable L2ARC_KEEP_HOT_PCT
save_tunable L2ARC_NOPREFETCH
save_tunable L2ARC_WRITE_MAX
save_tunable L2ARC_DWPD_LIMIT
save_tunable ARC_MAX
save_tunable ARC_MIN

# zfs_arc_max is ignored unless it is above zfs_arc_min.
log_must set_tunable64 ARC_MIN $((64 * 1024 * 1024))
log_must set_tunable64 ARC_MAX $((128 * 1024 * 1024))
log_must set_tunable32 L2ARC_KEEP_HOT_PCT 50
# Sequential reads are prefetches, which the L2ARC skips by default.
log_must set_tunable32 L2ARC_NOPREFETCH 0
log_must set_tunable64 L2ARC_WRITE_MAX $((64 * 1024 * 1024))
# The cache device laps several times; do not let the DWPD budget stall it.
log_must set_tunable32 L2ARC_DWPD_LIMIT 0

log_must truncate -s 256M $VDEV_CACHE
log_must zpool create -f -O primarycache=all -O compression=off \
    $TESTPOOL $VDEV cache $VDEV_CACHE

typeset hot=/$TESTPOOL/hot cold=/$TESTPOOL/cold
log_must dd if=/dev/urandom of=$hot bs=1M count=16
log_must dd if=/dev/urandom of=$cold bs=1M count=640
typeset hot_sum=$(xxh128digest $hot) cold_sum=$(xxh128digest $cold)

for lap in 1 2 3 4 5 6; do
	log_must cat $cold > /dev/null
	log_must sleep 2
	log_must cat $hot > /dev/null
	log_must sleep 2
done

typeset kept=$(kstat arcstats.l2_keep_hot)
log_note "l2_keep_hot=$kept l2_hits=$(kstat arcstats.l2_hits)" \
    "l2_misses=$(kstat arcstats.l2_misses)"
log_must test $kept -gt 0

log_must test "$(xxh128digest $hot)" = "$hot_sum"
log_must test "$(xxh128digest $cold)" = "$cold_sum"

log_must zpool export $TESTPOOL
log_must zpool import -d $VDIR $TESTPOOL
log_must test "$(xxh128digest $hot)" = "$hot_sum"
log_must test "$(xxh128digest $cold)" = "$cold_sum"

log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_must zpool destroy -f $TESTPOOL

log_pass "Blocks kept by l2arc_keep_hot_pct read back intact."
