/*
 * zrawdisk: a memory-backed disk that is a bare cdev with d_strategy and
 * no GEOM provider, the kind of device file vdevs on FreeBSD can now be
 * created on.  CI fixture only.
 *
 * It is strict where real drivers are lenient or silently wrong, so the
 * tests can see what a caller got wrong:
 *
 *	bio_bcount != bio_length	EINVAL	(nvme sizes BIO_DELETE by
 *						bio_bcount)
 *	bio_bcount > si_iosize_max	EINVAL	(nvme does not split by its
 *						maximum transfer size)
 *	BIO_UNMAPPED			EINVAL	(SI_UNMAPPED is not set)
 *
 * With debug.zrawdisk.lenient set, the first two are counted but served,
 * as a real driver would (a zero-length BIO_DELETE deletes nothing), so a
 * caller with every one of these bugs can still be measured.
 *
 * debug.zrawdisk.* holds counters for each, knobs to fail every bio with
 * ENXIO or DIOCGSECTORSIZE with ENOTTY, and "destroy" to remove the cdev
 * as a detaching driver would.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bio.h>
#include <sys/conf.h>
#include <sys/disk.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/module.h>
#include <sys/sysctl.h>
#include <sys/taskqueue.h>

static MALLOC_DEFINE(M_ZRAWDISK, "zrawdisk", "zrawdisk backing store");

#define	ZRD_SIZE	(512ULL << 20)
#define	ZRD_SECTOR	512
#define	ZRD_STRIPE	4096

static struct cdev *zrd_dev;
static char *zrd_data;
static int zrd_maxio = 64 * 1024;
static int zrd_lenient;
static int zrd_fail_enxio;
static int zrd_fail_sectorsize;
static int zrd_destroy;
static unsigned long zrd_reads, zrd_writes, zrd_deletes, zrd_delete_bytes;
static unsigned long zrd_flushes, zrd_bad_bcount, zrd_oversize, zrd_unmapped;

static SYSCTL_NODE(_debug, OID_AUTO, zrawdisk, CTLFLAG_RW | CTLFLAG_MPSAFE,
	    0, "zrawdisk test fixture");
SYSCTL_INT(_debug_zrawdisk, OID_AUTO, lenient, CTLFLAG_RW,
	    &zrd_lenient, 0, "Count, but serve, bad lengths and sizes");
SYSCTL_INT(_debug_zrawdisk, OID_AUTO, fail_enxio, CTLFLAG_RW,
	    &zrd_fail_enxio, 0, "Fail every bio with ENXIO");
SYSCTL_INT(_debug_zrawdisk, OID_AUTO, fail_sectorsize, CTLFLAG_RW,
	    &zrd_fail_sectorsize, 0, "Fail DIOCGSECTORSIZE with ENOTTY");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, reads, CTLFLAG_RD, &zrd_reads, 0, "");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, writes, CTLFLAG_RD, &zrd_writes, 0,
	    "");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, deletes, CTLFLAG_RD, &zrd_deletes, 0,
	    "");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, delete_bytes, CTLFLAG_RD,
	    &zrd_delete_bytes, 0, "");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, flushes, CTLFLAG_RD, &zrd_flushes, 0,
	    "");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, bad_bcount, CTLFLAG_RD,
	    &zrd_bad_bcount, 0, "bios refused for bio_bcount != bio_length");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, oversize, CTLFLAG_RD, &zrd_oversize,
	    0, "bios refused for exceeding si_iosize_max");
SYSCTL_ULONG(_debug_zrawdisk, OID_AUTO, unmapped, CTLFLAG_RD, &zrd_unmapped,
	    0, "bios refused for being unmapped");

static void
zrd_strategy(struct bio *bp)
{
	int error = 0;

	if (bp->bio_bcount != bp->bio_length) {
		atomic_add_long(&zrd_bad_bcount, 1);
		if (!zrd_lenient)
			error = EINVAL;
	}
	if (error == 0 && bp->bio_bcount > zrd_maxio &&
	    (bp->bio_cmd == BIO_READ || bp->bio_cmd == BIO_WRITE)) {
		atomic_add_long(&zrd_oversize, 1);
		if (!zrd_lenient)
			error = EINVAL;
	}
	if (error == 0 && (bp->bio_flags & BIO_UNMAPPED) != 0) {
		/* bio_data is unmapped_buf: there is nothing to copy. */
		atomic_add_long(&zrd_unmapped, 1);
		error = EINVAL;
	}
	if (error == 0 && (bp->bio_offset < 0 ||
	    (uint64_t)bp->bio_offset + bp->bio_bcount > ZRD_SIZE))
		error = EIO;
	if (zrd_fail_enxio)
		error = ENXIO;

	if (error == 0) {
		switch (bp->bio_cmd) {
		case BIO_READ:
			memcpy(bp->bio_data, zrd_data + bp->bio_offset,
			    bp->bio_bcount);
			atomic_add_long(&zrd_reads, 1);
			break;
		case BIO_WRITE:
			memcpy(zrd_data + bp->bio_offset, bp->bio_data,
			    bp->bio_bcount);
			atomic_add_long(&zrd_writes, 1);
			break;
		case BIO_DELETE:
			memset(zrd_data + bp->bio_offset, 0, bp->bio_bcount);
			atomic_add_long(&zrd_deletes, 1);
			atomic_add_long(&zrd_delete_bytes, bp->bio_bcount);
			break;
		case BIO_FLUSH:
			atomic_add_long(&zrd_flushes, 1);
			break;
		default:
			error = EOPNOTSUPP;
			break;
		}
	}

	if (error != 0) {
		bp->bio_error = error;
		bp->bio_flags |= BIO_ERROR;
		bp->bio_resid = bp->bio_bcount;
	} else {
		bp->bio_resid = 0;
	}
	biodone(bp);
}

