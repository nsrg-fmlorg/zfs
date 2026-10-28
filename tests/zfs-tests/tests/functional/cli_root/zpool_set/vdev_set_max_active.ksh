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

#
# DESCRIPTION:
# The max_active vdev property defaults to 0, accepts values up to
# UINT_MAX on leaf and top-level vdevs, survives export and import, and
# a pool whose vdevs allow a single outstanding i/o still does i/o.
#
# STRATEGY:
# 1. Create a mirror pool and check the default.
# 2. Reject values that are not a number or do not fit a uint_t.
# 3. Set it on a leaf and on the top-level vdev; export, import, recheck.
# 4. With max_active=1 on every leaf, write, read back and scrub.
# 5. Set it back to 0 and check the source is default again.
#

verify_runnable "global"

command -v fio > /dev/null || log_unsupported "fio missing"

function cleanup
{
	destroy_pool $TESTPOOL1
	log_must rm -f $DEV1 $DEV2
}

function check_prop # <vdev> <value> <source>
{
	typeset out
	out="$(zpool get -H -o value,source max_active $TESTPOOL1 $1)"
	[[ "$out" == "$2	$3" ]] ||
	    log_fail "max_active on $1: got '$out', expected '$2	$3'"
}

log_assert "max_active vdev property can be set, persists, and caps i/o"
log_onexit cleanup

DEV1="$TEST_BASE_DIR/filedev1.$$"
DEV2="$TEST_BASE_DIR/filedev2.$$"
log_must truncate -s $(($MINVDEVSIZE * 2)) $DEV1 $DEV2
log_must zpool create -f $TESTPOOL1 mirror $DEV1 $DEV2

# 1.
check_prop $DEV1 0 default
check_prop mirror-0 0 default

# 2.
for bad in -1 abc 4294967296; do
	log_mustnot zpool set max_active=$bad $TESTPOOL1 $DEV1
done
check_prop $DEV1 0 default

# 3.
log_must zpool set max_active=4 $TESTPOOL1 $DEV1
log_must zpool set max_active=8 $TESTPOOL1 mirror-0
log_must zpool set max_active=4294967295 $TESTPOOL1 $DEV2
check_prop $DEV1 4 local
check_prop mirror-0 8 local
check_prop $DEV2 4294967295 local
log_must zpool export $TESTPOOL1
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL1
check_prop $DEV1 4 local
check_prop mirror-0 8 local
check_prop $DEV2 4294967295 local

# 4.
log_must zpool set max_active=1 $TESTPOOL1 $DEV1
log_must zpool set max_active=1 $TESTPOOL1 $DEV2
mntpnt=$(get_prop mountpoint $TESTPOOL1)
log_must fio --filename=$mntpnt/file --name=write --rw=write \
    --size=$MINVDEVSIZE --bs=128k --numjobs=4 --ioengine=psync \
    --end_fsync=1 --verify=crc32c
log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"

# 5.
log_must zpool set max_active=0 $TESTPOOL1 $DEV1
check_prop $DEV1 0 default

log_pass "max_active vdev property can be set, persists, and caps i/o"
