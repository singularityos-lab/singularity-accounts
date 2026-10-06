using Singularity.Accounts;

namespace Singularity.CloudMount {

    public class MountConfig : Object {
        public int listing_ttl { get; set; default = 30; }
        public uint64 cache_limit { get; set; default = 2048 * 1024 * 1024ULL; }
        public double attr_timeout { get; set; default = 1.0; }

        public static MountConfig load() {
            var config = new MountConfig();
            var kf = new KeyFile();
            try {
                kf.load_from_file(Path.build_filename(Environment.get_user_config_dir(), "singularity", "cloud.conf"), KeyFileFlags.NONE);
                if (kf.has_key("Cache", "MaxSizeMB")) config.cache_limit = (uint64) kf.get_int64("Cache", "MaxSizeMB") * 1024 * 1024;
                if (kf.has_key("Listing", "RefreshSeconds")) config.listing_ttl = kf.get_integer("Listing", "RefreshSeconds");
            } catch (Error e) {
            }
            string? ttl = Environment.get_variable("SINGULARITY_CLOUD_TTL");
            if (ttl != null) config.listing_ttl = int.parse(ttl);
            string? mb = Environment.get_variable("SINGULARITY_CLOUD_CACHE_MB");
            if (mb != null) config.cache_limit = (uint64) int64.parse(mb) * 1024 * 1024;
            return config;
        }
    }

    public class DriveFs : Object {
        private const uint32 S_IFDIR = 0040000;
        private const uint32 S_IFREG = 0100000;
        private const int RENAME_NOREPLACE = 1;
        private const int RENAME_EXCHANGE = 2;
        private const int64 EXPORT_PLACEHOLDER_SIZE = 4096;
        public const string XATTR_OFFLINE = "user.singularity.offline";
        public const string XATTR_STATE = "user.singularity.state";
        public const string XATTR_ACCOUNT = "user.singularity.cloud-account";
        public const string XATTR_ENTRY = "user.singularity.cloud-id";

        private class Handle {
            public Node node;
            public int fd;
            public bool writable;
            public bool dirty;
        }

        private class TransferMeter {
            public int64 done;
            public int64 total;
        }

        private class DirHandle {
            public string[] names;
            public uint64[] inos;
            public uint32[] modes;
        }

        public Account account { get; construct; }
        public CloudDrive drive { get; construct; }
        public string mountpoint { get; construct; }
        public MountConfig config { get; construct; }
        public ContentCache cache { get; private set; }
        public NodeTable table { get; private set; }

        public bool online { get; private set; default = true; }
        public string status { get; private set; default = "online"; }
        public int pending_uploads { get; private set; default = 0; }
        public int64 transferred { get; private set; default = 0; }
        public int64 transfer_size { get; private set; default = 0; }
        public int64 quota_used { get; private set; default = -1; }
        public int64 quota_total { get; private set; default = -1; }

        public signal void state_changed();
        public signal void closed();

        private CloudFs.Session? session;
        private Gee.HashMap<string, Handle> handles = new Gee.HashMap<string, Handle>();
        private Gee.HashMap<string, DirHandle> dir_handles = new Gee.HashMap<string, DirHandle>();
        private Gee.HashMap<string, Gate> downloads = new Gee.HashMap<string, Gate>();
        private Gee.HashSet<Node> retry = new Gee.HashSet<Node>();
        private uint64 next_fh = 1;
        private int transfers = 0;
        private Gee.HashSet<TransferMeter> meters = new Gee.HashSet<TransferMeter>();
        private uint meter_source = 0;
        private uint retry_source = 0;
        private int64 quota_at = -1;
        private bool quota_running;
        private bool resuming;
        private ulong network_handler = 0;
        private Cancellable cancellable = new Cancellable();
        private uint32 uid;
        private uint32 gid;

        public DriveFs(Account account, CloudDrive drive, string mountpoint, string cache_root, MountConfig config) {
            Object(account: account, drive: drive, mountpoint: mountpoint, config: config);
            cache = new ContentCache(cache_root, config.cache_limit);
            var root_entry = new CloudEntry();
            root_entry.id = drive.root_id;
            root_entry.name = account.display_name;
            root_entry.is_folder = true;
            table = new NodeTable(root_entry);
            table.root.cache_key = drive.root_id;
            table.root.local_mtime = get_real_time() / 1000000;
            uid = (uint32) Posix.getuid();
            gid = (uint32) Posix.getgid();
        }

        public bool is_webdav {
            get { return drive is WebDavDrive; }
        }

        public void start() throws Error {
            session = CloudFs.Session.open(mountpoint, "singularity-cloud:" + account.id, on_request, on_closed, this);
            network_handler = NetworkMonitor.get_default().network_changed.connect((available) => {
                if (available) {
                    table.root.listed_at = -1;
                    retry_now();
                }
            });
            resume_dirty.begin();
            refresh_quota.begin();
        }

        public void stop() {
            cancellable.cancel();
            if (network_handler != 0) NetworkMonitor.get_default().disconnect(network_handler);
            network_handler = 0;
            if (retry_source != 0) Source.remove(retry_source);
            retry_source = 0;
            foreach (var h in handles.values) Posix.close(h.fd);
            handles.clear();
            session = null;
            cache.save();
        }

