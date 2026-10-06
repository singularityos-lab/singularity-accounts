using Singularity.Accounts;

namespace Singularity.CloudMount {

    [DBus (name = "dev.sinty.CloudMount.Error")]
    public errordomain MountError {
        NOT_FOUND,
        NOT_SUPPORTED,
        FAILED
    }

    public class MountedDrive : Object {
        public Account account { get; construct; }
        public DriveFs fs { get; construct; }
        public string link { get; set; default = ""; }

        public MountedDrive(Account account, DriveFs fs) {
            Object(account: account, fs: fs);
        }
    }

    public class Controller : Object {
        public string runtime_base { get; construct; }
        public string link_base { get; construct; }
        public string cache_base { get; construct; }

        public signal void changed();

        private Manager manager;
        private MountConfig config;
        private Gee.HashMap<string, MountedDrive> mounts = new Gee.HashMap<string, MountedDrive>();
        private Gee.HashSet<string> ejected = new Gee.HashSet<string>();
        private bool stopping;

        public Controller() {
            Object(
                runtime_base: Path.build_filename(Environment.get_user_runtime_dir(), "singularity", "cloud"),
                link_base: Path.build_filename(Environment.get_home_dir(), "Cloud"),
                cache_base: Path.build_filename(Environment.get_user_cache_dir(), "singularity", "cloud")
            );
            config = MountConfig.load();
            manager = Manager.get_default();
        }

        public async void start() {
            cleanup_stale();
            yield manager.load();
            manager.account_added.connect(() => sync());
            manager.account_changed.connect((account) => {
                var m = mounts[account.id];
                if (m != null) {
                    m.fs.account_updated();
                    update_link(m);
                }
                sync();
            });
            manager.needs_attention.connect((account) => {
                var m = mounts[account.id];
                if (m != null) m.fs.account_updated();
                changed();
            });
            manager.account_removed.connect((account) => {
                ejected.remove(account.id);
                unmount_account(account.id, true);
            });
            manager.reloaded.connect(() => sync());
            sync();
        }

        private static bool wanted(Account account) {
            return account.has_capability(Capability.FILES) && CloudDrive.for_account(account) != null;
        }

        public void sync() {
            if (stopping) return;
            var seen = new Gee.HashSet<string>();
            foreach (var account in manager.get_accounts()) {
                seen.add(account.id);
                bool want = wanted(account) && !ejected.contains(account.id);
                if (want && !mounts.has_key(account.id)) mount_account(account);
                else if (!want && mounts.has_key(account.id)) unmount_account(account.id, false);
            }
            foreach (string id in mounts.keys.to_array()) if (!seen.contains(id)) unmount_account(id, true);
        }

        private static bool is_mounted(string path) {
            string mounts_text;
            try {
                FileUtils.get_contents("/proc/self/mounts", out mounts_text);
            } catch (Error e) {
                return false;
            }
            foreach (string line in mounts_text.split("\n")) {
                var fields = line.split(" ");
                if (fields.length > 1 && fields[1].compress() == path) return true;
            }
            return false;
        }

        public void cleanup_stale() {
            string mounts_text = "";
            try {
                FileUtils.get_contents("/proc/self/mounts", out mounts_text);
            } catch (Error e) {
            }
            foreach (string line in mounts_text.split("\n")) {
                var fields = line.split(" ");
                if (fields.length < 3) continue;
                string point = fields[1].compress();
                if (point.has_prefix(runtime_base + "/") && fields[2].has_prefix("fuse")) {
                    if (CloudFs.unmount(point)) message("removed a stale mount at %s", point);
                    else warning("could not remove the stale mount at %s", point);
                }
            }
            try {
                var dir = Dir.open(link_base);
                string? name;
                while ((name = dir.read_name()) != null) {
                    string path = Path.build_filename(link_base, name);
                    if (!FileUtils.test(path, FileTest.IS_SYMLINK)) continue;
                    string target = FileUtils.read_link(path);
                    if (target.has_prefix(runtime_base + "/")) FileUtils.unlink(path);
                }
            } catch (Error e) {
            }
            Bookmarks.prune(link_base);
        }

        private string link_name_for(Account account, string? own_link) {
            string base_name = Names.sanitize(account.display_name);
            string name = base_name;
            int n = 2;
            while (true) {
                string path = Path.build_filename(link_base, name);
                bool taken = false;
                foreach (var m in mounts.values) if (m.link == path && m.link != own_link) taken = true;
                if (!taken && (path == own_link || !FileUtils.test(path, FileTest.EXISTS | FileTest.IS_SYMLINK))) return path;
                name = n == 2 ? "%s (%s)".printf(base_name, account.provider_name) : "%s (%d)".printf(base_name, n);
                n++;
                if (n > 50) return Path.build_filename(link_base, account.id);
            }
        }

