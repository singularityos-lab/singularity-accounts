[CCode (cheader_filename = "cloudfs.h", cprefix = "Cm", lower_case_cprefix = "cm_")]
namespace CloudFs {
    [CCode (cname = "CmOp", cprefix = "CM_OP_", has_type_id = false)]
    public enum Op {
        LOOKUP,
        GETATTR,
        SETATTR,
        OPENDIR,
        READDIR,
        RELEASEDIR,
        OPEN,
        READ,
        WRITE,
        FLUSH,
        FSYNC,
        RELEASE,
        CREATE,
        MKDIR,
        UNLINK,
        RMDIR,
        RENAME,
        STATFS,
        GETXATTR,
        SETXATTR,
        LISTXATTR,
        REMOVEXATTR
    }

    [CCode (cname = "CM_SET_ATTR_SIZE")]
    public const int SET_ATTR_SIZE;

    [CCode (cname = "CmAttr", has_type_id = false, destroy_function = "")]
    public struct Attr {
        public uint64 ino;
        public uint32 mode;
        public uint32 nlink;
        public int64 size;
        public int64 mtime;
        public uint32 uid;
        public uint32 gid;
    }

    [Compact]
    [CCode (cname = "CmRequest", ref_function = "cm_request_ref", unref_function = "cm_request_unref")]
    public class Request {
        public bool replied;
        public Op op;
        public uint64 ino;
        public uint64 parent;
        public uint64 newparent;
        public uint64 fh;
        public bool has_fh;
        public string? name;
        public string? newname;
        public uint64 size;
        public int64 offset;
        public int flags;
        public uint32 mode;
        [CCode (array_length_cname = "data_len", array_length_type = "size_t")]
        public uint8[]? data;
        public int to_set;
        public int64 attr_size;

        [CCode (cname = "cm_reply_err")]
        public void reply_err(int err);
        [CCode (cname = "cm_reply_entry")]
        public void reply_entry(Attr attr, double timeout);
        [CCode (cname = "cm_reply_create")]
        public void reply_create(Attr attr, double timeout, uint64 fh, bool direct_io);
        [CCode (cname = "cm_reply_attr")]
        public void reply_attr(Attr attr, double timeout);
        [CCode (cname = "cm_reply_open")]
        public void reply_open(uint64 fh, bool direct_io);
        [CCode (cname = "cm_reply_write")]
        public void reply_write(size_t count);
        [CCode (cname = "cm_reply_fd")]
        public void reply_fd(int fd, size_t size, int64 offset);
        [CCode (cname = "cm_reply_buf")]
        public void reply_buf([CCode (array_length_type = "size_t")] uint8[] data);
        [CCode (cname = "cm_reply_xattr_size")]
        public void reply_xattr_size(size_t size);
        [CCode (cname = "cm_reply_statfs")]
        public void reply_statfs(uint64 total, uint64 free_bytes);
        [CCode (cname = "cm_reply_dir")]
        public void reply_dir(string[] names, uint64[] inos, uint32[] modes);
    }

    [CCode (cname = "CmDispatch", has_target = false)]
    public delegate void Dispatch(owned Request request, void* user_data);
    [CCode (cname = "CmClosed", has_target = false)]
    public delegate void Closed(void* user_data);

    [Compact]
    [CCode (cname = "CmSession", free_function = "cm_session_free")]
    public class Session {
        [CCode (cname = "cm_session_new")]
        public static Session? open(string mountpoint, string fsname, Dispatch dispatch, Closed closed, void* user_data) throws GLib.Error;
    }

    [CCode (cname = "cm_unmount")]
    public bool unmount(string mountpoint);
}
