// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright (c) 2020 iXsystems, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 */

#include <sys/dmu.h>
#include <sys/dmu_impl.h>
#include <sys/dmu_recv.h>
#include <sys/dmu_tx.h>
#include <sys/dbuf.h>
#include <sys/dnode.h>
#include <sys/zfs_context.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_traverse.h>
#include <sys/dsl_dataset.h>
#include <sys/dsl_dir.h>
#include <sys/dsl_pool.h>
#include <sys/dsl_synctask.h>
#include <sys/abd.h>
#include <sys/vdev_impl.h>
#include <sys/zfs_ioctl.h>
#include <sys/zap.h>
#include <sys/zio_checksum.h>
#include <sys/zfs_znode.h>
#include <sys/zfs_file.h>
#include <sys/bio.h>
#include <sys/buf.h>
#include <sys/disk.h>
#include <sys/file.h>
#include <sys/conf.h>
#include <geom/geom.h>
#include <vm/vm_page.h>
#include <sys/stat.h>

SYSCTL_DECL(_vfs_zfs_vdev);
/* Don't send BIO_FLUSH. */
static int zfs_file_bio_flush_disable;
SYSCTL_INT(_vfs_zfs_vdev, OID_AUTO, file_bio_flush_disable, CTLFLAG_RWTUN,
	&zfs_file_bio_flush_disable, 0, "Disable vdev_file BIO_FLUSH");
/* Don't send BIO_DELETE. */
static int zfs_file_bio_delete_disable;
SYSCTL_INT(_vfs_zfs_vdev, OID_AUTO, file_bio_delete_disable, CTLFLAG_RWTUN,
	&zfs_file_bio_delete_disable, 0, "Disable vdev_file BIO_DELETE");

int
zfs_file_open(const char *path, int flags, int mode, cred_t *cr,
    zfs_file_t **zfpp)
{
	struct thread *td;
	struct vnode *vp;
	struct file *fp;
	struct nameidata nd;
	boolean_t creating = (flags & O_CREAT) != 0;
	int error;

	td = curthread;
	pwd_ensure_dirs();

	KASSERT((flags & (O_EXEC | O_PATH)) == 0,
	    ("invalid flags: 0x%x", flags));
	KASSERT((flags & O_ACCMODE) != O_ACCMODE,
	    ("invalid flags: 0x%x", flags));
	flags = FFLAGS(flags);

	error = falloc_noinstall(td, &fp);
	if (error != 0) {
		return (error);
	}
	fp->f_flag = flags & FMASK;

#if __FreeBSD_version >= 1400043
	NDINIT(&nd, LOOKUP, FOLLOW, UIO_SYSSPACE, path);
#else
	NDINIT(&nd, LOOKUP, FOLLOW, UIO_SYSSPACE, path, td);
#endif
	error = vn_open_cred(&nd, &flags, mode, 0, cr, fp);
	if (error != 0) {
		falloc_abort(td, fp);
		return (SET_ERROR(error));
	}
	NDFREE_PNBUF(&nd);
	vp = nd.ni_vp;
	fp->f_vnode = vp;
	if (fp->f_ops == &badfileops) {
		finit_vnode(fp, flags, NULL, &vnops);
	}
	VOP_UNLOCK(vp);
	/*
	 * A character device is accepted for a file vdev on a device with
	 * no GEOM provider.  Nothing creates or truncates one: the cache
	 * file is written with O_CREAT, and must not land on a device.
	 */
	if (vp->v_type != VREG && (vp->v_type != VCHR || creating)) {
		zfs_file_close(fp);
		return (SET_ERROR(EACCES));
	}

	if (vp->v_type == VREG && flags & O_TRUNC) {
		error = fo_truncate(fp, 0, cr, td);
		if (error != 0) {
			zfs_file_close(fp);
			return (SET_ERROR(error));
		}
	}

	*zfpp = fp;

	return (0);
}

void
zfs_file_close(zfs_file_t *zfp)
{
	struct file *fp = zfp;
	fdrop(fp, curthread);
}

