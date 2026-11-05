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
# Copyright (c) 2026 by Showta Ishizaki. All rights reserved.
#

. $STF_SUITE/tests/functional/slog/slog.kshlib

#
# DESCRIPTION:
#	Verify that a volume's log replays when one chain holds the records
#	of several opens of the volume.
#
#	The last close of a volume frees its zilog_t.  The log chain outlives
#	it, so the next open has to carry on with higher sequence numbers:
#	zil_parse() and zil_replay_log_record() rely on them rising along
#	the chain.  The last open writes less than the others: were the
#	sequence numbers to restart, the claim would record the last one as
#	the highest and replay would stop inside the first open's records.
#
# STRATEGY:
#	1. Create a volume and write to it so that its log has a header.
#	2. Freeze the pool.
#	3. Write synchronously several times, opening and closing the
#	   volume each time.
#	4. Record a checksum of the volume.
#	5. Export the pool and import it, replaying the log.
#	6. Verify the checksum.
#

verify_runnable "global"

VOLUME=$ZVOL_DEVDIR/$TESTPOOL/$TESTVOL

function write_volume # <block size> <block>
{
	log_must dd if=/dev/urandom of=$VOLUME bs=$1 count=1 seek=$2 \
	    oflag=sync conv=notrunc
	block_device_wait $VOLUME
}

log_assert "Replay of a log written across several opens of a volume."
log_onexit cleanup
log_must setup

log_must zpool create $TESTPOOL ${DISKS%% *}
log_must zfs create -V 128M -b 128k -o compression=off $TESTPOOL/$TESTVOL
block_device_wait $VOLUME

write_volume 128k 100
sync_pool $TESTPOOL

log_must zpool freeze $TESTPOOL

for block in 0 0 2 3 3 5 ; do
	write_volume 128k $block
done
write_volume 8k 800

typeset checksum=$(xxh128digest $VOLUME)

# Device probes can briefly keep the closed volume open.
log_must_busy zpool export $TESTPOOL

# It has to be -f because the labels of a frozen pool can't be written.
log_must zpool import -f $TESTPOOL
block_device_wait $VOLUME

typeset checksum1=$(xxh128digest $VOLUME)
[[ "$checksum1" == "$checksum" ]] || \
    log_fail "checksum mismatch ($checksum1 != $checksum)"

log_must zdb -bcv $TESTPOOL

log_pass "Replay of a log written across several opens of a volume."
