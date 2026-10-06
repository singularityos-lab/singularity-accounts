using Singularity.Accounts;

namespace Singularity.CloudMount {

    public class CacheRecord : Object {
        public string key { get; set; default = ""; }
        public string version { get; set; default = ""; }
        public int64 size { get; set; default = 0; }
        public int64 used { get; set; default = 0; }
        public bool complete { get; set; default = false; }
        public bool pinned { get; set; default = false; }
        public bool dirty { get; set; default = false; }
        public string remote_parent { get; set; default = ""; }
        public string remote_name { get; set; default = ""; }
    }

    public class ContentCache : Object {
        public string root { get; construct; }
        public uint64 limit { get; set; }

        private Gee.HashMap<string, CacheRecord> records = new Gee.HashMap<string, CacheRecord>();
        private Gee.HashMap<string, Json.Node> listings = new Gee.HashMap<string, Json.Node>();
        private int64 clock = 0;
        private uint save_source = 0;

        public ContentCache(string root, uint64 limit) {
            Object(root: root);
            this.limit = limit;
            DirUtils.create_with_parents(Path.build_filename(root, "data"), 0700);
            load();
        }

        private string index_path() {
            return Path.build_filename(root, "index.json");
        }

        private string listings_path() {
            return Path.build_filename(root, "listings.json");
        }

        public string file_path(string key) {
            string sum = Checksum.compute_for_string(ChecksumType.SHA256, key);
            return Path.build_filename(root, "data", sum.substring(0, 2), sum);
        }

        public string prepare_path(string key) {
            string path = file_path(key);
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            return path;
        }

        public bool has_content(string key) {
            var r = records[key];
            return r != null && r.complete && FileUtils.test(file_path(key), FileTest.IS_REGULAR);
        }

        public CacheRecord? lookup(string key) {
            return records[key];
        }

        public CacheRecord ensure(string key) {
            var r = records[key];
            if (r == null) {
                r = new CacheRecord();
                r.key = key;
                records[key] = r;
            }
            return r;
        }

        private int64 tick() {
            clock = int64.max(get_real_time(), clock + 1);
            return clock;
        }

        public void touch(string key) {
            var r = records[key];
            if (r == null) return;
            r.used = tick();
            save_soon();
        }

        public void commit(string key, string version, int64 size) {
            var r = ensure(key);
            r.version = version;
            r.size = size;
            r.complete = true;
            r.used = tick();
            save_soon();
        }

        public void set_pinned(string key, bool pinned) {
            var r = ensure(key);
            r.pinned = pinned;
            save_soon();
        }

        public bool is_pinned(string key) {
            var r = records[key];
            return r != null && r.pinned;
        }

        public void set_dirty(string key, bool dirty, string remote_parent = "", string remote_name = "") {
            var r = ensure(key);
            r.dirty = dirty;
            if (dirty) {
                r.complete = true;
                if (remote_parent != "") r.remote_parent = remote_parent;
                if (remote_name != "") r.remote_name = remote_name;
                r.used = tick();
            }
            save();
        }

        public Gee.List<CacheRecord> dirty_records() {
            var result = new Gee.ArrayList<CacheRecord>();
            foreach (var r in records.values) if (r.dirty) result.add(r);
            return result;
        }

        public void rekey(string old_key, string new_key) {
            if (old_key == new_key) return;
            var r = records[old_key];
            string old_path = file_path(old_key);
            if (FileUtils.test(old_path, FileTest.EXISTS)) {
                string new_path = prepare_path(new_key);
                FileUtils.rename(old_path, new_path);
            }
            records.unset(old_key);
            if (r != null) {
                r.key = new_key;
                records[new_key] = r;
            }
            var l = listings[old_key];
            if (l != null) {
                listings.unset(old_key);
                listings[new_key] = l;
            }
            save_soon();
        }

        public void rekey_prefix(string old_prefix, string new_prefix) {
            var keys = new Gee.ArrayList<string>();
            foreach (string k in records.keys) if (k.has_prefix(old_prefix)) keys.add(k);
            foreach (string k in listings.keys) if (k.has_prefix(old_prefix) && !keys.contains(k)) keys.add(k);
            foreach (string k in keys) rekey(k, new_prefix + k.substring(old_prefix.length));
        }

        public void remove(string key) {
            FileUtils.remove(file_path(key));
            records.unset(key);
            listings.unset(key);
            save_soon();
        }

        public uint64 total_size() {
            uint64 total = 0;
            foreach (var r in records.values) if (r.complete && r.size > 0) total += (uint64) r.size;
            return total;
        }

        public delegate bool KeyFilter(string key);