        private static void on_request(owned CloudFs.Request request, void* data) {
            unowned DriveFs self = (DriveFs) data;
            self.handle.begin(request);
        }

        private static void on_closed(void* data) {
            unowned DriveFs self = (DriveFs) data;
            Idle.add(() => {
                self.closed();
                return Source.REMOVE;
            });
        }

        private static Quark FS_ERROR = Quark.from_string("singularity-cloudfs");

        private static Error fs_error(int code) {
            return new Error(FS_ERROR, code, "%s", Posix.strerror(code));
        }

        private static int errno_for(Error e) {
            if (e is AccountsError.NOT_FOUND) return Posix.ENOENT;
            if (e is AccountsError.NETWORK) return Posix.ENETUNREACH;
            if (e is AccountsError.NEEDS_REAUTH || e is AccountsError.AUTH_FAILED) return Posix.EACCES;
            if (e is AccountsError.CONFLICT) return Posix.EEXIST;
            if (e is AccountsError.CANCELLED || e is IOError.CANCELLED) return Posix.EINTR;
            if (e.domain == FS_ERROR) return e.code;
            return Posix.EIO;
        }

        private static bool is_network(Error e) {
            return e is AccountsError.NETWORK;
        }

        private void mark_online() {
            if (online) return;
            online = true;
            update_status();
            retry_now();
        }

        private void mark_offline() {
            if (!online) return;
            online = false;
            update_status();
            schedule_retry();
        }

        private void update_status() {
            int pending = cache.dirty_records().size;
            string next;
            if (!account.healthy) next = "attention";
            else if (!online) next = "offline";
            else if (transfers > 0 || pending > 0) next = "syncing";
            else next = "online";
            if (next == status && pending == pending_uploads) return;
            status = next;
            pending_uploads = pending;
            state_changed();
        }

        public void account_updated() {
            update_status();
        }

        private TransferMeter begin_meter(int64 total) {
            var m = new TransferMeter();
            m.total = total;
            meters.add(m);
            queue_meters();
            return m;
        }

        private void end_meter(TransferMeter m) {
            meters.remove(m);
            queue_meters();
        }

        private void queue_meters() {
            if (meter_source != 0) return;
            meter_source = Timeout.add(400, () => {
                meter_source = 0;
                int64 done = 0;
                int64 size = 0;
                foreach (var m in meters) {
                    done += m.done;
                    size += int64.max(m.total, m.done);
                }
                if (done == transferred && size == transfer_size) return Source.REMOVE;
                transferred = done;
                transfer_size = size;
                state_changed();
                return Source.REMOVE;
            });
        }

        private CloudFs.Attr attr_of(Node n) {
            var a = CloudFs.Attr();
            a.ino = n.ino;
            a.uid = uid;
            a.gid = gid;
            if (n.is_dir) {
                a.mode = S_IFDIR | 0700;
                a.nlink = 2;
                a.size = 4096;
            } else {
                a.mode = S_IFREG | (n.is_export ? 0400 : 0600);
                a.nlink = 1;
                a.size = size_of(n);
            }
            if (n.entry != null && n.entry.modified != null && !n.dirty) a.mtime = n.entry.modified.to_unix();
            else if (n.local_mtime > 0) a.mtime = n.local_mtime;
            else if (n.entry != null && n.entry.modified != null) a.mtime = n.entry.modified.to_unix();
            return a;
        }

        private double timeout_for(Node n) {
            return n.is_export ? 0.0 : config.attr_timeout;
        }

        private void reply_attr(CloudFs.Request r, Node n) {
            r.reply_attr(attr_of(n), timeout_for(n));
        }

        private int64 size_of(Node n) {
            bool use_local = n.entry == null || n.dirty || n.uploading || n.open_writers > 0 || n.is_export || n.entry.size < 0;
            if (use_local && n.cache_key != "") {
                Posix.Stat st;
                if (Posix.stat(cache.file_path(n.cache_key), out st) == 0) return (int64) st.st_size;
            }
            if (n.is_export) return EXPORT_PLACEHOLDER_SIZE;
            return n.entry != null && n.entry.size >= 0 ? n.entry.size : 0;
        }

        private void prefetch_exports(Node dir) {
            int queued = 0;
            foreach (var c in table.children(dir.ino)) {
                if (!c.is_export || cache.has_content(c.cache_key)) continue;
                if (queued++ >= 20) break;
                fetch_in_background(c);
            }
        }

        private static string version_of(CloudEntry e) {
            if (e.etag != "") return e.etag;
            string stamp = "";
            if (e.modified != null) stamp = e.modified.to_unix().to_string();
            return "%s:%lld".printf(stamp, e.size);
        }

        private Node require(uint64 ino) throws Error {
            var n = table.get(ino);
            if (n == null || n.deleted) throw fs_error(Posix.ENOENT);
            return n;
        }

        private Node require_dir(uint64 ino) throws Error {
            var n = require(ino);
            if (!n.is_dir) throw fs_error(Posix.ENOTDIR);
            return n;
        }