        private void mount_account(Account account) {
            var drive = CloudDrive.for_account(account);
            if (drive == null) return;
            string point = Path.build_filename(runtime_base, account.id);
            DirUtils.create_with_parents(point, 0700);
            if (is_mounted(point)) CloudFs.unmount(point);
            var fs = new DriveFs(account, drive, point, Path.build_filename(cache_base, account.id), config);
            try {
                fs.start();
            } catch (Error e) {
                warning("cannot mount %s: %s", account.id, e.message);
                return;
            }
            var m = new MountedDrive(account, fs);
            mounts[account.id] = m;
            fs.state_changed.connect(() => changed());
            fs.closed.connect(() => {
                if (stopping || !mounts.has_key(account.id)) return;
                message("%s was unmounted from outside", account.id);
                ejected.add(account.id);
                unmount_account(account.id, false);
            });
            update_link(m);
            message("mounted %s at %s", account.id, point);
            changed();
        }

        private void update_link(MountedDrive m) {
            string wanted_link = link_name_for(m.account, m.link != "" ? m.link : null);
            if (wanted_link == m.link) return;
            DirUtils.create_with_parents(link_base, 0755);
            if (m.link != "") {
                Bookmarks.remove(m.link);
                FileUtils.unlink(m.link);
            }
            if (FileUtils.symlink(m.fs.mountpoint, wanted_link) != 0) {
                warning("cannot create %s", wanted_link);
                m.link = "";
                return;
            }
            m.link = wanted_link;
            Bookmarks.add(wanted_link, Path.get_basename(wanted_link));
            changed();
        }

        private void unmount_account(string id, bool forget) {
            var m = mounts[id];
            if (m != null) {
                mounts.unset(id);
                m.fs.stop();
                if (m.link != "") {
                    Bookmarks.remove(m.link);
                    FileUtils.unlink(m.link);
                }
                DirUtils.remove(m.fs.mountpoint);
                message("unmounted %s", id);
            }
            if (forget) remove_tree(Path.build_filename(cache_base, id));
            if (mounts.size == 0) DirUtils.remove(link_base);
            changed();
        }

        private static void remove_tree(string path) {
            if (!FileUtils.test(path, FileTest.IS_DIR) || FileUtils.test(path, FileTest.IS_SYMLINK)) {
                FileUtils.remove(path);
                return;
            }
            try {
                var dir = Dir.open(path);
                string? name;
                while ((name = dir.read_name()) != null) remove_tree(Path.build_filename(path, name));
            } catch (Error e) {
            }
            DirUtils.remove(path);
        }

        public void stop_all() {
            stopping = true;
            foreach (string id in mounts.keys.to_array()) unmount_account(id, false);
        }

        public async void mount(string account_id) throws MountError {
            var account = manager.get_account(account_id);
            if (account == null) throw new MountError.NOT_FOUND("No account %s".printf(account_id));
            if (!wanted(account)) throw new MountError.NOT_SUPPORTED("The account has no files switched on");
            ejected.remove(account_id);
            if (!mounts.has_key(account_id)) mount_account(account);
            if (!mounts.has_key(account_id)) throw new MountError.FAILED("Could not mount %s".printf(account.display_name));
        }

        public void unmount(string account_id) throws MountError {
            if (!mounts.has_key(account_id)) throw new MountError.NOT_FOUND("%s is not mounted".printf(account_id));
            ejected.add(account_id);
            unmount_account(account_id, false);
        }

        private MountedDrive? drive_for_path(string path, out string relative) {
            relative = "";
            foreach (var m in mounts.values) {
                foreach (string root in new string[] { m.link, m.fs.mountpoint }) {
                    if (root == "") continue;
                    if (path == root) return m;
                    if (path.has_prefix(root + "/")) {
                        relative = path.substring(root.length);
                        return m;
                    }
                }
            }
            return null;
        }

        public async void set_keep_offline(string[] paths, bool keep) throws MountError {
            foreach (string path in paths) {
                string relative;
                var m = drive_for_path(path, out relative);
                if (m == null) throw new MountError.NOT_FOUND("%s is not in an online account".printf(path));
                Node? node = null;
                try {
                    node = yield m.fs.resolve_path(relative);
                } catch (Error e) {
                    throw new MountError.FAILED(e.message);
                }
                if (node == null) throw new MountError.NOT_FOUND("%s was not found".printf(path));
                m.fs.set_keep_offline.begin(node, keep);
            }
        }