static int
zfs_file_write_impl(struct file *fp, const void *buf, size_t count,
    loff_t *offp, ssize_t *resid)
{
	ssize_t rc;
	struct uio auio;
	struct thread *td;
	struct iovec aiov;

	td = curthread;
	aiov.iov_base = (void *)(uintptr_t)buf;
	aiov.iov_len = count;
	auio.uio_iov = &aiov;
	auio.uio_iovcnt = 1;
	auio.uio_segflg = UIO_SYSSPACE;
	auio.uio_resid = count;
	auio.uio_rw = UIO_WRITE;
	auio.uio_td = td;
	auio.uio_offset = *offp;

	if ((fp->f_flag & FWRITE) == 0)
		return (SET_ERROR(EBADF));

	if (fp->f_type == DTYPE_VNODE)
		bwillwrite();

	rc = fo_write(fp, &auio, td->td_ucred, FOF_OFFSET, td);
	if (rc)
		return (SET_ERROR(rc));
	if (resid)
		*resid = auio.uio_resid;
	else if (auio.uio_resid)
		return (SET_ERROR(EIO));
	*offp += count - auio.uio_resid;
	return (rc);
}

int
zfs_file_write(zfs_file_t *zfp, const void *buf, size_t count, ssize_t *resid)
{
	struct file *fp = zfp;
	loff_t off = fp->f_offset;
	ssize_t rc;

	rc = zfs_file_write_impl(fp, buf, count, &off, resid);
	if (rc == 0)
		fp->f_offset = off;

	return (SET_ERROR(rc));
}

int
zfs_file_pwrite(zfs_file_t *zfp, const void *buf, size_t count, loff_t off,
    uint8_t ashift, ssize_t *resid)
{
	(void) ashift;
	return (zfs_file_write_impl(zfp, buf, count, &off, resid));
}

static int
zfs_file_read_impl(struct file *fp, void *buf, size_t count, loff_t *offp,
    ssize_t *resid)
{
	ssize_t rc;
	struct uio auio;
	struct thread *td;
	struct iovec aiov;

	td = curthread;
	aiov.iov_base = (void *)(uintptr_t)buf;
	aiov.iov_len = count;
	auio.uio_iov = &aiov;
	auio.uio_iovcnt = 1;
	auio.uio_segflg = UIO_SYSSPACE;
	auio.uio_resid = count;
	auio.uio_rw = UIO_READ;
	auio.uio_td = td;
	auio.uio_offset = *offp;

	if ((fp->f_flag & FREAD) == 0)
		return (SET_ERROR(EBADF));

	rc = fo_read(fp, &auio, td->td_ucred, FOF_OFFSET, td);
	if (rc)
		return (SET_ERROR(rc));
	if (resid)
		*resid = auio.uio_resid;
	*offp += count - auio.uio_resid;
	return (SET_ERROR(0));
}

int
zfs_file_read(zfs_file_t *zfp, void *buf, size_t count, ssize_t *resid)
{
	struct file *fp = zfp;
	loff_t off = fp->f_offset;
	ssize_t rc;

	rc = zfs_file_read_impl(fp, buf, count, &off, resid);
	if (rc == 0)
		fp->f_offset = off;
	return (rc);
}

int
zfs_file_pread(zfs_file_t *zfp, void *buf, size_t count, loff_t off,
    ssize_t *resid)
{
	return (zfs_file_read_impl(zfp, buf, count, &off, resid));
}

int
zfs_file_seek(zfs_file_t *zfp, loff_t *offp, int whence)
{
	struct file *fp = zfp;
	int rc;
	struct thread *td;

	td = curthread;
	if ((fp->f_ops->fo_flags & DFLAG_SEEKABLE) == 0)
		return (SET_ERROR(ESPIPE));
	rc = fo_seek(fp, *offp, whence, td);
	if (rc == 0)
		*offp = td->td_uretoff.tdu_off;
	return (SET_ERROR(rc));
}

