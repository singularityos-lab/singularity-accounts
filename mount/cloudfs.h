#ifndef SINGULARITY_CLOUDFS_H
#define SINGULARITY_CLOUDFS_H

#include <glib.h>
#include <stdint.h>

G_BEGIN_DECLS

typedef enum {
    CM_OP_LOOKUP,
    CM_OP_GETATTR,
    CM_OP_SETATTR,
    CM_OP_OPENDIR,
    CM_OP_READDIR,
    CM_OP_RELEASEDIR,
    CM_OP_OPEN,
    CM_OP_READ,
    CM_OP_WRITE,
    CM_OP_FLUSH,
    CM_OP_FSYNC,
    CM_OP_RELEASE,
    CM_OP_CREATE,
    CM_OP_MKDIR,
    CM_OP_UNLINK,
    CM_OP_RMDIR,
    CM_OP_RENAME,
    CM_OP_STATFS,
    CM_OP_GETXATTR,
    CM_OP_SETXATTR,
    CM_OP_LISTXATTR,
    CM_OP_REMOVEXATTR
} CmOp;

typedef struct {
    uint64_t ino;
    uint32_t mode;
    uint32_t nlink;
    int64_t size;
    int64_t mtime;
    uint32_t uid;
    uint32_t gid;
} CmAttr;

typedef struct _CmRequest CmRequest;
struct _CmRequest {
    gint ref_count;
    gboolean replied;
    void *req;
    CmOp op;
    uint64_t ino;
    uint64_t parent;
    uint64_t newparent;
    uint64_t fh;
    gboolean has_fh;
    char *name;
    char *newname;
    uint64_t size;
    int64_t offset;
    int flags;
    uint32_t mode;
    uint8_t *data;
    size_t data_len;
    int to_set;
    int64_t attr_size;
};

#define CM_SET_ATTR_MODE (1 << 0)
#define CM_SET_ATTR_SIZE (1 << 3)

typedef void (*CmDispatch) (CmRequest *request, void *user_data);
typedef void (*CmClosed) (void *user_data);

typedef struct _CmSession CmSession;

CmRequest *cm_request_ref (CmRequest *request);
void cm_request_unref (CmRequest *request);

void cm_reply_err (CmRequest *request, int err);
void cm_reply_entry (CmRequest *request, const CmAttr *attr, double timeout);
void cm_reply_create (CmRequest *request, const CmAttr *attr, double timeout, uint64_t fh, gboolean direct_io);
void cm_reply_attr (CmRequest *request, const CmAttr *attr, double timeout);
void cm_reply_open (CmRequest *request, uint64_t fh, gboolean direct_io);
void cm_reply_write (CmRequest *request, size_t count);
void cm_reply_fd (CmRequest *request, int fd, size_t size, int64_t offset);
void cm_reply_buf (CmRequest *request, const uint8_t *data, size_t len);
void cm_reply_xattr_size (CmRequest *request, size_t size);
void cm_reply_statfs (CmRequest *request, uint64_t total, uint64_t free_bytes);
void cm_reply_dir (CmRequest *request, char **names, int names_length, uint64_t *inos, int inos_length, uint32_t *modes, int modes_length);

CmSession *cm_session_new (const char *mountpoint, const char *fsname, CmDispatch dispatch, CmClosed closed, void *user_data, GError **error);
void cm_session_free (CmSession *session);

gboolean cm_unmount (const char *mountpoint);

G_END_DECLS

#endif
