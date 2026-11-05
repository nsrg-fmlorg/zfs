/*
 * mmapflip <device> <seconds>: keep changing a shared mapping of the
 * device while msync() writes it back, so bios carry pages that change
 * under them.  Each page ends with a known final content.
 */
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define	LEN	(64UL << 20)
static volatile int stop;
static uint8_t *m;

static void *
flip(void *arg)
{
	uint64_t x = 88172645463325252ULL;

	(void) arg;
	while (!stop) {
		x ^= x << 13; x ^= x >> 7; x ^= x << 17;
		m[x % LEN]++;
	}
	return (NULL);
}

int
main(int argc, char **argv)
{
	pthread_t t;
	int fd = open(argv[1], O_RDWR);
	time_t end = time(NULL) + atoi(argv[2]);
	long n = 0;

	if (fd < 0 || argc < 3) {
		perror("open");
		return (1);
	}
	m = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED) {
		perror("mmap");
		return (1);
	}
	memset(m, 0xa5, LEN);
	pthread_create(&t, NULL, flip, NULL);
	while (time(NULL) < end) {
		if (msync(m, LEN, MS_SYNC) != 0)
			perror("msync");
		n++;
	}
	stop = 1;
	pthread_join(t, NULL);
	msync(m, LEN, MS_SYNC);
	printf("msyncs %ld\n", n);
	return (0);
}
