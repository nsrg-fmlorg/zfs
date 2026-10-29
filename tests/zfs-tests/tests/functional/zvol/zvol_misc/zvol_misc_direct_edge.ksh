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
#	Direct I/O on a volume holds up in the cases the basic test does
#	not reach.
#
# STRATEGY:
#	1. A buffer changed while a direct write is in flight leaves no
#	   checksum error behind.
#	2. With zfs_dio_enabled=0, direct=always does no Direct I/O.
#	3. Rewriting the same data directly is a nopwrite: the block
#	   pointers do not change.
#	4. direct=always works with volmode=dev.
#	5. On a mirror with checksum errors injected on one side, direct
#	   reads return the right data.
#	6. Direct and buffered sync writes, interleaved and overlapping,
#	   are all there after ZIL replay.
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "Direct I/O on volumes is implemented on Linux only"
fi

ZVOL="$TESTPOOL/dvol"
ZDEV="$ZVOL_DEVDIR/$ZVOL"
DATA="$(mktemp -t zvol_dio_edge.XXXXXX)"
READ="$(mktemp -t zvol_dio_edge_rd.XXXXXX)"
EXPECT="$(mktemp -t zvol_dio_edge_ex.XXXXXX)"
MPOOL=dio_mirror
MDIR="$TEST_BASE_DIR/zvol_dio_edge"
MB=1048576
BLK=131072
SAVED_DIO=$(get_tunable DIO_ENABLED)

function cleanup
{
	zinject -c all >/dev/null 2>&1
	set_tunable32 DIO_ENABLED $SAVED_DIO
	datasetexists $ZVOL && destroy_dataset $ZVOL
	poolexists $MPOOL && destroy_pool $MPOOL
	block_device_wait
	rm -rf "$DATA" "$READ" "$EXPECT" "$MDIR"
}

function dio_writes # pool
{
	kstat_pool $1 iostats.direct_write_count
}

function dio_reads # pool
{
	kstat_pool $1 iostats.direct_read_count
}

# l0_bps: the volume's level 0 block pointers, as in dio_nopwrite.ksh
function l0_bps # volume
{
	zdb -ddddd $1 1 | awk '$2 == "L0" { print $1, $3, $6 }'
}

function new_zvol # extra options
{
	datasetexists $ZVOL && log_must_busy zfs destroy $ZVOL
	log_must zfs create -V 64M -b 128K -o direct=always "$@" $ZVOL
	block_device_wait $ZDEV
}

log_assert "Direct I/O on a volume holds up in edge cases"
log_onexit cleanup

log_must dd if=/dev/urandom of="$DATA" bs=1M count=8 status=none

log_note "1. buffer changed during a direct write"
new_zvol -o compression=off
typeset wr=$(dio_writes $TESTPOOL)
log_must manipulate_user_buffer -f "$ZDEV" -n 200 -b $BLK -w
log_must test "$(dio_writes $TESTPOOL)" -gt "$wr"
log_must zpool scrub -w $TESTPOOL
log_must test "$(zpool status -x $TESTPOOL)" = \
    "pool '$TESTPOOL' is healthy"

log_note "2. zfs_dio_enabled=0 turns direct=always off"
log_must set_tunable32 DIO_ENABLED 0
wr=$(dio_writes $TESTPOOL)
typeset rd=$(dio_reads $TESTPOOL)
log_must dd if="$DATA" of="$ZDEV" oflag=direct bs=1M count=8 status=none
log_must dd if="$ZDEV" of="$READ" iflag=direct bs=1M count=8 status=none
log_must cmp "$DATA" "$READ"
log_must test "$(dio_writes $TESTPOOL)" -eq "$wr"
log_must test "$(dio_reads $TESTPOOL)" -eq "$rd"
log_must set_tunable32 DIO_ENABLED $SAVED_DIO

log_note "3. a direct rewrite of the same data is a nopwrite"
new_zvol -o checksum=sha256 -o compression=lz4
log_must dd if="$DATA" of="$ZDEV" bs=$BLK count=8 status=none
sync_pool $TESTPOOL
typeset before=$(l0_bps $ZVOL)
log_note "L0 block pointers before: $before"
log_must test "$(echo "$before" | wc -l)" -eq 8
wr=$(dio_writes $TESTPOOL)
log_must dd if="$DATA" of="$ZDEV" oflag=direct bs=$BLK count=8 \
    status=none