        private async void handle(CloudFs.Request r) {
            try {
                switch (r.op) {
                    case CloudFs.Op.LOOKUP: yield op_lookup(r); break;
                    case CloudFs.Op.GETATTR: reply_attr(r, require(r.ino)); break;
                    case CloudFs.Op.SETATTR: yield op_setattr(r); break;
                    case CloudFs.Op.OPENDIR: yield op_opendir(r); break;
                    case CloudFs.Op.READDIR: op_readdir(r); break;
                    case CloudFs.Op.RELEASEDIR:
                        dir_handles.unset(r.fh.to_string());
                        r.reply_err(0);
                        break;
                    case CloudFs.Op.OPEN: yield op_open(r); break;
                    case CloudFs.Op.READ: op_read(r); break;
                    case CloudFs.Op.WRITE: op_write(r); break;
                    case CloudFs.Op.FLUSH: r.reply_err(0); break;
                    case CloudFs.Op.FSYNC: yield op_fsync(r); break;
                    case CloudFs.Op.RELEASE: op_release(r); break;
                    case CloudFs.Op.CREATE: yield op_create(r); break;
                    case CloudFs.Op.MKDIR: yield op_mkdir(r); break;
                    case CloudFs.Op.UNLINK: yield op_unlink(r); break;
                    case CloudFs.Op.RMDIR: yield op_rmdir(r); break;
                    case CloudFs.Op.RENAME: yield op_rename(r); break;
                    case CloudFs.Op.STATFS: op_statfs(r); break;
                    case CloudFs.Op.GETXATTR: op_getxattr(r); break;
                    case CloudFs.Op.SETXATTR: op_setxattr(r); break;
                    case CloudFs.Op.LISTXATTR: op_listxattr(r); break;
                    case CloudFs.Op.REMOVEXATTR: op_removexattr(r); break;
                    default: r.reply_err(Posix.ENOSYS); break;
                }
            } catch (Error e) {
                int err = errno_for(e);
                if (err == Posix.EIO) warning("%s: %s", account.id, e.message);
                r.reply_err(err);
            }
        }

        public async void ensure_listing(Node dir, bool force = false) throws Error {
            if (!dir.is_dir || dir.entry == null) return;
            while (dir.listing) yield dir.gate.wait();
            int64 now = get_monotonic_time();
            int64 ttl = (int64) config.listing_ttl * 1000000;
            if (!force && dir.listed_at >= 0 && now - dir.listed_at < ttl) return;
            dir.listing = true;
            try {
                var entries = yield drive.list(dir.entry.id, cancellable);
                foreach (var e in entries) Names.apply_export(e);
                cache.store_listing(dir.entry.id, entries);
                merge_listing(dir, entries);
                dir.listed_at = get_monotonic_time();
                mark_online();
            } catch (Error e) {
                if (!is_network(e)) {
                    finish_listing(dir);
                    throw e;
                }
                mark_offline();
                int64 retry_at = get_monotonic_time() - ttl + 5000000;
                if (dir.listed_at < 0) {
                    var stored = cache.load_listing(dir.entry.id);
                    if (stored == null) {
                        finish_listing(dir);
                        throw e;
                    }
                    merge_listing(dir, stored);
                }
                dir.listed_at = retry_at;
            }
            finish_listing(dir);
        }

        private void finish_listing(Node dir) {
            dir.listing = false;
            dir.gate.open();
        }

        private void merge_listing(Node dir, Gee.List<CloudEntry> entries) {
            var seen = new Gee.HashSet<string>();
            foreach (var named in Names.assign(entries)) {
                seen.add(named.name);
                var e = named.entry;
                if (e.parent_id == "") e.parent_id = dir.entry.id;
                var node = table.child(dir.ino, named.name);
                if (node != null && node.is_dir != e.is_folder) {
                    if (node.keeps_local_state) continue;
                    table.remove(node);
                    node = null;
                }
                if (node == null) {
                    node = table.add(dir.ino, named.name, e.is_folder, e);
                    node.cache_key = e.id;
                } else if (!node.dirty && !node.uploading) {
                    if (node.entry == null || node.entry.id != e.id) {
                        if (node.cache_key != "" && node.cache_key != e.id) cache.rekey(node.cache_key, e.id);
                        node.cache_key = e.id;
                    }
                    node.entry = e;
                }
                if (!node.is_dir && !node.dirty && cache.is_pinned(node.cache_key)) {
                    var rec = cache.lookup(node.cache_key);
                    if (rec == null || !rec.complete || rec.version != version_of(e)) fetch_in_background(node);
                }
            }
            bool dir_pinned = cache.is_pinned(dir.cache_key);
            foreach (var child in table.children(dir.ino)) {
                if (!seen.contains(child.name) && !child.keeps_local_state) {
                    table.remove(child);
                    continue;
                }
                if (dir_pinned && !child.is_dir && !cache.is_pinned(child.cache_key) && child.entry != null) {
                    cache.set_pinned(child.cache_key, true);
                    fetch_in_background(child);
                } else if (dir_pinned && child.is_dir && !cache.is_pinned(child.cache_key)) {
                    set_keep_offline.begin(child, true);
                }
            }
        }