/*
 * I/O to a device node with no GEOM provider, for vdev_file.
 *
 * GEOM's g_disk normally sits between ZFS and the driver.  Calling the
 * driver's d_strategy directly means doing here what g_disk would:
 * setting bio_bcount, which drivers read for the transfer length
 * (nvme_ns_bio_process() sizes BIO_DELETE from it); splitting reads and
 * writes at si_iosize_max, which d_strategy does not do for us (nvme
 * splits only at the namespace boundary); and sending unmapped bios only
 * to a device that sets SI_UNMAPPED, as physio() checks.
 *
 * One zio becomes one or more bios sharing a zfs_file_io_t, which
 * zio->io_bio points at until vdev_file_io_done() releases the buffer.
 */
typedef struct zfs_file_io {
	zio_t		*zfi_zio;
	void		*zfi_data;	/* borrowed linear buffer or NULL */
	vm_page_t	*zfi_ma;	/* unmapped pages, or NULL */
	int		zfi_ma_n;
	uint_t		zfi_pending;	/* bios still outstanding */
	uint_t		zfi_error;	/* first error seen */
} zfs_file_io_t;

/*
 * Callback to translate the ABD segment into array of physical pages.
 */
static int
zfs_file_fill_unmap_cb(void *buf, size_t len, void *priv)
{
	struct bio *bp = priv;
	vm_offset_t addr = (vm_offset_t)buf;
	vm_offset_t end = addr + len;

	if (bp->bio_ma_n == 0) {
		bp->bio_ma_offset = addr & PAGE_MASK;
		addr &= ~PAGE_MASK;
	} else {
		ASSERT0(P2PHASE(addr, PAGE_SIZE));
	}
	do {
		bp->bio_ma[bp->bio_ma_n++] =
		    PHYS_TO_VM_PAGE(pmap_kextract(addr));
		addr += PAGE_SIZE;
	} while (addr < end);
	return (0);
}

struct zfs_file_check_unmapped_cb_state {
	int	pages;
	uint_t	end;
};

/*
 * Callback to check the ABD segment size/alignment and count the pages.
 */
static int
zfs_file_check_unmapped_cb(void *buf, size_t len, void *priv)
{
	struct zfs_file_check_unmapped_cb_state *s = priv;
	vm_offset_t off = (vm_offset_t)buf & PAGE_MASK;

	if (s->pages != 0 && off != 0)
		return (1);
	if (s->end != 0)
		return (1);
	s->end = (off + len) & PAGE_MASK;
	s->pages += (off + len + PAGE_MASK) >> PAGE_SHIFT;
	return (0);
}

/*
 * Return the number of pages to describe the zio's buffer as an unmapped
 * bio, or 0 to use a linear buffer.  As in vdev_geom_check_unmapped(),
 * plus the device's own consent.
 */
static int
zfs_file_check_unmapped(zio_t *zio, struct cdev *dev)
{
	struct zfs_file_check_unmapped_cb_state s;

	if (!unmapped_buf_allowed || (dev->si_flags & SI_UNMAPPED) == 0)
		return (0);

	if (abd_is_linear(zio->io_abd))
		return (0);

	s.pages = s.end = 0;
	if (abd_iterate_func(zio->io_abd, 0, zio->io_size,
	    zfs_file_check_unmapped_cb, &s))
		return (0);
	return (s.pages);
}

static void
zfs_file_io_free(zfs_file_io_t *zfi)
{
	if (zfi->zfi_ma != NULL)
		free(zfi->zfi_ma, M_DEVBUF);
	kmem_free(zfi, sizeof (*zfi));
}