        public Gee.List<string> evict(KeyFilter? in_use = null) {
            var evicted = new Gee.ArrayList<string>();
            uint64 total = total_size();
            if (total <= limit) return evicted;
            var candidates = new Gee.ArrayList<CacheRecord>();
            foreach (var r in records.values) {
                if (!r.complete || r.pinned || r.dirty) continue;
                if (in_use != null && in_use(r.key)) continue;
                candidates.add(r);
            }
            candidates.sort((a, b) => a.used < b.used ? -1 : (a.used > b.used ? 1 : 0));
            foreach (var r in candidates) {
                if (total <= limit) break;
                total -= (uint64) int64.max(r.size, 0);
                FileUtils.remove(file_path(r.key));
                records.unset(r.key);
                evicted.add(r.key);
            }
            if (evicted.size > 0) save_soon();
            return evicted;
        }

        public void store_listing(string dir_key, Gee.List<CloudEntry> entries) {
            var array = new Json.Array();
            foreach (var e in entries) array.add_object_element(entry_to_json(e));
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(array);
            listings[dir_key] = node;
            save_soon();
        }

        public Gee.List<CloudEntry>? load_listing(string dir_key) {
            var node = listings[dir_key];
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) return null;
            var result = new Gee.ArrayList<CloudEntry>();
            foreach (var el in node.get_array().get_elements()) {
                if (el.get_node_type() == Json.NodeType.OBJECT) result.add(entry_from_json(el.get_object()));
            }
            return result;
        }

        public static Json.Object entry_to_json(CloudEntry e) {
            var o = new Json.Object();
            o.set_string_member("id", e.id);
            o.set_string_member("parent", e.parent_id);
            o.set_string_member("name", e.name);
            o.set_boolean_member("folder", e.is_folder);
            o.set_int_member("size", e.size);
            if (e.modified != null) o.set_int_member("modified", e.modified.to_unix());
            o.set_string_member("type", e.content_type);
            o.set_string_member("etag", e.etag);
            o.set_string_member("export", e.export_type);
            return o;
        }

        private static string str(Json.Object o, string member) {
            return o.has_member(member) ? o.get_string_member(member) : "";
        }

        public static CloudEntry entry_from_json(Json.Object o) {
            var e = new CloudEntry();
            e.id = str(o, "id");
            e.parent_id = str(o, "parent");
            e.name = str(o, "name");
            e.is_folder = o.has_member("folder") && o.get_boolean_member("folder");
            e.size = o.has_member("size") ? o.get_int_member("size") : -1;
            if (o.has_member("modified")) e.modified = new DateTime.from_unix_utc(o.get_int_member("modified"));
            e.content_type = str(o, "type");
            e.etag = str(o, "etag");
            e.export_type = str(o, "export");
            return e;
        }

        private void load() {
            try {
                var parser = new Json.Parser();
                parser.load_from_file(index_path());
                var root_node = parser.get_root();
                if (root_node != null && root_node.get_node_type() == Json.NodeType.OBJECT) {
                    var o = root_node.get_object();
                    if (o.has_member("records")) {
                        foreach (var el in o.get_array_member("records").get_elements()) {
                            var r = (CacheRecord) Json.gobject_deserialize(typeof(CacheRecord), el);
                            if (r.key == "") continue;
                            records[r.key] = r;
                            clock = int64.max(clock, r.used);
                        }
                    }
                }
            } catch (Error e) {
            }
            try {
                var parser = new Json.Parser();
                parser.load_from_file(listings_path());
                var root_node = parser.get_root();
                if (root_node != null && root_node.get_node_type() == Json.NodeType.OBJECT) {
                    var o = root_node.get_object();
                    foreach (string member in o.get_members()) listings[member] = o.get_member(member).copy();
                }
            } catch (Error e) {
            }
        }

        private void save_soon() {
            if (save_source != 0) return;
            save_source = Timeout.add(500, () => {
                save_source = 0;
                save();
                return Source.REMOVE;
            });
        }

        private static void write_atomic(string path, string data) throws Error {
            string tmp = path + ".tmp";
            FileUtils.set_contents_full(tmp, data, -1, FileSetContentsFlags.NONE, 0600);
            if (FileUtils.rename(tmp, path) != 0) throw new IOError.FAILED("rename %s", path);
        }

        public void save() {
            if (save_source != 0) {
                Source.remove(save_source);
                save_source = 0;
            }
            var array = new Json.Array();
            foreach (var r in records.values) array.add_element(Json.gobject_serialize(r));
            var o = new Json.Object();
            o.set_int_member("version", 1);
            o.set_array_member("records", array);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            var gen = new Json.Generator();
            gen.set_root(node);
            var lo = new Json.Object();
            foreach (var entry in listings.entries) lo.set_member(entry.key, entry.value.copy());
            var lnode = new Json.Node(Json.NodeType.OBJECT);
            lnode.set_object(lo);
            var lgen = new Json.Generator();
            lgen.set_root(lnode);
            try {
                write_atomic(index_path(), gen.to_data(null));
                write_atomic(listings_path(), lgen.to_data(null));
            } catch (Error e) {
                warning("cloud cache: cannot save the index: %s", e.message);
            }
        }
    }
}