log_must test "$(($(dio_writes $TESTPOOL) - wr))" -ge 8
sync_pool $TESTPOOL
typeset after=$(l0_bps $ZVOL)
log_note "L0 block pointers after: $after"
[[ "$before" == "$after" ]] || log_fail "The direct rewrites were not nopwrites"

log_note "4. volmode=dev"
new_zvol -o compression=off -o volmode=dev
wr=$(dio_writes $TESTPOOL)
log_must dd if="$DATA" of="$ZDEV" oflag=direct bs=1M count=8 status=none
log_must dd if="$ZDEV" of="$READ" iflag=direct bs=1M count=8 status=none
log_must cmp "$DATA" "$READ"
log_must test "$(dio_writes $TESTPOOL)" -gt "$wr"

log_note "5. direct reads on a mirror with checksum errors on one side"
log_must mkdir -p "$MDIR"
log_must truncate -s 256M "$MDIR/a" "$MDIR/b"
log_must zpool create $MPOOL mirror "$MDIR/a" "$MDIR/b"
log_must zfs create -V 64M -b 128K -o direct=always -o compression=off \
    $MPOOL/vol
typeset mdev="$ZVOL_DEVDIR/$MPOOL/vol"
block_device_wait $mdev
log_must dd if="$DATA" of="$mdev" oflag=direct bs=1M count=8 status=none
# Re-import so the data is read from the disks, not the ARC.
log_must_busy zpool export $MPOOL
log_must zpool import -d "$MDIR" $MPOOL
block_device_wait $mdev
log_must zinject -d "$MDIR/a" -e corrupt -T read -f 100 $MPOOL
rd=$(dio_reads $MPOOL)
log_must dd if="$mdev" of="$READ" iflag=direct bs=1M count=8 status=none
log_must zinject -c all
log_must cmp "$DATA" "$READ"
log_must test "$(dio_reads $MPOOL)" -gt "$rd"
typeset cksum=$(zpool status -p $MPOOL | awk -v v="$MDIR/a" \
    '$1 == v { print $5 }')
log_note "checksum errors on $MDIR/a: $cksum"
log_must test "$cksum" -gt 0
log_must_busy zfs destroy $MPOOL/vol
log_must destroy_pool $MPOOL

log_note "6. interleaved direct and buffered sync writes survive replay"
new_zvol -o compression=off
# No fill before the freeze: on master, writing 16M, syncing, freezing and
# then making two or more sync writes trips VERIFY3U(max_lr_seq, <,
# lr->lrc_seq) in zil_parse() at import, with or without Direct I/O.
# That is a separate bug; every block compared below is written here.
sync_pool $TESTPOOL
log_must zpool freeze $TESTPOOL
# Even blocks direct, odd blocks buffered, then an overlapping pass the
# other way round over the first half: the replayed volume must end up
# with the last write to each block.
typeset i
for ((i = 0; i < 16; i++)); do
	if ((i % 2 == 0)); then
		typeset f="oflag=direct,dsync"
	else
		typeset f="oflag=dsync"
	fi
	log_must dd if="$DATA" of="$ZDEV" $f bs=$BLK count=1 skip=$i \
	    seek=$i conv=notrunc status=none
done
for ((i = 0; i < 8; i++)); do
	if ((i % 2 == 0)); then
		typeset f="oflag=dsync"
	else
		typeset f="oflag=direct,dsync"
	fi
	log_must dd if="$DATA" of="$ZDEV" $f bs=$BLK count=1 \
	    skip=$((i + 32)) seek=$i conv=notrunc status=none
done
log_must_busy zpool export $TESTPOOL
log_must zpool import $TESTPOOL
block_device_wait $ZDEV
# Expected: blocks 0-7 from DATA blocks 32-39, blocks 8-15 from 8-15.
log_must dd if="$DATA" of="$EXPECT" bs=$BLK skip=32 count=8 status=none
log_must dd if="$DATA" of="$EXPECT" bs=$BLK skip=8 seek=8 count=8 \
    conv=notrunc status=none
log_must dd if="$ZDEV" of="$READ" bs=$BLK count=16 status=none
log_must cmp "$EXPECT" "$READ"

log_pass "Direct I/O on a volume holds up in edge cases"
