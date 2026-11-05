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

#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/zfs_context.h>
#include <sys/zio_compress.h>

#include "unit.h"

/*
 * zle.c needs only these from the ABD code.  An abd_t here is the buffer.
 */
void *
abd_borrow_buf(abd_t *abd, size_t size)
{
	(void) size;
	return (abd);
}

void *
abd_borrow_buf_copy(abd_t *abd, size_t size)
{
	(void) size;
	return (abd);
}

void
abd_return_buf(abd_t *abd, void *buf, size_t size)
{
	(void) abd, (void) buf, (void) size;
}

void
abd_return_buf_copy(abd_t *abd, void *buf, size_t size)
{
	(void) abd, (void) buf, (void) size;
}

/*
 * The encoder as it was when blocks already on disk were written.  Its result
 * for any input is what zfs_zle_compress() has to go on returning.
 */
static size_t
zle_original(void *s_start, void *d_start, size_t s_len, size_t d_len, int n)
{
	uchar_t *src = s_start;
	uchar_t *dst = d_start;
	uchar_t *s_end = src + s_len;
	uchar_t *d_end = dst + d_len;

	while (src < s_end && dst < d_end - 1) {
		uchar_t *first = src;
		uchar_t *len = dst++;
		if (src[0] == 0) {
			uchar_t *last = src + (256 - n);
			while (src < MIN(last, s_end) && src[0] == 0)
				src++;
			*len = src - first - 1 + n;
		} else {
			uchar_t *last = src + n;
			if (d_end - dst < n)
				break;
			while (src < MIN(last, s_end) - 1 && (src[0] | src[1]))
				*dst++ = *src++;
			if (src[0])
				*dst++ = *src++;
			*len = src - first - 1;
		}
	}
	return (src == s_end ? dst - (uchar_t *)d_start : s_len);
}

#define	MAXLEN		(1 << 13)
#define	MARGIN		16

static uchar_t in[MAXLEN + MARGIN], want[MAXLEN + MARGIN];
static uchar_t got[MAXLEN + MARGIN], back[MAXLEN + MARGIN];

static void
check(uchar_t *s, size_t s_len, size_t d_len, int n)
{
	size_t a, b;

	memset(want, 0xa5, d_len + 1);
	memset(got, 0xa5, d_len + 1);
	a = zle_original(s, want, s_len, d_len, n);
	b = zfs_zle_compress((abd_t *)s, (abd_t *)got, s_len, d_len, n);

	unit_eq(a, b);
	/* The original writes nothing past d_len, and neither may this. */
	unit_eq((int)got[d_len], 0xa5);
	if (a < s_len) {
		unit_eq(memcmp(want, got, a), 0);
		unit_eq(zfs_zle_decompress((abd_t *)got, (abd_t *)back, a,
		    s_len, n), 0);
		unit_eq(memcmp(back, s, s_len), 0);
	}
}

/* Bytes with a chosen share of zeroes, some of them in long runs. */
static void
fill(uchar_t *s, size_t s_len, int zero_pct)
{
	for (size_t i = 0; i < s_len; ) {
		size_t run = munit_rand_int_range(0, 2) == 0 ?
		    munit_rand_int_range(1, 300) : 1;
		int zero = munit_rand_int_range(0, 99) < zero_pct;

		for (; run > 0 && i < s_len; run--, i++)
			s[i] = zero ? 0 : munit_rand_int_range(1, 255);
	}
}

static MunitResult
test_zle_random(const MunitParameter params[], void *data)
{
	(void) params, (void) data;
	static const int pct[] = { 0, 1, 20, 50, 80, 97, 100 };

	for (size_t i = 0; i < 50000; i++) {
		size_t off = munit_rand_int_range(0, MARGIN - 1);
		size_t s_len = munit_rand_int_range(1, 4096);
		size_t d_len = munit_rand_int_range(0, s_len + 8);
		int n = munit_rand_int_range(0, 7) == 0 ?
		    munit_rand_int_range(1, 255) : 64;

		fill(in + off, s_len, pct[i % ARRAY_SIZE(pct)]);
		check(in + off, s_len, d_len, n);
	}
	return (MUNIT_OK);
}

/* Around every limit: chunk lengths, and room left for a chunk. */
static MunitResult
test_zle_boundaries(const MunitParameter params[], void *data)
{
	(void) params, (void) data;
	static const size_t len[] = { 1, 2, 3, 7, 8, 9, 63, 64, 65, 66, 127,
	    128, 129, 191, 192, 193, 194, 255, 256, 257, 512, 4096 };

	for (size_t l = 0; l < ARRAY_SIZE(len); l++) {
		size_t s_len = len[l];

		for (size_t d_len = 0; d_len <= s_len + 3;
		    d_len += s_len > 300 ? 61 : 1) {
			/* Every position of a zero pair and of a lone zero. */
			for (size_t z = 0; z < s_len && z < 80; z++) {
				memset(in, 0x11, s_len);
				in[z] = 0;
				check(in, s_len, d_len, 64);
				if (z + 1 < s_len)
					in[z + 1] = 0;
				check(in, s_len, d_len, 64);
			}
			memset(in, 0, s_len);
			check(in, s_len, d_len, 64);
			in[s_len - 1] = 1;
			check(in, s_len, d_len, 64);
			memset(in, 0x11, s_len);
			check(in, s_len, d_len, 64);
		}
	}
	return (MUNIT_OK);
}

/* zio_write_compress() asks for 1/8 of the block to be saved. */
static MunitResult
test_zle_block_sizes(const MunitParameter params[], void *data)
{
	(void) params, (void) data;
	static const size_t len[] = { 512, 4096, 8192 };

	for (size_t i = 0; i < 5000; i++) {
		size_t s_len = len[i % ARRAY_SIZE(len)];

		/* About where the saving crosses 1/8. */
		fill(in, s_len, munit_rand_int_range(5, 30));
		check(in, s_len, s_len - (s_len >> 3), 64);
	}
	return (MUNIT_OK);
}

static const MunitTest zle_tests[] = {
	UNIT_TEST("random",		test_zle_random),
	UNIT_TEST("boundaries",		test_zle_boundaries),
	UNIT_TEST("block_sizes",	test_zle_block_sizes),
	{ 0 },
};

static const MunitSuite zle_test_suite = {
	"zle.",
	zle_tests,
	NULL,
	1,
	MUNIT_SUITE_OPTION_NONE,
};

int
main(int argc, char **argv)
{
	return (munit_suite_main(&zle_test_suite, NULL, argc, argv));
}
