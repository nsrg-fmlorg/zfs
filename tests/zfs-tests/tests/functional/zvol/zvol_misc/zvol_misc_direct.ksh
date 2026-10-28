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
#	Direct I/O on a volume follows its direct property.
#
# STRATEGY:
#	For both the blk-mq and the bio paths:
#	1. With direct=standard, O_DIRECT on the device still goes through
#	   the ARC: no Direct I/O is counted.
#	2. With direct=always, aligned writes and reads are counted as
#	   Direct I/O and the data reads back intact.
#	3. With direct=always, a request at a 512 byte offset is served
#	   through the ARC and the data is intact.
#	4. Data written directly reads back through the ARC, and data
#	   written through the ARC reads back directly, before any txg sync.
#	5. With nopwrite possible (sha256, compression), rewriting the
#	   same data directly is safe.
#	6. A direct sync write survives ZIL replay.
#	7. Direct I/O works on a volume in a raidz pool, where #18661 is
#	   reported to have crashed.
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "Direct I/O on volumes is implemented on Linux only"
fi

ZVOL="$TESTPOOL/dvol"
ZDEV="$ZVOL_DEVDIR/$ZVOL"
DATA="$(mktemp -t zvol_misc_direct.XXXXXX)"
READ="$(mktemp -t zvol_misc_direct_rd.XXXXXX)"
# Sizes are given in bytes: verify_dev computes with them, and ksh
# arithmetic does not understand dd's suffixes ("1M * 4" is an error that
# leaves the comparison undone, the bug #18661's tests had).
MB=1048576
RZPOOL=dio_raidz
RZDIR="$TEST_BASE_DIR/zvol_misc_direct"

function cleanup
{
	datasetexists $ZVOL && destroy_dataset $ZVOL
	poolexists $RZPOOL && destroy_pool $RZPOOL
	block_device_wait
	rm -rf "$DATA" "$READ" "$RZDIR"
}

function dio_writes
{
	kstat_pool $TESTPOOL iostats.direct_write_count
}

function dio_reads
{
	kstat_pool $TESTPOOL iostats.direct_read_count
}

# write_dev <dd flags> <bs> <count> <seek>: write $DATA to the volume
function write_dev
{
	log_must dd if="$DATA" of="$ZDEV" $1 bs=$2 count=$3 seek=$4 \
	    conv=notrunc status=none
}

# verify_dev <dd flags> <bs> <count> <skip>: read back and compare
function verify_dev
{
	log_must dd if="$ZDEV" of="$READ" $1 bs=$2 count=$3 skip=$4 \
	    status=none
	log_must cmp -n $(($2 * $3)) "$DATA" "$READ"
}

function do_test
{
	log_must zfs create -V $VOLSIZE -b 16K -o compression=off $ZVOL
	block_device_wait $ZDEV

	log_note "direct=standard: O_DIRECT stays in the ARC"
	typeset wr rd
	wr=$(dio_writes)
	rd=$(dio_reads)
	write_dev oflag=direct $MB 4 0
	verify_dev iflag=direct $MB 4 0
	log_must test "$(dio_writes)" -eq $wr
	log_must test "$(dio_reads)" -eq $rd

	log_note "direct=always: aligned I/O is direct"
	log_must zfs set direct=always $ZVOL
	wr=$(dio_writes)
	rd=$(dio_reads)
	write_dev oflag=direct $MB 4 4
	verify_dev iflag=direct $MB 4 4
	log_must test "$(dio_writes)" -gt $wr
	log_must test "$(dio_reads)" -gt $rd

	log_note "direct=always: a 512 byte offset goes through the ARC"
	wr=$(dio_writes)
	write_dev oflag=direct 512 64 17
	verify_dev iflag=direct 512 64 17
	log_must test "$(dio_writes)" -eq $wr

	log_note "coherency before txg sync, both ways"
	write_dev oflag=direct $MB 2 8
	log_must zfs set direct=standard $ZVOL
	verify_dev "" $MB 2 8
	write_dev "" $MB 2 10
	log_must zfs set direct=always $ZVOL
	verify_dev iflag=direct $MB 2 10

	log_note "nopwrite: rewrite identical data directly"
	log_must zfs set checksum=sha256 compression=lz4 $ZVOL
	write_dev oflag=direct $MB 2 12
	sync_pool $TESTPOOL
	write_dev oflag=direct $MB 2 12
	verify_dev iflag=direct $MB 2 12

	log_note "a direct sync write is replayed from the ZIL"
	sync_pool $TESTPOOL
	log_must zpool freeze $TESTPOOL
	write_dev oflag=direct,dsync $MB 4 16
	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	block_device_wait $ZDEV
	verify_dev iflag=direct $MB 4 16

	log_must_busy zfs destroy $ZVOL
	block_device_wait
}

function raidz_test
{
	typeset rzdev="$ZVOL_DEVDIR/$RZPOOL/vol"

	log_must mkdir -p "$RZDIR"
	log_must truncate -s 512M "$RZDIR/a" "$RZDIR/b" "$RZDIR/c"
	log_must zpool create $RZPOOL raidz1 "$RZDIR/a" "$RZDIR/b" \
	    "$RZDIR/c"
	log_must zfs create -V 128M -b 16K -o direct=always \
	    -o compression=off $RZPOOL/vol
	block_device_wait $rzdev

	typeset wr
	wr=$(kstat_pool $RZPOOL iostats.direct_write_count)
	log_must dd if="$DATA" of="$rzdev" oflag=direct bs=1M count=4 \
	    status=none
	log_must test "$(kstat_pool $RZPOOL iostats.direct_write_count)" \
	    -gt "$wr"
	log_must dd if="$rzdev" of="$READ" iflag=direct bs=1M count=4 \
	    status=none
	log_must cmp "$DATA" "$READ"

	log_must_busy zfs destroy $RZPOOL/vol
	log_must destroy_pool $RZPOOL
}

log_assert "Direct I/O on a volume follows its direct property"
log_onexit cleanup

log_must dd if=/dev/urandom of="$DATA" bs=1M count=4 status=none

for blk_mq in 0 1; do
	log_note "zvol_use_blk_mq=$blk_mq"
	set_blk_mq $blk_mq
	log_must_busy zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	do_test
	raidz_test
done

log_pass "Direct I/O on a volume follows its direct property"
