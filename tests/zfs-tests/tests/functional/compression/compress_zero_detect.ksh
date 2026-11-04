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
. $STF_SUITE/tests/functional/nopwrite/nopwrite.shlib

#
# DESCRIPTION:
# compression=zero-detect stores zero blocks as holes and every other
# block uncompressed.
#
# STRATEGY:
# 1. A file of zeroes allocates no data blocks.
# 2. A record with zero runs is not compressed, where zle compresses it.
# 3. Zero records inside a file become holes and the file reads back.
# 4. The dataset can be the bootfs and nopwrite works.
# 5. Encrypted datasets behave the same.
# 6. The value survives send -p, and zstream recompress refuses it.
#

verify_runnable "global"

fs=$TESTPOOL/zd
dst=$TESTPOOL/zd_recv
crypt=$TESTPOOL/zd_crypt
stream=$TEST_BASE_DIR/zero_detect.$$
mb=$((1024 * 1024))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -R
	datasetexists $dst && destroy_dataset $dst -R
	datasetexists $crypt && destroy_dataset $crypt -R
	rm -f $stream
	zpool set bootfs= $TESTPOOL
}

function refer
{
	sync_pool $TESTPOOL > /dev/null
	get_prop referenced $1
}

log_onexit cleanup
log_assert "compression=zero-detect only turns zero blocks into holes"

log_must zfs create -o compression=zero-detect -o recordsize=128k $fs
log_must test "$(get_prop compression $fs)" = zero-detect
dir=$(get_prop mountpoint $fs)

# All zeroes: no data blocks.
log_must dd if=/dev/zero of=$dir/zero bs=1M count=16
log_must test $(refer $fs) -lt $((2 * mb))
log_must rm $dir/zero
sync_pool $TESTPOOL

# 64k of random data and 64k of zeroes in each record: half of it could
# be saved, and zero-detect must not save it.
log_must dd if=/dev/urandom of=$TEST_BASE_DIR/half.$$ bs=64k count=1
log_must dd if=/dev/zero of=$TEST_BASE_DIR/half.$$ bs=64k count=1 seek=1
for i in {1..64}; do
	cat $TEST_BASE_DIR/half.$$
done > $dir/half
rm -f $TEST_BASE_DIR/half.$$
log_must test $(refer $fs) -ge $((8 * mb))
log_must zfs set compression=zle $fs
log_must dd if=$dir/half of=$dir/half.zle bs=128k
log_must rm $dir/half
log_must test $(refer $fs) -lt $((6 * mb))
log_must rm $dir/half.zle
log_must zfs set compression=zero-detect $fs
sync_pool $TESTPOOL

# Zero records in the middle of a file become holes and read back.
log_must dd if=/dev/urandom of=$dir/mixed bs=1M count=4
log_must dd if=/dev/zero of=$dir/mixed bs=1M count=4 seek=4
log_must dd if=/dev/urandom of=$dir/mixed bs=1M count=4 seek=8
sum=$(xxh128digest $dir/mixed)
log_must test $(refer $fs) -lt $((10 * mb))
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
log_must test "$(xxh128digest $dir/mixed)" = "$sum"

# The blocks are ordinary, so a boot loader can read them.
log_must zpool set bootfs=$fs $TESTPOOL
log_must zpool set bootfs= $TESTPOOL

# nopwrite asks for a strong checksum and compression other than off.
log_must zfs set checksum=sha256 $fs
log_must dd if=/dev/urandom of=$dir/nop bs=1M count=8
log_must zfs snapshot $fs@nop
log_must zfs clone $fs@nop $fs/clone
log_must dd if=$dir/nop of=$dir/clone/nop bs=1M count=8 conv=notrunc
log_must verify_nopwrite $fs $fs@nop $fs/clone
log_must zfs destroy -R $fs@nop
log_must zfs set checksum=on $fs

# Encrypted: the same hole, the same uncompressed data.
log_must eval "echo password | zfs create -o encryption=on \
    -o keyformat=passphrase -o compression=zero-detect $crypt"
cdir=$(get_prop mountpoint $crypt)
log_must dd if=/dev/zero of=$cdir/zero bs=1M count=16
log_must test $(refer $crypt) -lt $((2 * mb))
log_must dd if=/dev/urandom of=$cdir/data bs=1M count=8
log_must test $(refer $crypt) -ge $((8 * mb))

# The property travels with the stream; a stream never carries the type.
log_must zfs snapshot $fs@send
log_must eval "zfs send -c -p $fs@send > $stream"
log_must eval "zfs receive $dst < $stream"
log_must test "$(get_prop compression $dst)" = zero-detect
log_must test "$(xxh128digest $(get_prop mountpoint $dst)/mixed)" = "$sum"
log_mustnot eval "zstream recompress zero-detect < $stream > /dev/null"

log_pass "compression=zero-detect only turns zero blocks into holes"