        private void fetch_in_background(Node n) {
            ensure_content.begin(n, (obj, res) => {
                try {
                    ensure_content.end(res);
                } catch (Error e) {
                }
            });
        }

        private async void op_lookup(CloudFs.Request r) throws Error {
            var dir = require_dir(r.parent);
            yield ensure_listing(dir);
            var child = table.child(dir.ino, r.name);
            if (child == null) throw fs_error(Posix.ENOENT);
            r.reply_entry(attr_of(child), timeout_for(child));
        }

        private async void op_opendir(CloudFs.Request r) throws Error {
            var dir = require_dir(r.ino);
            yield ensure_listing(dir);
            if (online) prefetch_exports(dir);
            var h = new DirHandle();
            string[] names = { ".", ".." };
            uint64[] inos = { dir.ino, dir.parent };
            uint32[] modes = { S_IFDIR, S_IFDIR };
            foreach (var c in table.children(dir.ino)) {
                names += c.name;
                inos += c.ino;
                modes += c.is_dir ? S_IFDIR : S_IFREG;
            }
            h.names = names;
            h.inos = inos;
            h.modes = modes;
            uint64 fh = next_fh++;
            dir_handles[fh.to_string()] = h;
            r.reply_open(fh, false);
        }

        private void op_readdir(CloudFs.Request r) throws Error {
            var h = dir_handles[r.fh.to_string()];
            if (h == null) throw fs_error(Posix.EBADF);
            r.reply_dir(h.names, h.inos, h.modes);
        }

        public async string ensure_content(Node n) throws Error {
            string key = n.cache_key;
            string path = cache.prepare_path(key);
            if (n.entry == null || n.dirty || n.uploading) {
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
                throw fs_error(Posix.ENOENT);
            }
            while (downloads.has_key(key)) yield downloads[key].wait();
            var rec = cache.lookup(key);
            bool present = cache.has_content(key);
            if (present && rec.version == version_of(n.entry)) {
                cache.touch(key);
                return path;
            }
            if (present && !online) return path;
            var gate = new Gate();
            downloads[key] = gate;
            transfers++;
            update_status();
            string part = path + ".part";
            var meter = begin_meter(n.entry.size);
            try {
                yield drive.download(n.entry, File.new_for_path(part), cancellable, (done, total) => {
                    meter.done = done;
                    if (total > 0) meter.total = total;
                    queue_meters();
                });
                end_meter(meter);
                if (FileUtils.rename(part, path) != 0) throw fs_error(Posix.EIO);
                Posix.Stat st;
                Posix.stat(path, out st);
                cache.commit(key, version_of(n.entry), (int64) st.st_size);
                mark_online();
            } catch (Error e) {
                end_meter(meter);
                FileUtils.remove(part);
                downloads.unset(key);
                transfers--;
                gate.open();
                update_status();
                if (is_network(e)) {
                    mark_offline();
                    if (present) return path;
                }
                throw e;
            }
            downloads.unset(key);
            transfers--;
            gate.open();
            update_status();
            evict();
            return path;
        }

        private void evict() {
            cache.evict((k) => {
                foreach (var h in handles.values) if (h.node.cache_key == k) return true;
                return downloads.has_key(k);
            });
        }

        private Handle open_handle(Node n, string path, bool writable) throws Error {
            int fd = Posix.open(path, writable ? Posix.O_RDWR : Posix.O_RDONLY);
            if (fd < 0) throw fs_error(Posix.errno);
            var h = new Handle();
            h.node = n;
            h.fd = fd;
            h.writable = writable;
            n.open_count++;
            if (writable) n.open_writers++;
            return h;
        }

        private uint64 register(Handle h) {
            uint64 fh = next_fh++;
            handles[fh.to_string()] = h;
            return fh;
        }

        private string empty_local_copy(Node n) throws Error {
            string path = cache.prepare_path(n.cache_key);
            FileUtils.set_contents(path, "");
            return path;
        }

        private void mark_dirty(Node n) {
            n.dirty = true;
            n.local_mtime = get_real_time() / 1000000;
            var parent = table.get(n.parent);
            cache.set_dirty(n.cache_key, true, parent != null && parent.entry != null ? parent.entry.id : "",
                Names.remote_name(n.name, n.entry));
            update_status();
        }

        private async void op_open(CloudFs.Request r) throws Error {
            var n = require(r.ino);
            if (n.is_dir) throw fs_error(Posix.EISDIR);
            bool writable = (r.flags & Posix.O_ACCMODE) != Posix.O_RDONLY;
            if (writable && n.is_export) throw fs_error(Posix.EACCES);
            string path;
            bool truncate = writable && (r.flags & Posix.O_TRUNC) != 0;
            if (truncate) {
                yield n.wait_idle();
                path = empty_local_copy(n);
            } else {
                path = yield ensure_content(n);
            }
            var h = open_handle(n, path, writable);
            if (truncate) {
                h.dirty = true;
                mark_dirty(n);
            }
            r.reply_open(register(h), n.is_export);
        }

