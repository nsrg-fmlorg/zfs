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
 * Copyright (c) 2024, Klara, Inc.
 */

#include <sys/zio_compress.h>
#include <sys/types.h>

/*
 * Slack compression simply searches for the last non-zero byte in the buffer,
 * and sets the position as the size of the "compressed" data.
 */

static size_t
zfs_slack_compress_buf(void *src, void *dst, size_t s_len, size_t d_len,
    int level)
{
	(void) level;

	ASSERT3U(s_len, >, 0);
	ASSERT0(P2PHASE(s_len, sizeof (uint64_t)));

	const uint64_t *buf = src;

	size_t n = s_len / sizeof (uint64_t);
	while (n > 0 && buf[n - 1] == 0)
		n--;

	if (n == 0)
		return (s_len);

	size_t c_len = n * sizeof (uint64_t);
	if (c_len > d_len)
		return (s_len);

	memcpy(dst, src, c_len);
	return (c_len);
}

static int
zfs_slack_decompress_buf(void *src, void *dst, size_t s_len, size_t d_len,
    int level)
{
	(void) level;

	/*
	 * A physical size larger than the logical one can only come from a
	 * damaged block pointer.  Refuse it as zle does; an ASSERT would let
	 * a non-debug build copy past the end of dst.
	 */
	if (s_len > d_len)
		return (-1);

	memcpy(dst, src, s_len);
	memset((uchar_t *)dst + s_len, 0, d_len - s_len);
	return (0);
}

ZFS_COMPRESS_WRAP_DECL(zfs_slack_compress)
ZFS_DECOMPRESS_WRAP_DECL(zfs_slack_decompress)
