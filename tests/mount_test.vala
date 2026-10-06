using Singularity.Accounts;
using Singularity.CloudMount;

void check(bool ok, string label) {
    if (!ok) {
        stderr.printf("FAILED: %s\n", label);
        assert_not_reached();
    }
}

CloudEntry entry(string id, string name, bool folder = false, string export_type = "") {
    var e = new CloudEntry();
    e.id = id;
    e.name = name;
    e.is_folder = folder;
    e.export_type = export_type;
    e.content_type = export_type;
    return e;
}

string[] scratch_dirs;

string scratch_dir() {
    try {
        string dir = DirUtils.make_tmp("cloud-mount-test-XXXXXX");
        scratch_dirs += dir;
        return dir;
    } catch (Error e) {
        assert_not_reached();
    }
}

void remove_tree(string path) {
    if (FileUtils.test(path, FileTest.IS_DIR) && !FileUtils.test(path, FileTest.IS_SYMLINK)) {
        try {
            var dir = Dir.open(path);
            string? name;
            while ((name = dir.read_name()) != null) remove_tree(Path.build_filename(path, name));
        } catch (FileError e) {
        }
        DirUtils.remove(path);
    } else {
        FileUtils.unlink(path);
    }
}

void write_file(string path, string text) {
    try {
        FileUtils.set_contents(path, text);
    } catch (Error e) {
        assert_not_reached();
    }
}

void test_sanitize() {
    check(Names.sanitize("a/b") == "a_b", "slash replaced");
    check(Names.sanitize("") == "_", "empty name");
    check(Names.sanitize(".") == "_.", "dot");
    check(Names.sanitize("..") == "_..", "dot dot");
    check(Names.sanitize("tab\there") == "tab_here", "control characters");
    check(Names.sanitize("Città ok.txt") == "Città ok.txt", "unicode kept");
    string longname = string.nfill(300, 'x');
    check(Names.sanitize(longname).length == 255, "long names cut to 255 bytes");
}

void test_numbered() {
    check(Names.numbered("Report.odt", 2, false) == "Report (2).odt", "file keeps extension");
    check(Names.numbered("Photos.2024", 3, true) == "Photos.2024 (3)", "folder has no extension");
    check(Names.numbered("README", 2, false) == "README (2)", "no extension");
    check(Names.numbered(".hidden", 2, false) == ".hidden (2)", "dot file");
}

void test_assign_duplicates() {
    var list = new Gee.ArrayList<CloudEntry>();
    list.add(entry("id-b", "Report.odt"));
    list.add(entry("id-a", "Report.odt"));
    list.add(entry("id-c", "Report (2).odt"));
    list.add(entry("id-d", "a/b.txt"));
    var named = Names.assign(list);
    var by_id = new Gee.HashMap<string, string>();
    foreach (var n in named) by_id[n.entry.id] = n.name;
    check(by_id["id-a"] == "Report.odt", "lowest id keeps the name");
    check(by_id["id-c"] == "Report (2).odt", "real name wins over a generated one");
    check(by_id["id-b"] == "Report (3).odt", "duplicate gets the next free number");
    check(by_id["id-d"] == "a_b.txt", "sanitized");
    list.clear();
    list.add(entry("id-a", "Report.odt"));
    list.add(entry("id-c", "Report (2).odt"));
    list.add(entry("id-d", "a/b.txt"));
    list.add(entry("id-b", "Report.odt"));
    var again = Names.assign(list);
    foreach (var n in again) check(by_id[n.entry.id] == n.name, "stable across listing order: " + n.name);
}

