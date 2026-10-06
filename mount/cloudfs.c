#define FUSE_USE_VERSION 35

#include "cloudfs.h"

#include <errno.h>
#include <fcntl.h>
#include <fuse_lowlevel.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

struct _CmSession {
    struct fuse_session *se;
    struct fuse_buf buf;
    guint source;
    gboolean mounted;
    gboolean closed_sent;
    CmDispatch dispatch;
    CmClosed closed;
    void *user_data;
};

static CmRequest *
new_request (fuse_req_t req, CmOp op, fuse_ino_t ino)
{
    CmRequest *r = g_new0 (CmRequest, 1);
    r->ref_count = 1;
    r->req = req;
    r->op = op;
    r->ino = ino;
    return r;
}

static void
dispatch (CmRequest *r)
{
    CmSession *s = fuse_req_userdata ((fuse_req_t) r->req);
    s->dispatch (r, s->user_data);
}

static void
take_fi (CmRequest *r, struct fuse_file_info *fi)
{
    if (fi == NULL)
        return;
    r->fh = fi->fh;
    r->flags = fi->flags;
    r->has_fh = TRUE;
}

CmRequest *
cm_request_ref (CmRequest *request)
{
    g_atomic_int_inc (&request->ref_count);
    return request;
}

void
cm_request_unref (CmRequest *request)
{
    if (!g_atomic_int_dec_and_test (&request->ref_count))
        return;
    if (!request->replied)
        fuse_reply_err ((fuse_req_t) request->req, EIO);
    g_free (request->name);
    g_free (request->newname);
    g_free (request->data);
    g_free (request);
}

static gboolean
claim (CmRequest *request)
{
    if (request->replied)
        return FALSE;
    request->replied = TRUE;
    return TRUE;
}

static void
fill_stat (struct stat *st, const CmAttr *attr)
{
    memset (st, 0, sizeof (*st));
    st->st_ino = attr->ino;
    st->st_mode = attr->mode;
    st->st_nlink = attr->nlink;
    st->st_size = attr->size;
    st->st_blocks = (attr->size + 511) / 512;
    st->st_blksize = 4096;
    st->st_uid = attr->uid;
    st->st_gid = attr->gid;
    st->st_mtim.tv_sec = attr->mtime;
    st->st_ctim.tv_sec = attr->mtime;
    st->st_atim.tv_sec = attr->mtime;
}

void
cm_reply_err (CmRequest *request, int err)
{
    if (claim (request))
        fuse_reply_err ((fuse_req_t) request->req, err);
}

static void
fill_entry (struct fuse_entry_param *e, const CmAttr *attr, double timeout)
{
    memset (e, 0, sizeof (*e));
    e->ino = attr->ino;
    e->attr_timeout = timeout;
    e->entry_timeout = timeout;
    fill_stat (&e->attr, attr);
}

void
cm_reply_entry (CmRequest *request, const CmAttr *attr, double timeout)
{
    struct fuse_entry_param e;
    if (!claim (request))
        return;
    fill_entry (&e, attr, timeout);
    fuse_reply_entry ((fuse_req_t) request->req, &e);
}

void
cm_reply_create (CmRequest *request, const CmAttr *attr, double timeout, uint64_t fh, gboolean direct_io)
{
    struct fuse_entry_param e;
    struct fuse_file_info fi;
    if (!claim (request))
        return;
    fill_entry (&e, attr, timeout);
    memset (&fi, 0, sizeof (fi));
    fi.flags = request->flags;
    fi.fh = fh;
    fi.direct_io = direct_io ? 1 : 0;
    fuse_reply_create ((fuse_req_t) request->req, &e, &fi);
}

void
cm_reply_attr (CmRequest *request, const CmAttr *attr, double timeout)
{
    struct stat st;
    if (!claim (request))
        return;
    fill_stat (&st, attr);
    fuse_reply_attr ((fuse_req_t) request->req, &st, timeout);
}