        private void op_read(CloudFs.Request r) throws Error {
            var h = handles[r.fh.to_string()];
            if (h == null) throw fs_error(Posix.EBADF);
            r.reply_fd(h.fd, (size_t) r.size, r.offset);
        }

        private void op_write(CloudFs.Request r) throws Error {
            var h = handles[r.fh.to_string()];
            if (h == null || !h.writable) throw fs_error(Posix.EBADF);
            ssize_t n = Posix.pwrite(h.fd, r.data, r.data.length, (Posix.off_t) r.offset);
            if (n < 0) throw fs_error(Posix.errno);
            if (!h.dirty) {
                h.dirty = true;
                mark_dirty(h.node);
            }
            r.reply_write((size_t) n);
        }

        private void op_release(CloudFs.Request r) {
            var h = handles[r.fh.to_string()];
            handles.unset(r.fh.to_string());
            r.reply_err(0);
            if (h == null) return;
            Posix.close(h.fd);
            var n = h.node;
            n.open_count--;
            if (h.writable) n.open_writers--;
            if (n.dirty && n.open_writers == 0 && !n.deleted) schedule_upload(n);
        }

        private async void op_fsync(CloudFs.Request r) throws Error {
            var h = handles[r.fh.to_string()];
            if (h == null) throw fs_error(Posix.EBADF);
            Posix.fsync(h.fd);
            if (!h.node.dirty) {
                r.reply_err(0);
                return;
            }
            yield h.node.wait_idle();
            if (h.node.dirty) {
                if (!yield upload_node(h.node, true)) throw fs_error(online ? Posix.EIO : Posix.ENETUNREACH);
            }
            r.reply_err(0);
        }

        private async void op_setattr(CloudFs.Request r) throws Error {
            var n = require(r.ino);
            if ((r.to_set & CloudFs.SET_ATTR_SIZE) != 0) {
                if (n.is_dir) throw fs_error(Posix.EISDIR);
                if (n.is_export) throw fs_error(Posix.EACCES);
                var h = r.has_fh ? handles[r.fh.to_string()] : null;
                if (h != null && h.writable) {
                    if (Posix.ftruncate(h.fd, (Posix.off_t) r.attr_size) != 0) throw fs_error(Posix.errno);
                    if (!h.dirty) {
                        h.dirty = true;
                        mark_dirty(n);
                    }
                } else {
                    yield n.wait_idle();
                    string path = r.attr_size == 0 ? empty_local_copy(n) : yield ensure_content(n);
                    if (Posix.truncate(path, (Posix.off_t) r.attr_size) != 0) throw fs_error(Posix.errno);
                    mark_dirty(n);
                    if (n.open_writers == 0) schedule_upload(n);
                }
            }
            reply_attr(r, n);
        }

        private async void op_create(CloudFs.Request r) throws Error {
            var dir = require_dir(r.parent);
            yield listing_tolerant(dir);
            if (Names.is_reserved(r.name, dir.ino == NodeTable.ROOT)) throw fs_error(Posix.EPERM);
            var existing = table.child(dir.ino, r.name);
            Node n;
            if (existing != null) {
                if ((r.flags & Posix.O_EXCL) != 0) throw fs_error(Posix.EEXIST);
                if (existing.is_dir) throw fs_error(Posix.EISDIR);
                if (existing.is_export) throw fs_error(Posix.EACCES);
                yield existing.wait_idle();
                n = existing;
            } else {
                n = table.add(dir.ino, r.name, false, null);
                n.cache_key = "pending:" + Uuid.string_random();
            }
            bool keep_content = existing != null && (r.flags & Posix.O_TRUNC) == 0;
            string path = keep_content ? yield ensure_content(n) : empty_local_copy(n);
            var h = open_handle(n, path, true);
            if (!keep_content) {
                h.dirty = true;
                mark_dirty(n);
            }
            r.reply_create(attr_of(n), timeout_for(n), register(h), false);
        }

        private async void listing_tolerant(Node dir) {
            try {
                yield ensure_listing(dir);
            } catch (Error e) {
            }
        }

        private async void op_mkdir(CloudFs.Request r) throws Error {
            var dir = require_dir(r.parent);
            yield ensure_listing(dir);
            if (Names.is_reserved(r.name, dir.ino == NodeTable.ROOT)) throw fs_error(Posix.EPERM);
            if (table.child(dir.ino, r.name) != null) throw fs_error(Posix.EEXIST);
            var e = yield drive.create_folder(dir.entry.id, r.name, cancellable);
            mark_online();
            if (e.parent_id == "") e.parent_id = dir.entry.id;
            var n = table.add(dir.ino, r.name, true, e);
            n.cache_key = e.id;
            n.listed_at = get_monotonic_time();
            r.reply_entry(attr_of(n), timeout_for(n));
        }

        private async void op_unlink(CloudFs.Request r) throws Error {
            var dir = require_dir(r.parent);
            yield listing_tolerant(dir);
            var n = table.child(dir.ino, r.name);
            if (n == null) throw fs_error(Posix.ENOENT);
            if (n.is_dir) throw fs_error(Posix.EISDIR);
            yield remove_node(n);
            r.reply_err(0);
        }