void test_google_exports() {
    var doc = entry("g1", "Plan.odt", false, "application/vnd.oasis.opendocument.text");
    Names.apply_export(doc);
    check(doc.name == "Plan.docx", "document becomes docx");
    check(doc.export_type == Names.DOCX && doc.content_type == Names.DOCX, "docx type");
    var sheet = entry("g2", "Budget.ods", false, "application/vnd.oasis.opendocument.spreadsheet");
    Names.apply_export(sheet);
    check(sheet.name == "Budget.xlsx", "spreadsheet becomes xlsx");
    var slides = entry("g3", "Deck.odp", false, "application/vnd.oasis.opendocument.presentation");
    Names.apply_export(slides);
    check(slides.name == "Deck.pptx", "presentation becomes pptx");
    var drawing = entry("g4", "Sketch.svg", false, "image/svg+xml");
    Names.apply_export(drawing);
    check(drawing.name == "Sketch.svg", "drawings stay svg");
    var plain = entry("f1", "notes.odt");
    Names.apply_export(plain);
    check(plain.name == "notes.odt", "ordinary files untouched");
    check(Names.remote_name("Plan v2.docx", doc) == "Plan v2", "rename strips the export extension");
    check(Names.remote_name("Plan v2", doc) == "Plan v2", "rename without extension");
    check(Names.remote_name("x.docx", plain) == "x.docx", "ordinary rename untouched");
    check(Names.is_reserved(".Trash-1000", true) && !Names.is_reserved(".Trash-1000", false), "trash folders refused at the top only");
}

void test_node_table() {
    var t = new NodeTable(entry("root", "Drive", true));
    var docs = t.add(NodeTable.ROOT, "Documents", true, entry("d1", "Documents", true));
    var report = t.add(docs.ino, "Report.odt", false, entry("f1", "Report.odt"));
    check(t.child(NodeTable.ROOT, "Documents") == docs, "lookup by name");
    check(t.get(report.ino) == report, "lookup by inode");
    check(t.path_of(report) == "/Documents/Report.odt", "path of a file");
    check(t.resolve("/Documents/Report.odt") == report, "resolve a path");
    check(t.resolve("Documents/../Documents/Report.odt") == report, "resolve with dot dot");
    check(t.resolve("/Documents/missing") == null, "missing path");
    check(report.ino != docs.ino && docs.ino != NodeTable.ROOT, "unique inodes");
    t.rename(report, docs.ino, "Final.odt");
    check(t.child(docs.ino, "Report.odt") == null && t.child(docs.ino, "Final.odt") == report, "rename");
    check(t.path_of(report) == "/Documents/Final.odt", "path after rename");
    var other = t.add(docs.ino, "Other.odt", false, null);
    t.rename(other, docs.ino, "Final.odt");
    check(report.deleted && t.child(docs.ino, "Final.odt") == other, "rename over replaces the target");
    var sub = t.add(docs.ino, "Sub", true, entry("d2", "Sub", true));
    var deep = t.add(sub.ino, "deep.txt", false, entry("f2", "deep.txt"));
    check(t.descendants(docs).size == 3, "descendants");
    var names = new Gee.ArrayList<string>();
    foreach (var c in t.children(docs.ino)) names.add(c.name);
    check(names.size == 2 && names[0] == "Final.odt" && names[1] == "Sub", "children sorted");
    t.remove(docs);
    check(t.get(deep.ino) == null && t.get(sub.ino) == null && t.child(NodeTable.ROOT, "Documents") == null, "remove is recursive");
    check(t.size == 1, "only the root is left");
}

void test_cache_basics() {
    string dir = scratch_dir();
    var c = new ContentCache(dir, 1000);
    string p = c.prepare_path("file-1");
    check(p.has_prefix(dir + "/data/"), "content under data");
    check(!c.has_content("file-1"), "nothing yet");
    write_file(p, "hello");
    c.commit("file-1", "v1", 5);
    check(c.has_content("file-1") && c.lookup("file-1").version == "v1", "committed");
    c.set_pinned("file-1", true);
    c.set_dirty("pending:x", true, "parent-id", "new.txt");
    write_file(c.prepare_path("pending:x"), "new");
    c.save();
    var reloaded = new ContentCache(dir, 1000);
    check(reloaded.has_content("file-1") && reloaded.is_pinned("file-1"), "pinned survives a restart");
    var dirty = reloaded.dirty_records();
    check(dirty.size == 1 && dirty[0].remote_parent == "parent-id" && dirty[0].remote_name == "new.txt", "dirty survives a restart");
    reloaded.rekey("pending:x", "real-id");
    check(reloaded.lookup("pending:x") == null && reloaded.lookup("real-id") != null, "rekey moves the record");
    string moved;
    try {
        FileUtils.get_contents(reloaded.file_path("real-id"), out moved);
    } catch (Error e) {
        moved = "";
    }
    check(moved == "new", "rekey moves the content");
}