void
cm_reply_open (CmRequest *request, uint64_t fh, gboolean direct_io)
{
    struct fuse_file_info fi;
    if (!claim (request))
        return;
    memset (&fi, 0, sizeof (fi));
    fi.flags = request->flags;
    fi.fh = fh;
    fi.direct_io = direct_io ? 1 : 0;
    fuse_reply_open ((fuse_req_t) request->req, &fi);
}

void
cm_reply_write (CmRequest *request, size_t count)
{
    if (claim (request))
        fuse_reply_write ((fuse_req_t) request->req, count);
}

void
cm_reply_fd (CmRequest *request, int fd, size_t size, int64_t offset)
{
    struct fuse_bufvec bv = FUSE_BUFVEC_INIT (size);
    if (!claim (request))
        return;
    bv.buf[0].flags = FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK;
    bv.buf[0].fd = fd;
    bv.buf[0].pos = offset;
    fuse_reply_data ((fuse_req_t) request->req, &bv, FUSE_BUF_SPLICE_MOVE);
}

void
cm_reply_buf (CmRequest *request, const uint8_t *data, size_t len)
{
    if (claim (request))
        fuse_reply_buf ((fuse_req_t) request->req, (const char *) data, len);
}

void
cm_reply_xattr_size (CmRequest *request, size_t size)
{
    if (claim (request))
        fuse_reply_xattr ((fuse_req_t) request->req, size);
}

void
cm_reply_statfs (CmRequest *request, uint64_t total, uint64_t free_bytes)
{
    struct statvfs st;
    if (!claim (request))
        return;
    memset (&st, 0, sizeof (st));
    st.f_bsize = 4096;
    st.f_frsize = 4096;
    st.f_blocks = total / 4096;
    st.f_bfree = free_bytes / 4096;
    st.f_bavail = free_bytes / 4096;
    st.f_files = 1000000;
    st.f_ffree = 1000000;
    st.f_favail = 1000000;
    st.f_namemax = 255;
    fuse_reply_statfs ((fuse_req_t) request->req, &st);
}

void
cm_reply_dir (CmRequest *request, char **names, int names_length, uint64_t *inos, int inos_length, uint32_t *modes, int modes_length)
{
    size_t cap = request->size;
    size_t used = 0;
    char *buf;
    int n = MIN (names_length, MIN (inos_length, modes_length));
    if (!claim (request))
        return;
    buf = g_malloc0 (cap > 0 ? cap : 1);
    for (int64_t i = request->offset; i >= 0 && i < n; i++) {
        struct stat st;
        size_t len;
        memset (&st, 0, sizeof (st));
        st.st_ino = inos[i];
        st.st_mode = modes[i];
        len = fuse_add_direntry ((fuse_req_t) request->req, buf + used, cap - used, names[i], &st, i + 1);
        if (len > cap - used)
            break;
        used += len;
    }
    fuse_reply_buf ((fuse_req_t) request->req, buf, used);
    g_free (buf);
}

static void
ll_init (void *userdata, struct fuse_conn_info *conn)
{
    fuse_set_feature_flag (conn, FUSE_CAP_ATOMIC_O_TRUNC);
}

static void
ll_lookup (fuse_req_t req, fuse_ino_t parent, const char *name)
{
    CmRequest *r = new_request (req, CM_OP_LOOKUP, 0);
    r->parent = parent;
    r->name = g_strdup (name);
    dispatch (r);
}

static void
ll_forget (fuse_req_t req, fuse_ino_t ino, uint64_t nlookup)
{
    fuse_reply_none (req);
}

static void
ll_forget_multi (fuse_req_t req, size_t count, struct fuse_forget_data *forgets)
{
    fuse_reply_none (req);
}

static void
ll_getattr (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_GETATTR, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_setattr (fuse_req_t req, fuse_ino_t ino, struct stat *attr, int to_set, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_SETATTR, ino);
    take_fi (r, fi);
    r->to_set = to_set;
    r->attr_size = attr->st_size;
    r->mode = attr->st_mode;
    dispatch (r);
}

