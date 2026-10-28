// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026, Showta Ishizaki.
 */

#include <string.h>

#include <sys/types.h>
#include <sys/abd.h>
#include <sys/zio_compress.h>

#include "unit.h"

/* ========== */

/*
 * The slack compressor goes through the abd borrow/return wrappers.  These
 * stand-ins treat an abd_t pointer as the address of a flat buffer, which is
 * all the wrappers need, so the test does not pull in the abd machinery.
 */
void *
abd_borrow_buf(abd_t *abd, size_t n)
{
	(void) n;
	return (abd);
}

void *
abd_borrow_buf_copy(abd_t *abd, size_t n)
{
	(void) n;
	return (abd);
}

void
abd_return_buf(abd_t *abd, void *buf, size_t n)
{
	(void) abd, (void) buf, (void) n;
}

void
abd_return_buf_copy(abd_t *abd, void *buf, size_t n)
{
	(void) abd, (void) buf, (void) n;
}

#define	BUF(p)	((abd_t *)(void *)(p))

/* ========== */

#define	BLKSZ	4096
#define	GUARD	64

static uint8_t src[BLKSZ + GUARD] __attribute__((aligned(8)));
static uint8_t dst[BLKSZ + GUARD] __attribute__((aligned(8)));

/*
 * Trailing zeroes are trimmed back to the end of the last word that is not
 * zero, so 1001 bytes of data keep 1008, and decompression restores them.
 */
#define	DATALEN	1001

static MunitResult
test_slack_roundtrip(const MunitParameter params[], void *data)
{
	(void) params, (void) data;

	memset(src, 0, sizeof (src));
	memset(src, 0xa5, DATALEN);

	size_t c_len = zfs_slack_compress(BUF(src), BUF(dst), BLKSZ, BLKSZ, 0);
	unit_eq(c_len, (size_t)P2ROUNDUP(DATALEN, sizeof (uint64_t)));

	memset(src, 0xff, sizeof (src));
	unit_zero(zfs_slack_decompress(BUF(dst), BUF(src), c_len, BLKSZ, 0));
	for (size_t i = 0; i < BLKSZ; i++)
		unit_eq(src[i], (uint8_t)(i < DATALEN ? 0xa5 : 0));

	return (MUNIT_OK);
}

/* A block with nothing to trim is returned as incompressible. */
static MunitResult
test_slack_full(const MunitParameter params[], void *data)
{
	(void) params, (void) data;

	memset(src, 0xa5, BLKSZ);
	unit_eq(zfs_slack_compress(BUF(src), BUF(dst), BLKSZ, BLKSZ / 2, 0),
	    (size_t)BLKSZ);

	return (MUNIT_OK);
}

/*
 * A physical size larger than the logical one only comes from a damaged
 * block pointer.  It must be refused, not copied past the end of dst.
 */
static MunitResult
test_slack_oversize(const MunitParameter params[], void *data)
{
	(void) params, (void) data;

	memset(src, 0xa5, sizeof (src));
	memset(dst, 0, sizeof (dst));

	unit_ne(zfs_slack_decompress(BUF(src), BUF(dst), BLKSZ + GUARD,
	    BLKSZ, 0), 0);
	for (size_t i = BLKSZ; i < BLKSZ + GUARD; i++)
		unit_eq(dst[i], (uint8_t)0);

	return (MUNIT_OK);
}

/* ========== */

static const MunitTest slack_tests[] = {
	UNIT_TEST("roundtrip",	test_slack_roundtrip),
	UNIT_TEST("full",	test_slack_full),
	UNIT_TEST("oversize",	test_slack_oversize),
	{ 0 },
};

static const MunitSuite slack_test_suite = {
	"slack.",
	slack_tests,
	NULL,
	1,
	MUNIT_SUITE_OPTION_NONE,
};

int
main(int argc, char **argv)
{
	return (munit_suite_main(&slack_test_suite, NULL, argc, argv));
}