static void
zfs_file_io_intr(struct bio *bp)
{
	zfs_file_io_t *zfi = bp->bio_caller1;
	zio_t *zio = zfi->zfi_zio;
	uint_t error = (uint_t)bp->bio_error;

	if (error == 0 && bp->bio_resid != 0)
		error = SET_ERROR(EIO);
	if (error != 0)
		(void) atomic_cmpset_int(&zfi->zfi_error, 0, error);
	g_destroy_bio(bp);

	if (atomic_fetchadd_int(&zfi->zfi_pending, -1) != 1)
		return;

	zio->io_error = (int)zfi->zfi_error;

	/*
	 * There is no GEOM orphan event to tell a vanished device from a
	 * failed request (vdev_geom checks the provider's error, which a
	 * bio sent straight to d_strategy does not have: bio_to is NULL).
	 * Close and reopen later; zfs_file_io_strategy() asks for removal
	 * once the cdev itself is gone.
	 */
	if (zio->io_error == ENXIO && !zio->io_vd->vdev_remove_wanted)
		zio->io_vd->vdev_delayed_close = B_TRUE;

	/*
	 * vdev_op_io_done is not called for ZIO_TYPE_FLUSH, and the ABD code
	 * cannot be called in this context, so a read or write keeps its
	 * buffer until zfs_file_io_strategy_done().
	 */
	if (zio->io_type != ZIO_TYPE_READ && zio->io_type != ZIO_TYPE_WRITE) {
		zio->io_bio = NULL;
		zfs_file_io_free(zfi);
	}
	zio_delay_interrupt(zio);
}

static struct bio *
zfs_file_bio(zfs_file_io_t *zfi, struct cdev *dev, uint_t cmd, off_t offset,
    off_t length)
{
	struct bio *bp = g_alloc_bio();

	bp->bio_cmd = cmd;
	bp->bio_dev = dev;
	bp->bio_offset = offset;
	bp->bio_length = bp->bio_bcount = length;
	bp->bio_caller1 = zfi;
	bp->bio_done = zfs_file_io_intr;
	return (bp);
}

void
zfs_file_io_strategy(zfs_file_t *zfp, void *arg)
{
	struct file *fp = zfp;
	zio_t *zio = arg;
	vdev_t *vd = zio->io_vd;
	struct cdevsw *csw;
	struct cdev *dev;
	int ref;

	ASSERT(zio->io_type == ZIO_TYPE_READ ||
	    zio->io_type == ZIO_TYPE_WRITE ||
	    zio->io_type == ZIO_TYPE_TRIM ||
	    zio->io_type == ZIO_TYPE_FLUSH);

	if ((zio->io_type == ZIO_TYPE_FLUSH && zfs_file_bio_flush_disable) ||
	    (zio->io_type == ZIO_TYPE_TRIM && zfs_file_bio_delete_disable)) {
		zio_execute(zio);
		return;
	}
	if (zio->io_type == ZIO_TYPE_FLUSH && vd->vdev_nowritecache) {
		zio->io_error = SET_ERROR(ENOTSUP);
		zio_execute(zio);
		return;
	}

	csw = devvn_refthread(fp->f_vnode, &dev, &ref);
	if (csw == NULL) {
		/* The cdev has been destroyed: the device is gone. */
		if (!vd->vdev_remove_wanted) {
			vd->vdev_remove_wanted = B_TRUE;
			spa_async_request(zio->io_spa, SPA_ASYNC_REMOVE);
		}
		zio->io_error = SET_ERROR(ENXIO);
		zio_interrupt(zio);
		return;
	}

	zfs_file_io_t *zfi = kmem_zalloc(sizeof (*zfi), KM_SLEEP);
	zfi->zfi_zio = zio;
	zio->io_bio = zfi;

	if (zio->io_type == ZIO_TYPE_TRIM || zio->io_type == ZIO_TYPE_FLUSH) {
		struct bio *bp = (zio->io_type == ZIO_TYPE_TRIM) ?
		    zfs_file_bio(zfi, dev, BIO_DELETE, zio->io_offset,
		    zio->io_size) :
		    zfs_file_bio(zfi, dev, BIO_FLUSH, vd->vdev_asize, 0);
		zfi->zfi_pending = 1;
		csw->d_strategy(bp);
		dev_relthread(dev, ref);
		return;
	}

	uint_t cmd = (zio->io_type == ZIO_TYPE_READ) ? BIO_READ : BIO_WRITE;
	/*
	 * physio() falls back to DFLTPHYS for a driver that leaves
	 * si_iosize_max unset.  Pieces are whole sectors of the vdev.
	 */
	off_t maxio = (dev->si_iosize_max >= PAGE_SIZE) ?
	    dev->si_iosize_max : DFLTPHYS;
	maxio = MIN(maxio, (off_t)maxphys);
	maxio = MAX(P2ALIGN_TYPED(maxio, 1LL << vd->vdev_ashift, off_t),
	    1LL << vd->vdev_ashift);
	zio->io_target_timestamp = zio_handle_io_delay(zio);

	/*
	 * Represent a scattered ABD as an array of pages when the device
	 * takes unmapped I/O and one bio carries it.  Splitting a page
	 * array is left to a later change; a split goes through a linear
	 * buffer.
	 */
	int pgs = 0;
	if (zio->io_size <= (uint64_t)maxio)
		pgs = zfs_file_check_unmapped(zio, dev);
	if (pgs > 0) {
		struct bio *bp = zfs_file_bio(zfi, dev, cmd, zio->io_offset,
		    zio->io_size);
		bp->bio_ma = zfi->zfi_ma = malloc(sizeof (vm_page_t) * pgs,
		    M_DEVBUF, M_WAITOK);
		zfi->zfi_ma_n = pgs;
		bp->bio_ma_n = 0;
		bp->bio_ma_offset = 0;
		abd_iterate_func(zio->io_abd, 0, zio->io_size,
		    zfs_file_fill_unmap_cb, bp);
		bp->bio_data = unmapped_buf;
		bp->bio_flags |= BIO_UNMAPPED;
		zfi->zfi_pending = 1;
		csw->d_strategy(bp);
		dev_relthread(dev, ref);
		return;
	}

	zfi->zfi_data = (cmd == BIO_READ) ?
	    abd_borrow_buf(zio->io_abd, zio->io_size) :
	    abd_borrow_buf_copy(zio->io_abd, zio->io_size);

	/*
	 * Count every piece before sending any, so that an early completion
	 * cannot see the count reach zero while pieces remain unsent.
	 */
	uint_t nbios = (uint_t)howmany(zio->io_size, maxio);
	zfi->zfi_pending = nbios;
	for (uint_t i = 0; i < nbios; i++) {
		off_t done = (off_t)i * maxio;
		struct bio *bp = zfs_file_bio(zfi, dev, cmd,
		    (off_t)zio->io_offset + done,
		    MIN(maxio, (off_t)zio->io_size - done));
		bp->bio_data = (char *)zfi->zfi_data + done;
		csw->d_strategy(bp);
	}
	dev_relthread(dev, ref);
}

