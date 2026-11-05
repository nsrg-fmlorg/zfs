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
 * Copyright 2009 Sun Microsystems, Inc.  All rights reserved.
 * Use is subject to license terms.
 */

/*
 * Zero-length encoding.  This is a fast and simple algorithm to eliminate
 * runs of zeroes.  Each chunk of compressed data begins with a length byte, b.
 * If b < n (where n is the compression parameter) then the next b + 1 bytes
 * are literal values.  If b >= n then the next (256 - b + 1) bytes are zero.
 */
#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/zfs_context.h>
#include <sys/zio_compress.h>

#define	ZLE_ONES	0x0101010101010101ULL
#define	ZLE_HIGHS	0x8080808080808080ULL
#define	ZLE_NOFIT	((size_t)-1)

static inline uint64_t
zle_load64(const uchar_t *p)
{
	uint64_t w;

	/* The buffer of a borrowed ABD has no particular alignment. */
	memcpy(&w, p, sizeof (w));
	return (w);
}

/*
 * Encode src into dst, or with dst NULL only work out what would be written.
 * Returns the encoded length, or ZLE_NOFIT if the input does not fit.
 *
 * Which blocks fit, and the bytes they encode to, have to stay as they have
 * always been: rewriting a block must give the same bytes and so the same
 * checksum, or nopwrite and dedup stop matching blocks from older software.
 * So two limits of the original loop are kept although they are not the
 * tightest possible.  A chunk starts only with at least two bytes of room,
 * and a literal chunk needs n bytes of room however short it turns out.
 *
 * A literal chunk is at most n bytes and ends before two adjacent zeroes.  A
 * single zero stays inside it, as it costs less there than a chunk of its
 * own.  A zero chunk is at most 256 - n bytes.  Whole words are skipped where
 * possible; the test for a zero byte may be true of a word only if it holds
 * one, so a word it passes cannot hold the start of a pair, in either byte
 * order.
 */
static size_t
zle_encode(const uchar_t *src, uchar_t *dst, size_t s_len, size_t d_len, int n)
{
	const uchar_t *s_end = src + s_len;
	size_t d_off = 0;

	while (src < s_end && d_off + 1 < d_len) {
		const uchar_t *first = src;
		const uchar_t *last;
		size_t len = d_off++;

		if (src[0] == 0) {
			last = src + MIN((size_t)(256 - n),
			    (size_t)(s_end - src));
			while ((size_t)(last - src) >= sizeof (uint64_t) &&
			    zle_load64(src) == 0)
				src += sizeof (uint64_t);
			while (src < last && src[0] == 0)
				src++;
			if (dst != NULL)
				dst[len] = (uchar_t)(src - first - 1 + n);
		} else {
			if (d_len - d_off < (size_t)n)
				return (ZLE_NOFIT);
			last = src + MIN((size_t)n, (size_t)(s_end - src));
			while (last - src > 1) {
				if ((size_t)(last - src) >= sizeof (uint64_t)) {
					uint64_t w = zle_load64(src);

					if (((w - ZLE_ONES) & ~w &
					    ZLE_HIGHS) == 0) {
						src += sizeof (uint64_t);
						continue;
					}
				}
				if ((src[0] | src[1]) == 0)
					break;
				src++;
			}
			if (src < last && src[0] != 0)
				src++;
			if (dst != NULL) {
				dst[len] = (uchar_t)(src - first - 1);
				memcpy(dst + d_off, first, src - first);
			}
			d_off += src - first;
		}
	}
	return (src == s_end ? d_off : ZLE_NOFIT);
}

static int
zfs_zle_decompress_buf(void *s_start, void *d_start, size_t s_len,
    size_t d_len, int n)
{
	uchar_t *src = s_start;
	uchar_t *dst = d_start;
	uchar_t *s_end = src + s_len;
	uchar_t *d_end = dst + d_len;

	while (src < s_end && dst < d_end) {
		int len = 1 + *src++;
		if (len <= n) {
			if (src + len > s_end || dst + len > d_end)
				return (-1);
			while (len-- != 0)
				*dst++ = *src++;
		} else {
			len -= n;
			if (dst + len > d_end)
				return (-1);
			while (len-- != 0)
				*dst++ = 0;
		}
	}
	return (dst == d_end ? 0 : -1);
}

/*
 * Most of what zle sees and cannot shrink is given up on here, before the
 * destination is touched: returning a borrowed buffer copies it back.
 */
size_t
zfs_zle_compress(abd_t *src, abd_t *dst, size_t s_len, size_t d_len, int n)
{
	void *s_buf = abd_borrow_buf_copy(src, s_len);
	size_t c_len = zle_encode(s_buf, NULL, s_len, d_len, n);

	if (c_len == ZLE_NOFIT) {
		c_len = s_len;
	} else {
		void *d_buf = abd_borrow_buf(dst, d_len);

		c_len = zle_encode(s_buf, d_buf, s_len, d_len, n);
		abd_return_buf_copy(dst, d_buf, d_len);
	}
	abd_return_buf(src, s_buf, s_len);
	return (c_len);
}

ZFS_DECOMPRESS_WRAP_DECL(zfs_zle_decompress)