void test_cache_eviction() {
    string dir = scratch_dir();
    var c = new ContentCache(dir, 250);
    string[] keys = { "a", "b", "c", "d" };
    foreach (string k in keys) {
        write_file(c.prepare_path(k), string.nfill(100, 'x'));
        c.commit(k, "v", 100);
    }
    c.touch("a");
    c.set_pinned("b", true);
    var evicted = c.evict((k) => k == "c");
    check(evicted.size == 2 && evicted.contains("d"), "least recently used goes first");
    check(!c.has_content("a"), "older unpinned content is evicted next");
    check(c.has_content("b"), "pinned is kept");
    check(c.has_content("c"), "open file is kept");
    check(!FileUtils.test(c.file_path("d"), FileTest.EXISTS), "evicted content is deleted");
    check(c.total_size() <= 250, "under the limit");
    c.set_dirty("c", true);
    c.limit = 0;
    c.evict();
    check(c.has_content("b") && c.has_content("c"), "pinned and dirty survive a full eviction");
}

void test_cache_prefix_and_listings() {
    string dir = scratch_dir();
    var c = new ContentCache(dir, 1 << 20);
    write_file(c.prepare_path("/Docs/a.txt"), "a");
    c.commit("/Docs/a.txt", "1", 1);
    write_file(c.prepare_path("/Docs/Sub/b.txt"), "b");
    c.commit("/Docs/Sub/b.txt", "1", 1);
    write_file(c.prepare_path("/Other/c.txt"), "c");
    c.commit("/Other/c.txt", "1", 1);
    c.rekey_prefix("/Docs/", "/Papers/");
    check(c.has_content("/Papers/a.txt") && c.has_content("/Papers/Sub/b.txt"), "prefix rekey");
    check(!c.has_content("/Docs/a.txt") && c.has_content("/Other/c.txt"), "other keys untouched");
    var list = new Gee.ArrayList<CloudEntry>();
    var e = entry("/Papers/a.txt", "a.txt");
    e.size = 1;
    e.etag = "\"etag\"";
    e.modified = new DateTime.from_unix_utc(1700000000);
    list.add(e);
    list.add(entry("/Papers/Sub/", "Sub", true));
    c.store_listing("/Papers/", list);
    c.save();
    var reloaded = new ContentCache(dir, 1 << 20);
    var back = reloaded.load_listing("/Papers/");
    check(back != null && back.size == 2, "listing survives a restart");
    check(back[0].name == "a.txt" && back[0].etag == "\"etag\"" && back[0].size == 1 && back[0].modified.to_unix() == 1700000000, "entry fields");
    check(back[1].is_folder, "folder flag");
    check(reloaded.load_listing("/missing/") == null, "unknown listing");
    reloaded.remove("/Papers/a.txt");
    check(!reloaded.has_content("/Papers/a.txt"), "remove");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/cloud-mount/names/sanitize", test_sanitize);
    Test.add_func("/cloud-mount/names/numbered", test_numbered);
    Test.add_func("/cloud-mount/names/duplicates", test_assign_duplicates);
    Test.add_func("/cloud-mount/names/google-exports", test_google_exports);
    Test.add_func("/cloud-mount/nodes/table", test_node_table);
    Test.add_func("/cloud-mount/cache/basics", test_cache_basics);
    Test.add_func("/cloud-mount/cache/eviction", test_cache_eviction);
    Test.add_func("/cloud-mount/cache/prefix-and-listings", test_cache_prefix_and_listings);
    int result = Test.run();
    foreach (string dir in scratch_dirs) remove_tree(dir);
    return result;
}