void
zfs_file_io_strategy_done(zfs_file_t *fp, void *arg)
{
	(void) fp;
	zio_t *zio = arg;
	zfs_file_io_t *zfi = zio->io_bio;

	ASSERT(zio->io_type == ZIO_TYPE_READ || zio->io_type == ZIO_TYPE_WRITE);

	if (zfi->zfi_data != NULL) {
		if (zio->io_type == ZIO_TYPE_READ) {
			abd_return_buf_copy(zio->io_abd, zfi->zfi_data,
			    zio->io_size);
		} else {
			abd_return_buf(zio->io_abd, zfi->zfi_data,
			    zio->io_size);
		}
	}
	zio->io_bio = NULL;
	zfs_file_io_free(zfi);
}

int
zfs_file_getattr(zfs_file_t *zfp, zfs_file_attr_t *zfattr)
{
	struct file *fp = zfp;
	struct thread *td;
	struct stat sb;
	off_t stripesize = 0;
	off_t stripeoffset = 0;
	off_t mediasize;
	uint_t sectorsize;
	int rc;

	td = curthread;

#if __FreeBSD_version < 1400037
	rc = fo_stat(fp, &sb, td->td_ucred, td);
#else
	rc = fo_stat(fp, &sb, td->td_ucred);
#endif
	if (rc)
		return (SET_ERROR(rc));

	zfattr->zfa_size = sb.st_size;
	zfattr->zfa_mode = sb.st_mode;
	zfattr->zfa_logical_block_size = 0;
	zfattr->zfa_physical_block_size = 0;

	if (fp->f_vnode->v_type == VREG)
		return (0);

	rc = fo_ioctl(fp, DIOCGMEDIASIZE, (caddr_t)&mediasize,
	    td->td_ucred, td);
	if (rc) {
		zfs_dbgmsg("zfs file open: cannot get media size");
		return (SET_ERROR(EINVAL));
	}

	zfattr->zfa_size = mediasize;

	rc = fo_ioctl(fp, DIOCGSECTORSIZE, (caddr_t)&sectorsize,
	    td->td_ucred, td);
	if (rc) {
		zfs_dbgmsg("zfs file open: cannot get sector size");
		return (SET_ERROR(EINVAL));
	}

	rc = fo_ioctl(fp, DIOCGSTRIPESIZE, (caddr_t)&stripesize,
	    td->td_ucred, td);
	if (rc)
		zfs_dbgmsg("zfs file open: cannot get stripe size");

	rc = fo_ioctl(fp, DIOCGSTRIPEOFFSET, (caddr_t)&stripeoffset,
	    td->td_ucred, td);
	if (rc)
		zfs_dbgmsg("zfs file open: cannot get stripe offset");

	zfattr->zfa_logical_block_size = MAX(sectorsize, SPA_MINBLOCKSIZE);
	zfattr->zfa_physical_block_size = 0;
	if (stripesize && stripesize > zfattr->zfa_logical_block_size &&
	    ISP2(stripesize) && stripeoffset == 0)
		zfattr->zfa_physical_block_size = stripesize;

	return (0);
}

