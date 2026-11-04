#define	_GNU_SOURCE
/*
 * tailw <path> <blocksize> <direct> <seconds>: write blocks that are zero
 * but for the last byte, the worst case for the zero check, and print the
 * counters in the shape of fio's JSON.  With seconds 0, fill 1G once.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define	SIZE	(1024ULL * 1024 * 1024)
#define	MAXLAT	(1 << 24)

static uint64_t
now(void)
{
	struct timespec ts;

	(void) clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec * 1000000000ULL + ts.tv_nsec);
}

static int
cmp(const void *a, const void *b)
{
	uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;

	return (x < y ? -1 : x > y);
}

int
main(int argc, char **argv)
{
	size_t bs;
	int fd, direct, secs;
	char *buf;
	uint32_t *lat;
	uint64_t off = 0, n = 0, t0, end, t;

	if (argc != 5)
		return (2);
	bs = strtoul(argv[2], NULL, 0);
	direct = atoi(argv[3]);
	secs = atoi(argv[4]);
	fd = open(argv[1], O_WRONLY | O_CREAT | (direct ? O_DIRECT : 0), 0644);
	if (fd < 0 || posix_memalign((void **)&buf, 1 << 20, bs) != 0)
		return (1);
	lat = malloc(MAXLAT * sizeof (*lat));
	if (lat == NULL)
		return (1);
	memset(buf, 0, bs);
	t0 = now();
	end = t0 + secs * 1000000000ULL;
	for (;;) {
		t = now();
		if (secs == 0 ? off >= SIZE : t >= end)
			break;
		/* Never 0, and different from one pass to the next. */
		buf[bs - 1] = (char)(n % 255 + 1);
		if (off >= SIZE)
			off = 0;
		if (pwrite(fd, buf, bs, off) != (ssize_t)bs)
			return (1);
		if (n < MAXLAT)
			lat[n] = (uint32_t)(now() - t);
		off += bs;
		n++;
	}
	t = (now() - t0) / 1000000;
	uint64_t m = n < MAXLAT ? n : MAXLAT;
	qsort(lat, m, sizeof (*lat), cmp);
	(void) close(fd);
	(void) printf("{\"jobs\":[{\"write\":{\"iops\":%.1f,\"bw_bytes\":%.0f,"
	    "\"runtime\":%llu,\"total_ios\":%llu,\"clat_ns\":{\"percentile\":"
	    "{\"50.000000\":%u,\"99.000000\":%u}}}}]}\n",
	    t ? n * 1000.0 / t : 0, t ? n * bs * 1000.0 / t : 0,
	    (unsigned long long)t, (unsigned long long)n,
	    m ? lat[m / 2] : 0, m ? lat[m * 99 / 100] : 0);
	return (0);
}
