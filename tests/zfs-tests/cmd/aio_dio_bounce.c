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

/*
 * Write a file with asynchronous O_DIRECT writes from one handle while
 * another thread changes the write buffer, as manipulate_user_buffer -w
 * does with pwrite().  Each write is submitted with io_submit() and
 * waited for before the next, so the requests take the async Direct I/O
 * path one at a time and in order.
 *
 * usage: aio_dio_bounce <file> <blocksize> <numblocks>
 * exit:  0 = every write returned its full length
 *        2 = a write failed or came back short, or usage or setup error
 */

#include <errno.h>
#include <fcntl.h>
#include <libaio.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Wait this long for a completion before calling the write failed. */
#define	WAIT_SECONDS	60

static unsigned char *buf;
static size_t blocksize;
static volatile int done;

static void *
mutate_thread(void *arg)
{
	(void) arg;
	unsigned int seed = 1;

	while (!done) {
		buf[(size_t)rand_r(&seed) % blocksize] =
		    (unsigned char)(rand_r(&seed) % (126 - 33) + 33);
	}
	return (NULL);
}

int
main(int argc, char *argv[])
{
	struct timespec ts = { WAIT_SECONDS, 0 };
	io_context_t ctx = 0;
	struct io_event ev;
	struct iocb cb;
	struct iocb *cbp = &cb;
	pthread_t thr;
	long nblocks;
	int fd, rc, status = 0;

	if (argc != 4) {
		(void) fprintf(stderr,
		    "usage: %s <file> <blocksize> <numblocks>\n", argv[0]);
		return (2);
	}
	blocksize = strtoul(argv[2], NULL, 0);
	nblocks = strtol(argv[3], NULL, 0);
	if (blocksize == 0 || nblocks <= 0) {
		(void) fprintf(stderr, "%s: bad blocksize or numblocks\n",
		    argv[0]);
		return (2);
	}

	fd = open(argv[1], O_WRONLY | O_CREAT | O_DIRECT, S_IRUSR | S_IWUSR);
	if (fd == -1) {
		(void) fprintf(stderr, "%s: %s: %s\n", argv[0], argv[1],
		    strerror(errno));
		return (2);
	}
	rc = posix_memalign((void **)&buf, (size_t)sysconf(_SC_PAGE_SIZE),
	    blocksize);
	if (rc != 0) {
		(void) fprintf(stderr, "%s: %s\n", argv[0], strerror(rc));
		return (2);
	}
	(void) memset(buf, 0xa5, blocksize);

	rc = io_setup(1, &ctx);
	if (rc != 0) {
		(void) fprintf(stderr, "%s: io_setup: %s\n", argv[0],
		    strerror(-rc));
		return (2);
	}
	rc = pthread_create(&thr, NULL, mutate_thread, NULL);
	if (rc != 0) {
		(void) fprintf(stderr, "%s: pthread_create: %s\n", argv[0],
		    strerror(rc));
		return (2);
	}

	for (long i = 0; i < nblocks && status == 0; i++) {
		io_prep_pwrite(&cb, fd, buf, blocksize,
		    (long long)i * (long long)blocksize);
		if (io_submit(ctx, 1, &cbp) != 1) {
			(void) fprintf(stderr, "write %ld: io_submit failed\n",
			    i);
			status = 2;
			break;
		}
		rc = io_getevents(ctx, 1, 1, &ev, &ts);
		if (rc != 1) {
			/*
			 * The request may still be in flight and own buf, so
			 * stop here rather than reuse it.
			 */
			(void) fprintf(stderr, "write %ld: no completion\n", i);
			_exit(2);
		}
		if (ev.res != blocksize) {
			(void) fprintf(stderr, "write %ld: returned %ld\n", i,
			    (long)ev.res);
			status = 2;
		}
	}

	done = 1;
	(void) pthread_join(thr, NULL);
	(void) io_destroy(ctx);
	(void) close(fd);
	free(buf);
	return (status);
}