static __inline int
zfs_vop_fsync(vnode_t *vp)
{
	struct mount *mp;
	int error;

#if __FreeBSD_version < 1400068
	if ((error = vn_start_write(vp, &mp, V_WAIT | PCATCH)) != 0)
#else
	if ((error = vn_start_write(vp, &mp, V_WAIT | V_PCATCH)) != 0)
#endif
		goto drop;
	vn_lock(vp, LK_EXCLUSIVE | LK_RETRY);
	error = VOP_FSYNC(vp, MNT_WAIT, curthread);
	VOP_UNLOCK(vp);
	vn_finished_write(mp);
drop:
	return (SET_ERROR(error));
}

int
zfs_file_fsync(zfs_file_t *zfp, int flags)
{
	struct file *fp = zfp;
	if (fp->f_type != DTYPE_VNODE)
		return (EINVAL);

	return (zfs_vop_fsync(fp->f_vnode));
}

/*
 * deallocate - zero and/or deallocate file storage
 *
 * fp - file pointer
 * offset - offset to start zeroing or deallocating
 * len - length to zero or deallocate
 */
int
zfs_file_deallocate(zfs_file_t *zfp, loff_t offset, loff_t len)
{
	struct file *fp = zfp;
	int rc;
#if __FreeBSD_version >= 1400029
	struct thread *td;

	td = curthread;
	rc = fo_fspacectl(fp, SPACECTL_DEALLOC, &offset, &len, 0,
	    td->td_ucred, td);
#else
	(void) fp, (void) offset, (void) len;
	rc = EOPNOTSUPP;
#endif
	if (rc)
		return (SET_ERROR(rc));
	return (0);
}

zfs_file_t *
zfs_file_get(int fd)
{
	struct file *fp;

	if (fget(curthread, fd, &cap_no_rights, &fp))
		return (NULL);

	return (fp);
}

void
zfs_file_put(zfs_file_t *zfp)
{
	struct file *fp = zfp;
	zfs_file_close(fp);
}

loff_t
zfs_file_off(zfs_file_t *zfp)
{
	struct file *fp = zfp;
	return (fp->f_offset);
}

void *
zfs_file_private(zfs_file_t *zfp)
{
	struct file *fp = zfp;
	file_t *tmpfp;
	void *data;
	int error;

	tmpfp = curthread->td_fpop;
	curthread->td_fpop = fp;
	error = devfs_get_cdevpriv(&data);
	curthread->td_fpop = tmpfp;
	if (error != 0)
		return (NULL);
	return (data);
}

int
zfs_file_unlink(const char *fnamep)
{
	zfs_uio_seg_t seg = UIO_SYSSPACE;
	int rc;

	rc = kern_funlinkat(curthread, AT_FDCWD, fnamep, FD_NONE, seg, 0, 0);
	return (SET_ERROR(rc));
}
