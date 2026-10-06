using Singularity.Accounts;

namespace Singularity.CloudMount {

    public class Gate : Object {
        private class Waiter {
            public SourceFunc callback;

            public Waiter(owned SourceFunc callback) {
                this.callback = (owned) callback;
            }
        }

        private Gee.ArrayList<Waiter> waiters = new Gee.ArrayList<Waiter>();

        public async void wait() {
            waiters.add(new Waiter(wait.callback));
            yield;
        }

        public void open() {
            var ready = waiters;
            waiters = new Gee.ArrayList<Waiter>();
            foreach (var w in ready) Idle.add((owned) w.callback);
        }
    }

    public class Node : Object {
        public uint64 ino { get; construct; }
        public uint64 parent { get; set; }
        public string name { get; set; }
        public bool is_dir { get; construct; }
        public CloudEntry? entry { get; set; }
        public string cache_key { get; set; default = ""; }
        public int64 local_mtime { get; set; default = 0; }

        public bool dirty;
        public bool uploading;
        public bool reupload;
        public bool deleted;
        public int open_count;
        public int open_writers;
        public int64 listed_at = -1;
        public bool listing;
        public Error? list_error;
        public Gate gate = new Gate();

        public Node(uint64 ino, uint64 parent, string name, bool is_dir, CloudEntry? entry) {
            Object(ino: ino, is_dir: is_dir);
            this.parent = parent;
            this.name = name;
            this.entry = entry;
        }

        public bool is_export {
            get { return entry != null && entry.export_type != ""; }
        }

        public bool keeps_local_state {
            get { return entry == null || dirty || uploading || open_count > 0; }
        }

        public async void wait_idle() {
            while (uploading || listing) yield gate.wait();
        }
    }

    public class NodeTable : Object {
        public const uint64 ROOT = 1;

        private Gee.HashMap<string, Node> by_ino = new Gee.HashMap<string, Node>();
        private Gee.HashMap<string, Node> by_name = new Gee.HashMap<string, Node>();
        private Gee.HashMap<string, Gee.TreeSet<string>> children_of = new Gee.HashMap<string, Gee.TreeSet<string>>();
        private uint64 next_ino = 2;

        public Node root { get; private set; }

        public NodeTable(CloudEntry root_entry) {
            root = new Node(ROOT, ROOT, "", true, root_entry);
            by_ino[key(ROOT)] = root;
        }

        private static string key(uint64 ino) {
            return ino.to_string();
        }

        private static string child_key(uint64 parent, string name) {
            return parent.to_string() + "/" + name;
        }

        public int size {
            get { return by_ino.size; }
        }

        public new Node? get(uint64 ino) {
            return by_ino[key(ino)];
        }

        public Node? child(uint64 parent, string name) {
            return by_name[child_key(parent, name)];
        }

        public Gee.List<Node> children(uint64 parent) {
            var result = new Gee.ArrayList<Node>();
            var names = children_of[key(parent)];
            if (names == null) return result;
            foreach (string n in names) {
                var node = by_name[child_key(parent, n)];
                if (node != null) result.add(node);
            }
            return result;
        }

        public Node add(uint64 parent, string name, bool is_dir, CloudEntry? entry) {
            var existing = child(parent, name);
            if (existing != null) remove(existing);
            var node = new Node(next_ino++, parent, name, is_dir, entry);
            by_ino[key(node.ino)] = node;
            link(node);
            return node;
        }

        private void link(Node node) {
            by_name[child_key(node.parent, node.name)] = node;
            var set = children_of[key(node.parent)];
            if (set == null) {
                set = new Gee.TreeSet<string>();
                children_of[key(node.parent)] = set;
            }
            set.add(node.name);
        }

        private void unlink(Node node) {
            by_name.unset(child_key(node.parent, node.name));
            var set = children_of[key(node.parent)];
            if (set != null) set.remove(node.name);
        }

        public void rename(Node node, uint64 new_parent, string new_name) {
            if (node.ino == ROOT) return;
            var target = child(new_parent, new_name);
            if (target != null && target != node) remove(target);
            unlink(node);
            node.parent = new_parent;
            node.name = new_name;
            link(node);
        }

        public void remove(Node node) {
            if (node.ino == ROOT) return;
            foreach (var c in children(node.ino)) remove(c);
            unlink(node);
            children_of.unset(key(node.ino));
            by_ino.unset(key(node.ino));
            node.deleted = true;
        }

        public string path_of(Node node) {
            var parts = new Gee.ArrayList<string>();
            Node? n = node;
            int guard = 0;
            while (n != null && n.ino != ROOT && guard++ < 4096) {
                parts.insert(0, n.name);
                n = get(n.parent);
            }
            return "/" + string.joinv("/", parts.to_array());
        }

        public Node? resolve(string path) {
            Node? n = root;
            foreach (string part in path.split("/")) {
                if (part == "" || part == ".") continue;
                if (n == null || !n.is_dir) return null;
                n = part == ".." ? get(n.parent) : child(n.ino, part);
            }
            return n;
        }

        public Gee.List<Node> descendants(Node node) {
            var result = new Gee.ArrayList<Node>();
            foreach (var c in children(node.ino)) {
                result.add(c);
                if (c.is_dir) result.add_all(descendants(c));
            }
            return result;
        }
    }
}