        private async void remove_node(Node n) throws Error {
            yield n.wait_idle();
            if (n.entry != null) {
                try {
                    yield drive.delete(n.entry, cancellable);
                    mark_online();
                } catch (Error e) {
                    if (!(e is AccountsError.NOT_FOUND)) throw e;
                }
            }
            retry.remove(n);
            cache.remove(n.cache_key);
            foreach (var d in table.descendants(n)) if (d.cache_key != "") cache.remove(d.cache_key);
            table.remove(n);
            update_status();
            invalidate_quota();
        }

        private async void op_rmdir(CloudFs.Request r) throws Error {
            var dir = require_dir(r.parent);
            yield ensure_listing(dir);
            var n = table.child(dir.ino, r.name);
            if (n == null) throw fs_error(Posix.ENOENT);
            if (!n.is_dir) throw fs_error(Posix.ENOTDIR);
            yield ensure_listing(n, true);
            if (table.children(n.ino).size > 0) throw fs_error(Posix.ENOTEMPTY);
            yield remove_node(n);
            r.reply_err(0);
        }

        private bool is_inside(Node dir, Node n) {
            Node? cur = dir;
            int guard = 0;
            while (cur != null && guard++ < 4096) {
                if (cur == n) return true;
                if (cur.ino == NodeTable.ROOT) return false;
                cur = table.get(cur.parent);
            }
            return false;
        }

        private async void op_rename(CloudFs.Request r) throws Error {
            if ((r.flags & RENAME_EXCHANGE) != 0) throw fs_error(Posix.EINVAL);
            var dir = require_dir(r.parent);
            var target_dir = require_dir(r.newparent);
            bool moving = dir.ino != target_dir.ino;
            yield ensure_listing(dir);
            if (moving) yield ensure_listing(target_dir);
            var n = table.child(dir.ino, r.name);
            if (n == null) throw fs_error(Posix.ENOENT);
            if (!moving && r.name == r.newname) {
                r.reply_err(0);
                return;
            }
            if (n.is_dir && moving && is_inside(target_dir, n)) throw fs_error(Posix.EINVAL);
            if (Names.is_reserved(r.newname, target_dir.ino == NodeTable.ROOT)) throw fs_error(Posix.EPERM);
            if (moving && target_dir.entry == null) throw fs_error(Posix.EIO);
            var target = table.child(target_dir.ino, r.newname);
            if (target != null && target != n) {
                if ((r.flags & RENAME_NOREPLACE) != 0) throw fs_error(Posix.EEXIST);
                if (target.is_dir != n.is_dir) throw fs_error(n.is_dir ? Posix.ENOTDIR : Posix.EISDIR);
                if (target.is_dir) {
                    yield ensure_listing(target, true);
                    if (table.children(target.ino).size > 0) throw fs_error(Posix.ENOTEMPTY);
                }
                yield remove_node(target);
            }
            yield n.wait_idle();
            if (n.entry == null) {
                table.rename(n, target_dir.ino, r.newname);
                cache.set_dirty(n.cache_key, true, target_dir.entry.id, r.newname);
                r.reply_err(0);
                if (n.dirty && n.open_writers == 0) schedule_upload(n);
                return;
            }
            string old_id = n.entry.id;
            string remote_name = Names.remote_name(r.newname, n.entry);
            CloudEntry updated;
            if (moving) {
                bool renamed = remote_name != Names.remote_name(n.name, n.entry);
                updated = yield drive.move(n.entry, target_dir.entry.id, renamed ? remote_name : null, cancellable);
            } else {
                updated = yield drive.rename(n.entry, remote_name, cancellable);
            }
            mark_online();
            Names.apply_export(updated);
            if (updated.parent_id == "") updated.parent_id = target_dir.entry.id;
            if (updated.id != old_id) {
                if (n.is_dir && is_webdav) {
                    foreach (var d in table.descendants(n)) {
                        if (d.entry != null && d.entry.id.has_prefix(old_id)) d.entry.id = updated.id + d.entry.id.substring(old_id.length);
                        if (d.cache_key.has_prefix(old_id)) d.cache_key = updated.id + d.cache_key.substring(old_id.length);
                    }
                    cache.rekey_prefix(old_id, updated.id);
                } else {
                    cache.rekey(n.cache_key, updated.id);
                }
                n.cache_key = updated.id;
            }
            if (n.dirty) {
                updated.size = n.entry.size;
            } else {
                var rec = cache.lookup(n.cache_key);
                if (rec != null && rec.complete) rec.version = version_of(updated);
            }
            n.entry = updated;
            table.rename(n, target_dir.ino, r.newname);
            r.reply_err(0);
        }

        private void op_statfs(CloudFs.Request r) {
            const uint64 UNKNOWN = 1024ULL * 1024 * 1024 * 1024;
            if (quota_total > 0) {
                int64 free_bytes = int64.max(quota_total - int64.max(quota_used, 0), 0);
                r.reply_statfs((uint64) quota_total, (uint64) free_bytes);
            } else {
                r.reply_statfs(UNKNOWN, UNKNOWN);
            }
            if (quota_at < 0 || get_monotonic_time() - quota_at > 300 * 1000000LL) refresh_quota.begin();
        }

