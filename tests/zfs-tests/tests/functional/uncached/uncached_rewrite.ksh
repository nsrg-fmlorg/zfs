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
# Verify that zfs rewrite does not leave the blocks it rewrites in the dbuf
# cache.  It reads them uncached, and dirtying them must not undo that.
#
# STRATEGY:
# 1. Write a file of whole records and export and import the pool, so that
#    none of its dbufs are cached.
# 2. Rewrite it with zfs rewrite, sync, and count the file's level 0 dbufs
#    left in the dbuf cache; there must be none.  Repeat with -P.
# 3. Read the file normally and count again; the dbufs must now be cached,
#    so the first checks can't pass for the wrong reason.
#

verify_runnable "global"

FS=$TESTPOOL/$TESTFS
FILE=$TESTDIR/$TESTFILE0
RECSIZE=131072
NRECS=8
DBUFS_FILE=$(mktemp -t dbufs.out.XXXXXX)

function cleanup
{
	log_must rm -f $FILE $DBUFS_FILE
	log_must zfs inherit recordsize $FS
	log_must zfs inherit compression $FS
}

function cached_dbufs
{
	typeset objset=$(get_prop objsetid $FS)
	typeset obj=$(get_objnum $FILE)

	kstat dbufs > $DBUFS_FILE
	dbufstat -bxn -i $DBUFS_FILE \
	    -F "pool=$TESTPOOL,objset=$objset,object=$obj,level=0" | wc -l
}

function drop_caches
{
	log_must zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
}

log_assert "zfs rewrite does not leave rewritten blocks in the dbuf cache"

log_onexit cleanup

log_must zfs set recordsize=$RECSIZE $FS
log_must zfs set compression=off $FS
log_must dd if=/dev/urandom of=$FILE bs=$RECSIZE count=$NRECS
sync_pool $TESTPOOL

drop_caches
log_must zfs rewrite $FILE
sync_pool $TESTPOOL
sync_pool $TESTPOOL
logical=$(cached_dbufs)

drop_caches
log_must zfs rewrite -P $FILE
sync_pool $TESTPOOL
sync_pool $TESTPOOL
physical=$(cached_dbufs)

drop_caches
log_must eval "cat $FILE > /dev/null"
read=$(cached_dbufs)

log_note "cached level 0 dbufs: rewrite $logical, rewrite -P $physical," \
    "read $read (of $NRECS)"

log_must [ $logical -eq 0 ]
log_must [ $physical -eq 0 ]
log_must [ $read -ge $((NRECS / 2)) ]

log_pass "zfs rewrite does not leave rewritten blocks in the dbuf cache"
