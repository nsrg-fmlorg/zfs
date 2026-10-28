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
#	The direct property applies to volumes.
#
# STRATEGY:
#	1. A new volume reports direct=standard.
#	2. Each valid value can be set and read back; an invalid one is
#	   refused.
#	3. A volume inherits the value of its parent filesystem.
#

verify_runnable "global"

PARENT="$TESTPOOL/direct_parent"
ZVOL="$PARENT/vol"

function cleanup
{
	datasetexists $PARENT && destroy_dataset $PARENT -r
	block_device_wait
}

log_assert "The direct property applies to volumes"
log_onexit cleanup

log_must zfs create $PARENT
log_must zfs create -V $VOLSIZE $ZVOL
log_must eval "[[ $(get_prop direct $ZVOL) == standard ]]"

for value in always disabled standard; do
	log_must zfs set direct=$value $ZVOL
	log_must eval "[[ $(get_prop direct $ZVOL) == $value ]]"
done
log_mustnot zfs set direct=sometimes $ZVOL

log_must zfs inherit direct $ZVOL
log_must zfs set direct=always $PARENT
log_must eval "[[ $(get_prop direct $ZVOL) == always ]]"
log_must eval "[[ '$(zfs get -H -o source direct $ZVOL)' == \
    'inherited from $PARENT' ]]"

log_pass "The direct property applies to volumes"