static void
ll_opendir (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_OPENDIR, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_readdir (fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_READDIR, ino);
    take_fi (r, fi);
    r->size = size;
    r->offset = off;
    dispatch (r);
}

static void
ll_releasedir (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_RELEASEDIR, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_open (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_OPEN, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_read (fuse_req_t req, fuse_ino_t ino, size_t size, off_t off, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_READ, ino);
    take_fi (r, fi);
    r->size = size;
    r->offset = off;
    dispatch (r);
}

static void
ll_write (fuse_req_t req, fuse_ino_t ino, const char *buf, size_t size, off_t off, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_WRITE, ino);
    take_fi (r, fi);
    r->data = g_memdup2 (buf, size);
    r->data_len = size;
    r->offset = off;
    dispatch (r);
}

static void
ll_flush (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_FLUSH, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_fsync (fuse_req_t req, fuse_ino_t ino, int datasync, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_FSYNC, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_release (fuse_req_t req, fuse_ino_t ino, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_RELEASE, ino);
    take_fi (r, fi);
    dispatch (r);
}

static void
ll_create (fuse_req_t req, fuse_ino_t parent, const char *name, mode_t mode, struct fuse_file_info *fi)
{
    CmRequest *r = new_request (req, CM_OP_CREATE, 0);
    take_fi (r, fi);
    r->parent = parent;
    r->name = g_strdup (name);
    r->mode = mode;
    dispatch (r);
}

static void
ll_mkdir (fuse_req_t req, fuse_ino_t parent, const char *name, mode_t mode)
{
    CmRequest *r = new_request (req, CM_OP_MKDIR, 0);
    r->parent = parent;
    r->name = g_strdup (name);
    r->mode = mode;
    dispatch (r);
}

static void
ll_unlink (fuse_req_t req, fuse_ino_t parent, const char *name)
{
    CmRequest *r = new_request (req, CM_OP_UNLINK, 0);
    r->parent = parent;
    r->name = g_strdup (name);
    dispatch (r);
}

static void
ll_rmdir (fuse_req_t req, fuse_ino_t parent, const char *name)
{
    CmRequest *r = new_request (req, CM_OP_RMDIR, 0);
    r->parent = parent;
    r->name = g_strdup (name);
    dispatch (r);
}

static void
ll_rename (fuse_req_t req, fuse_ino_t parent, const char *name, fuse_ino_t newparent, const char *newname, unsigned int flags)
{
    CmRequest *r = new_request (req, CM_OP_RENAME, 0);
    r->parent = parent;
    r->name = g_strdup (name);
    r->newparent = newparent;
    r->newname = g_strdup (newname);
    r->flags = (int) flags;
    dispatch (r);
}

static void
ll_statfs (fuse_req_t req, fuse_ino_t ino)
{
    dispatch (new_request (req, CM_OP_STATFS, ino));
}

static void
ll_getxattr (fuse_req_t req, fuse_ino_t ino, const char *name, size_t size)
{
    CmRequest *r = new_request (req, CM_OP_GETXATTR, ino);
    r->name = g_strdup (name);
    r->size = size;
    dispatch (r);
}

static void
ll_setxattr (fuse_req_t req, fuse_ino_t ino, const char *name, const char *value, size_t size, int flags)
{
    CmRequest *r = new_request (req, CM_OP_SETXATTR, ino);
    r->name = g_strdup (name);
    r->data = g_memdup2 (value, size);
    r->data_len = size;
    r->flags = flags;
    dispatch (r);
}

static void
ll_listxattr (fuse_req_t req, fuse_ino_t ino, size_t size)
{
    CmRequest *r = new_request (req, CM_OP_LISTXATTR, ino);
    r->size = size;
    dispatch (r);
}

static void
ll_removexattr (fuse_req_t req, fuse_ino_t ino, const char *name)
{
    CmRequest *r = new_request (req, CM_OP_REMOVEXATTR, ino);
    r->name = g_strdup (name);
    dispatch (r);
}

static const struct fuse_lowlevel_ops cm_ops = {
    .init = ll_init,
    .lookup = ll_lookup,
    .forget = ll_forget,
    .forget_multi = ll_forget_multi,
    .getattr = ll_getattr,
    .setattr = ll_setattr,
    .opendir = ll_opendir,
    .readdir = ll_readdir,
    .releasedir = ll_releasedir,
    .open = ll_open,
    .read = ll_read,
    .write = ll_write,
    .flush = ll_flush,
    .fsync = ll_fsync,
    .release = ll_release,
    .create = ll_create,
    .mkdir = ll_mkdir,
    .unlink = ll_unlink,
    .rmdir = ll_rmdir,
    .rename = ll_rename,
    .statfs = ll_statfs,
    .getxattr = ll_getxattr,
    .setxattr = ll_setxattr,
    .listxattr = ll_listxattr,
    .removexattr = ll_removexattr,
};

static void
session_closed (CmSession *s)
{
    if (s->closed_sent)
        return;
    s->closed_sent = TRUE;
    s->source = 0;
    if (s->closed != NULL)
        s->closed (s->user_data);
}

static gboolean
on_readable (gint fd, GIOCondition condition, gpointer data)
{
    CmSession *s = data;
    for (int i = 0; i < 64; i++) {
        int res = fuse_session_receive_buf (s->se, &s->buf);
        if (res == -EINTR)
            continue;
        if (res == -EAGAIN)
            return G_SOURCE_CONTINUE;
        if (res <= 0) {
            session_closed (s);
            return G_SOURCE_REMOVE;
        }
        fuse_session_process_buf (s->se, &s->buf);
        if (fuse_session_exited (s->se)) {
            session_closed (s);
            return G_SOURCE_REMOVE;
        }
    }
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        session_closed (s);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

CmSession *
cm_session_new (const char *mountpoint, const char *fsname, CmDispatch dispatch_func, CmClosed closed, void *user_data, GError **error)
{
    CmSession *s = g_new0 (CmSession, 1);
    char *opts = g_strdup_printf ("fsname=%s,subtype=singularity-cloud,default_permissions,auto_unmount", fsname);
    char *argv[] = { (char *) "singularity-cloud-mount", (char *) "-o", opts, NULL };
    struct fuse_args args = FUSE_ARGS_INIT (3, argv);
    int fd;
    s->dispatch = dispatch_func;
    s->closed = closed;
    s->user_data = user_data;
    s->se = fuse_session_new (&args, &cm_ops, sizeof (cm_ops), s);
    fuse_opt_free_args (&args);
    g_free (opts);
    if (s->se == NULL) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not create the file system session");
        g_free (s);
        return NULL;
    }
    if (fuse_session_mount (s->se, mountpoint) != 0) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not mount %s", mountpoint);
        fuse_session_destroy (s->se);
        g_free (s);
        return NULL;
    }
    s->mounted = TRUE;
    fd = fuse_session_fd (s->se);
    fcntl (fd, F_SETFL, fcntl (fd, F_GETFL) | O_NONBLOCK);
    s->source = g_unix_fd_add (fd, G_IO_IN | G_IO_HUP | G_IO_ERR, on_readable, s);
    return s;
}

void
cm_session_free (CmSession *session)
{
    if (session == NULL)
        return;
    session->closed = NULL;
    if (session->source != 0)
        g_source_remove (session->source);
    session->source = 0;
    if (session->mounted)
        fuse_session_unmount (session->se);
    fuse_session_destroy (session->se);
    free (session->buf.mem);
    g_free (session);
}

gboolean
cm_unmount (const char *mountpoint)
{
    const char *argv[] = { "fusermount3", "-u", "-z", "-q", mountpoint, NULL };
    int status = 0;
    if (!g_spawn_sync (NULL, (char **) argv, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
                       NULL, NULL, NULL, NULL, &status, NULL))
        return FALSE;
    return g_spawn_check_wait_status (status, NULL);
}