        private string? xattr_value(Node n, string name) {
            if (name == XATTR_OFFLINE) return cache.is_pinned(n.cache_key) ? "1" : "0";
            if (name == XATTR_ACCOUNT) return account.id;
            if (name == XATTR_ENTRY) return n.entry != null ? n.entry.id : null;
            if (name == XATTR_STATE) {
                if (n.is_dir) return "folder";
                if (n.dirty || n.uploading) return "pending";
                return cache.has_content(n.cache_key) ? "cached" : "online";
            }
            return null;
        }

        private void reply_bytes(CloudFs.Request r, uint8[] data) throws Error {
            if (r.size == 0) {
                r.reply_xattr_size(data.length);
            } else if (r.size < data.length) {
                throw fs_error(Posix.ERANGE);
            } else {
                r.reply_buf(data);
            }
        }

        private void op_getxattr(CloudFs.Request r) throws Error {
            var n = require(r.ino);
            string? value = xattr_value(n, r.name);
            if (value == null) throw fs_error(Posix.ENODATA);
            reply_bytes(r, value.data);
        }

        private void op_listxattr(CloudFs.Request r) throws Error {
            require(r.ino);
            reply_bytes(r, new uint8[0]);
        }

        private void op_setxattr(CloudFs.Request r) throws Error {
            var n = require(r.ino);
            if (r.name != XATTR_OFFLINE) throw fs_error(Posix.ENOTSUP);
            string value = r.data != null ? ((string) r.data).substring(0, r.data.length).strip() : "";
            set_keep_offline.begin(n, value == "1" || value == "true");
            r.reply_err(0);
        }

        private void op_removexattr(CloudFs.Request r) throws Error {
            var n = require(r.ino);
            if (r.name != XATTR_OFFLINE) throw fs_error(Posix.ENODATA);
            set_keep_offline.begin(n, false);
            r.reply_err(0);
        }

        public Node? node_for_path(string relative) {
            return table.resolve(relative);
        }

        public async Node? resolve_path(string relative) throws Error {
            Node n = table.root;
            foreach (string part in relative.split("/")) {
                if (part == "" || part == ".") continue;
                yield ensure_listing(n);
                var c = table.child(n.ino, part);
                if (c == null) return null;
                n = c;
            }
            return n;
        }

        public async void set_keep_offline(Node n, bool keep) {
            if (n.cache_key == "") return;
            cache.set_pinned(n.cache_key, keep);
            if (!n.is_dir) {
                if (keep) fetch_in_background(n);
                return;
            }
            try {
                yield ensure_listing(n);
            } catch (Error e) {
                return;
            }
            foreach (var c in table.children(n.ino)) yield set_keep_offline(c, keep);
        }

        private void schedule_upload(Node n) {
            if (n.uploading) {
                n.reupload = true;
                return;
            }
            upload_node.begin(n, false);
        }

        private async bool upload_node(Node n, bool now) {
            if (n.deleted || !n.dirty) return true;
            if (n.open_writers > 0 && !now) return false;
            var parent = table.get(n.parent);
            if (parent == null || parent.entry == null) return false;
            n.uploading = true;
            n.reupload = false;
            transfers++;
            update_status();
            bool ok = false;
            string path = cache.file_path(n.cache_key);
            var meter = begin_meter(-1);
            TransferProgress track = (done, total) => {
                meter.done = done;
                if (total > 0) meter.total = total;
                queue_meters();
            };
            try {
                CloudEntry uploaded;
                if (n.entry == null) {
                    uploaded = yield drive.upload(parent.entry.id, Names.remote_name(n.name, null), File.new_for_path(path), cancellable, track);
                } else {
                    uploaded = yield drive.replace(n.entry, File.new_for_path(path), cancellable, track);
                }
                if (uploaded.parent_id == "") uploaded.parent_id = parent.entry.id;
                if (!n.deleted) {
                    if (uploaded.id != n.cache_key) cache.rekey(n.cache_key, uploaded.id);
                    n.cache_key = uploaded.id;
                    n.entry = uploaded;
                    Posix.Stat st;
                    int64 size = Posix.stat(cache.file_path(n.cache_key), out st) == 0 ? (int64) st.st_size : uploaded.size;
                    cache.commit(n.cache_key, version_of(uploaded), size);
                    if (!n.reupload) {
                        n.dirty = false;
                        cache.set_dirty(n.cache_key, false);
                    }
                    retry.remove(n);
                } else if (uploaded.id != "") {
                    try {
                        yield drive.delete(uploaded, cancellable);
                    } catch (Error e) {
                    }
                }
                ok = true;
                mark_online();
                invalidate_quota();
            } catch (Error e) {
                if (is_network(e)) {
                    mark_offline();
                } else if (e is AccountsError.NOT_FOUND && n.entry != null) {
                    n.entry = null;
                    n.reupload = true;
                } else {
                    warning("%s: upload of %s failed: %s", account.id, table.path_of(n), e.message);
                }
                if (!n.deleted) retry.add(n);
                schedule_retry();
            }
            end_meter(meter);
            n.uploading = false;
            transfers--;
            n.gate.open();
            update_status();
            if (ok && n.reupload && n.dirty && !n.deleted) schedule_upload(n);
            else if (!ok && n.reupload && n.dirty && !n.deleted && online) schedule_upload(n);
            if (ok) evict();
            return ok;
        }