static int
zrd_ioctl(struct cdev *dev, unsigned long cmd, caddr_t data, int fflag,
    struct thread *td)
{
	switch (cmd) {
	case DIOCGMEDIASIZE:
		*(off_t *)data = ZRD_SIZE;
		return (0);
	case DIOCGSECTORSIZE:
		if (zrd_fail_sectorsize)
			return (ENOTTY);
		*(unsigned int *)data = ZRD_SECTOR;
		return (0);
	case DIOCGSTRIPESIZE:
		*(off_t *)data = ZRD_STRIPE;
		return (0);
	case DIOCGSTRIPEOFFSET:
		*(off_t *)data = 0;
		return (0);
	default:
		return (ENOTTY);
	}
}

static struct cdevsw zrd_cdevsw = {
	.d_version =	D_VERSION,
	.d_flags =	D_DISK,
	.d_name =	"zrawdisk",
	.d_strategy =	zrd_strategy,
	.d_read =	physread,
	.d_write =	physwrite,
	.d_ioctl =	zrd_ioctl,
};

/* destroy_dev() waits for threads in the driver; run it off the sysctl. */
static void
zrd_destroy_task(void *arg, int pending)
{
	if (zrd_dev != NULL) {
		destroy_dev(zrd_dev);
		zrd_dev = NULL;
	}
}

static struct task zrd_task;

static int
zrd_sysctl_destroy(SYSCTL_HANDLER_ARGS)
{
	int error = sysctl_handle_int(oidp, &zrd_destroy, 0, req);

	if (error == 0 && req->newptr != NULL && zrd_destroy != 0)
		taskqueue_enqueue(taskqueue_thread, &zrd_task);
	return (error);
}
SYSCTL_PROC(_debug_zrawdisk, OID_AUTO, destroy,
	    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0,
	    zrd_sysctl_destroy, "I", "Destroy the cdev, as on detach");

static int
zrd_modevent(module_t mod, int type, void *arg)
{
	switch (type) {
	case MOD_LOAD:
		zrd_data = malloc(ZRD_SIZE, M_ZRAWDISK, M_WAITOK | M_ZERO);
		TASK_INIT(&zrd_task, 0, zrd_destroy_task, NULL);
		zrd_dev = make_dev(&zrd_cdevsw, 0, UID_ROOT, GID_OPERATOR, 0640,
		    "zrawdisk");
		zrd_dev->si_iosize_max = zrd_maxio;
		return (0);
	case MOD_UNLOAD:
		taskqueue_drain(taskqueue_thread, &zrd_task);
		if (zrd_dev != NULL)
			destroy_dev(zrd_dev);
		free(zrd_data, M_ZRAWDISK);
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

DEV_MODULE(zrawdisk, zrd_modevent, NULL);