        public async string get_link(string path) throws MountError {
            string relative;
            var m = drive_for_path(path, out relative);
            if (m == null) throw new MountError.NOT_FOUND("%s is not in an online account".printf(path));
            var sharing = LinkSharing.for_account(m.account);
            if (sharing == null) throw new MountError.NOT_SUPPORTED("Sharing links are not available for %s".printf(m.account.provider_name));
            Node? node = null;
            try {
                node = yield m.fs.resolve_path(relative);
            } catch (Error e) {
                throw new MountError.FAILED(e.message);
            }
            if (node == null) throw new MountError.NOT_FOUND("%s was not found".printf(path));
            if (node.entry == null) throw new MountError.FAILED("%s is not uploaded yet".printf(path));
            try {
                var link = yield sharing.create_link(node.entry, LinkAccess.VIEW);
                return link.url;
            } catch (Error e) {
                throw new MountError.FAILED(e.message);
            }
        }

        public HashTable<string, Variant>[] describe() {
            HashTable<string, Variant>[] result = {};
            foreach (var account in manager.get_accounts()) {
                var m = mounts[account.id];
                if (m == null) continue;
                var d = new HashTable<string, Variant>(str_hash, str_equal);
                d["account-id"] = account.id;
                d["name"] = account.display_name;
                d["path"] = m.link != "" ? m.link : m.fs.mountpoint;
                d["mountpoint"] = m.fs.mountpoint;
                d["provider"] = account.provider;
                d["provider-name"] = account.provider_name;
                d["icon"] = account.icon_name;
                d["status"] = m.fs.status;
                d["pending"] = (uint32) m.fs.pending_uploads;
                d["transferred"] = m.fs.transferred;
                d["transfer-size"] = m.fs.transfer_size;
                d["used"] = m.fs.quota_used;
                d["total"] = m.fs.quota_total;
                d["can-share"] = LinkSharing.for_account(account) != null;
                result += d;
            }
            return result;
        }
    }

    [DBus (name = "dev.sinty.CloudMount")]
    public class Service : Object {
        private Controller controller;

        public signal void mounts_changed();

        public Service(Controller controller) {
            this.controller = controller;
            controller.changed.connect(() => mounts_changed());
        }

        public HashTable<string, Variant>[] list_mounts() throws DBusError, IOError {
            return controller.describe();
        }

        public async void mount(string account_id) throws MountError, DBusError, IOError {
            yield controller.mount(account_id);
        }

        public void unmount(string account_id) throws MountError, DBusError, IOError {
            controller.unmount(account_id);
        }

        public async void set_keep_offline(string[] paths, bool keep) throws MountError, DBusError, IOError {
            yield controller.set_keep_offline(paths, keep);
        }

        public async string get_link(string path) throws MountError, DBusError, IOError {
            return yield controller.get_link(path);
        }
    }

    public class Bookmarks : Object {
        public static string file_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "gtk-3.0", "bookmarks");
        }

        private static string[] read_lines() {
            string? text = null;
            try {
                FileUtils.get_contents(file_path(), out text);
            } catch (Error e) {
                text = null;
            }
            string[] lines = {};
            if (text == null) return lines;
            foreach (string line in text.split("\n")) if (line.strip() != "") lines += line;
            return lines;
        }

        private static void write_lines(string[] lines) {
            DirUtils.create_with_parents(Path.get_dirname(file_path()), 0700);
            string data = lines.length > 0 ? string.joinv("\n", lines) + "\n" : "";
            try {
                FileUtils.set_contents(file_path(), data);
            } catch (Error e) {
                warning("cannot update the bookmarks: %s", e.message);
            }
        }

        private static string? path_of(string line) {
            string uri = line.split(" ", 2)[0];
            try {
                return Filename.from_uri(uri);
            } catch (Error e) {
                return null;
            }
        }

        public static void add(string path, string label) {
            string[] lines = read_lines();
            foreach (string line in lines) if (path_of(line) == path) return;
            try {
                lines += "%s %s".printf(Filename.to_uri(path), label);
            } catch (Error e) {
                return;
            }
            write_lines(lines);
        }

        public static void remove(string path) {
            string[] kept = {};
            bool changed = false;
            foreach (string line in read_lines()) {
                if (path_of(line) == path) changed = true;
                else kept += line;
            }
            if (changed) write_lines(kept);
        }

        public static void prune(string link_base) {
            string[] kept = {};
            bool changed = false;
            foreach (string line in read_lines()) {
                string? p = path_of(line);
                if (p != null && Path.get_dirname(p) == link_base && !FileUtils.test(p, FileTest.EXISTS)) changed = true;
                else kept += line;
            }
            if (changed) write_lines(kept);
        }
    }
}