        private void schedule_retry() {
            if (retry_source != 0) return;
            retry_source = Timeout.add_seconds(15, () => {
                retry_source = 0;
                retry_now();
                return Source.REMOVE;
            });
        }

        private void retry_now() {
            var pending = new Gee.ArrayList<Node>();
            pending.add_all(retry);
            retry.clear();
            foreach (var n in pending) if (!n.deleted && n.dirty && !n.uploading && n.open_writers == 0) upload_node.begin(n, false);
            if (!resuming && cache.dirty_records().size > pending.size) resume_dirty.begin();
        }

        private async void resume_dirty() {
            if (resuming) return;
            resuming = true;
            foreach (var rec in cache.dirty_records()) {
                bool attached = false;
                foreach (var n in retry) if (n.cache_key == rec.key) attached = true;
                if (attached || node_by_key(rec.key) != null) continue;
                string path = cache.file_path(rec.key);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) {
                    cache.set_dirty(rec.key, false);
                    continue;
                }
                try {
                    CloudEntry uploaded;
                    if (rec.key.has_prefix("pending:")) {
                        if (rec.remote_parent == "" || rec.remote_name == "") {
                            cache.set_dirty(rec.key, false);
                            continue;
                        }
                        uploaded = yield drive.upload(rec.remote_parent, rec.remote_name, File.new_for_path(path), cancellable);
                    } else {
                        var current = yield drive.stat(rec.key, cancellable);
                        uploaded = yield drive.replace(current, File.new_for_path(path), cancellable);
                    }
                    cache.rekey(rec.key, uploaded.id);
                    Posix.Stat st;
                    Posix.stat(cache.file_path(uploaded.id), out st);
                    cache.commit(uploaded.id, version_of(uploaded), (int64) st.st_size);
                    cache.set_dirty(uploaded.id, false);
                    mark_online();
                    message("%s: uploaded a change saved before the last stop", account.id);
                } catch (Error e) {
                    if (is_network(e)) {
                        mark_offline();
                        schedule_retry();
                        break;
                    }
                    warning("%s: could not upload a saved change: %s", account.id, e.message);
                }
            }
            resuming = false;
            update_status();
        }

        private Node? node_by_key(string key) {
            foreach (var n in table.descendants(table.root)) if (n.cache_key == key) return n;
            return null;
        }

        private void invalidate_quota() {
            quota_at = -1;
        }

        public async void refresh_quota() {
            if (quota_running) return;
            quota_running = true;
            try {
                var http = new HttpClient(account, Capability.FILES);
                string api = account.get_endpoint("files-api") ?? "webdav";
                if (api == "google-drive") {
                    string root = account.get_endpoint("google-drive") ?? "https://www.googleapis.com/drive/v3/";
                    if (!root.has_suffix("/")) root += "/";
                    var o = (yield http.send_ok("GET", root + "about?fields=storageQuota", null, null, null, cancellable)).json_object();
                    if (o.has_member("storageQuota")) {
                        var q = o.get_object_member("storageQuota");
                        quota_used = q.has_member("usage") ? int64.parse(q.get_string_member("usage")) : -1;
                        quota_total = q.has_member("limit") ? int64.parse(q.get_string_member("limit")) : -1;
                    }
                } else if (api == "onedrive") {
                    string root = account.get_endpoint("graph") ?? "https://graph.microsoft.com/v1.0/";
                    if (!root.has_suffix("/")) root += "/";
                    var o = (yield http.send_ok("GET", root + "me/drive", null, null, null, cancellable)).json_object();
                    if (o.has_member("quota")) {
                        var q = o.get_object_member("quota");
                        quota_used = q.has_member("used") ? q.get_int_member("used") : -1;
                        quota_total = q.has_member("total") ? q.get_int_member("total") : -1;
                    }
                } else {
                    string? root = account.get_endpoint("webdav");
                    if (root != null) {
                        var dav = new DavClient(http);
                        var ms = yield dav.propfind(root, "0", """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>""", cancellable);
                        if (ms.responses.size > 0) {
                            string avail = ms.responses[0].text(NS_DAV, "quota-available-bytes");
                            string used = ms.responses[0].text(NS_DAV, "quota-used-bytes");
                            int64 a = avail != "" ? int64.parse(avail) : -1;
                            int64 u = used != "" ? int64.parse(used) : -1;
                            quota_used = u;
                            quota_total = a >= 0 && u >= 0 ? a + u : -1;
                        }
                    }
                }
                quota_at = get_monotonic_time();
                mark_online();
                state_changed();
            } catch (Error e) {
                if (is_network(e)) mark_offline();
                quota_at = get_monotonic_time();
            }
            quota_running = false;
        }
    }

}
