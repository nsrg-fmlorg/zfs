#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
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
#	the chain.
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

function write_volume # <128K block>
{
	log_must dd if=/dev/urandom of=$VOLUME bs=128k count=1 seek=$1 \
	    oflag=sync conv=notrunc
	block_device_wait $VOLUME
}

log_assert "Replay of a log written across several opens of a volume."
log_onexit cleanup
log_must setup

log_must zpool create $TESTPOOL ${DISKS%% *}
log_must zfs create -V 128M -b 128k -o compression=off $TESTPOOL/$TESTVOL
block_device_wait $VOLUME

write_volume 100
sync_pool $TESTPOOL

log_must zpool freeze $TESTPOOL

for block in 0 0 2 3 3 5 ; do
	write_volume $block
done

typeset checksum=$(xxh128digest $VOLUME)

log_note "Verify transactions to replay:"
log_must zdb -iv $TESTPOOL/$TESTVOL

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
