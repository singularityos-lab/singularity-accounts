namespace Singularity.AccountsDaemon {

    public class AccountRecord : Object {
        public string id { get; set; default = ""; }
        public string provider { get; set; default = ""; }
        public string display_name { get; set; default = ""; }
        public string identity { get; set; default = ""; }
        public string server { get; set; default = ""; }
        public string auth { get; set; default = "password"; }
        public string attention { get; set; default = ""; }
        public int64 created { get; set; default = 0; }
        public string[] capabilities { get; set; default = {}; }
        public string[] enabled { get; set; default = {}; }
        public Gee.HashMap<string, string> endpoints = new Gee.HashMap<string, string>();

        public bool has_capability(string cap) {
            return cap in capabilities;
        }

        public string endpoint(string key, string fallback = "") {
            return endpoints.has_key(key) ? endpoints[key] : fallback;
        }

        public void enable_capability(string cap, bool on) {
            string[] result = {};
            foreach (string c in capabilities) {
                bool keep = c == cap ? on : (c in enabled);
                if (keep) result += c;
            }
            enabled = result;
        }

        public HashTable<string, Variant> to_variant(ProviderInfo? info) {
            var t = new HashTable<string, Variant>(str_hash, str_equal);
            t.insert("id", id);
            t.insert("provider", provider);
            t.insert("provider-name", info != null ? info.name : provider);
            t.insert("display-name", display_name != "" ? display_name : identity);
            t.insert("identity", identity);
            t.insert("icon", info != null ? info.icon : "singularity-account-generic");
            t.insert("auth", auth);
            t.insert("attention", attention);
            t.insert("server", server);
            t.insert("created", new Variant.int64(created));
            t.insert("capabilities", capabilities);
            t.insert("enabled", enabled);
            var b = new VariantBuilder(new VariantType("a{ss}"));
            foreach (var e in endpoints.entries) b.add("{ss}", e.key, e.value);
            t.insert("endpoints", b.end());
            return t;
        }

        public Json.Node to_json() {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("id").add_string_value(id);
            b.set_member_name("provider").add_string_value(provider);
            b.set_member_name("display-name").add_string_value(display_name);
            b.set_member_name("identity").add_string_value(identity);
            b.set_member_name("server").add_string_value(server);
            b.set_member_name("auth").add_string_value(auth);
            b.set_member_name("attention").add_string_value(attention);
            b.set_member_name("created").add_int_value(created);
            b.set_member_name("capabilities").begin_array();
            foreach (string c in capabilities) b.add_string_value(c);
            b.end_array();
            b.set_member_name("enabled").begin_array();
            foreach (string c in enabled) b.add_string_value(c);
            b.end_array();
            b.set_member_name("endpoints").begin_object();
            foreach (var e in endpoints.entries) b.set_member_name(e.key).add_string_value(e.value);
            b.end_object();
            b.end_object();
            return b.get_root();
        }

        private static string str(Json.Object o, string key) {
            if (!o.has_member(key)) return "";
            var n = o.get_member(key);
            return n.get_node_type() == Json.NodeType.VALUE && n.get_value().type() == typeof(string) ? n.get_string() : "";
        }

        private static string[] strv(Json.Object o, string key) {
            string[] result = {};
            if (!o.has_member(key) || o.get_member(key).get_node_type() != Json.NodeType.ARRAY) return result;
            foreach (var n in o.get_array_member(key).get_elements()) {
                if (n.get_node_type() == Json.NodeType.VALUE) result += n.get_string();
            }
            return result;
        }

        public static AccountRecord from_json(Json.Object o) {
            var r = new AccountRecord();
            r.id = str(o, "id");
            r.provider = str(o, "provider");
            r.display_name = str(o, "display-name");
            r.identity = str(o, "identity");
            r.server = str(o, "server");
            r.auth = str(o, "auth");
            if (r.auth == "") r.auth = "password";
            r.attention = str(o, "attention");
            r.created = o.has_member("created") ? o.get_int_member("created") : 0;
            r.capabilities = strv(o, "capabilities");
            r.enabled = strv(o, "enabled");
            if (o.has_member("endpoints") && o.get_member("endpoints").get_node_type() == Json.NodeType.OBJECT) {
                var eo = o.get_object_member("endpoints");
                foreach (string k in eo.get_members()) r.endpoints[k] = str(eo, k);
            }
            return r;
        }
    }

    public class AccountStore : Object {
        public Gee.ArrayList<AccountRecord> accounts = new Gee.ArrayList<AccountRecord>();
        public string path { get; construct; }

        public AccountStore(string path) {
            Object(path: path);
            load();
        }

        public static string default_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "accounts", "accounts.json");
        }

        public void load() {
            accounts.clear();
            if (!FileUtils.test(path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (!o.has_member("accounts")) return;
                foreach (var n in o.get_array_member("accounts").get_elements()) {
                    if (n.get_node_type() != Json.NodeType.OBJECT) continue;
                    var r = AccountRecord.from_json(n.get_object());
                    if (r.id != "" && r.provider != "") accounts.add(r);
                }
            } catch (Error e) {
                warning("cannot read %s: %s", path, e.message);
            }
        }

        public void save() throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version").add_int_value(1);
            b.set_member_name("accounts").begin_array();
            foreach (var r in accounts) b.add_value(r.to_json());
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(b.get_root());
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            FileUtils.set_contents_full(path, gen.to_data(null), -1, FileSetContentsFlags.CONSISTENT, 0600);
        }

        public AccountRecord? find(string id) {
            foreach (var r in accounts) if (r.id == id) return r;
            return null;
        }

        public AccountRecord? find_identity(string provider, string identity, string server) {
            foreach (var r in accounts) {
                if (r.provider == provider && r.identity.down() == identity.down() && r.server == server) return r;
            }
            return null;
        }

        public string new_id() {
            while (true) {
                string id = Uuid.string_random().replace("-", "").substring(0, 12);
                if (find(id) == null) return id;
            }
        }
    }
}
