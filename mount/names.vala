using Singularity.Accounts;

namespace Singularity.CloudMount {

    public class NamedEntry : Object {
        public string name { get; construct; }
        public CloudEntry entry { get; construct; }

        public NamedEntry(string name, CloudEntry entry) {
            Object(name: name, entry: entry);
        }
    }

    public class Names : Object {
        public const string DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
        public const string XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        public const string PPTX = "application/vnd.openxmlformats-officedocument.presentationml.presentation";

        public static string sanitize(string name) {
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            string valid = name.validate() ? name : name.make_valid();
            while (valid.get_next_char(ref i, out c)) {
                if (c == '/' || c < 0x20) sb.append_c('_');
                else sb.append_unichar(c);
            }
            string result = sb.str;
            if (result == "" || result == "." || result == "..") result = "_" + result;
            while (result.length > 255) result = result.substring(0, result.index_of_nth_char(result.char_count() - 1));
            return result;
        }

        public static string extension_of(string name) {
            int dot = name.last_index_of(".");
            if (dot <= 0 || dot == name.length - 1) return "";
            return name.substring(dot);
        }

        public static string numbered(string name, int n, bool is_folder) {
            string ext = is_folder ? "" : extension_of(name);
            string stem = name.substring(0, name.length - ext.length);
            return "%s (%d)%s".printf(stem, n, ext);
        }

        public static string export_extension(string export_type) {
            switch (export_type) {
                case DOCX: return ".docx";
                case XLSX: return ".xlsx";
                case PPTX: return ".pptx";
                case "application/vnd.oasis.opendocument.text": return ".odt";
                case "application/vnd.oasis.opendocument.spreadsheet": return ".ods";
                case "application/vnd.oasis.opendocument.presentation": return ".odp";
                case "image/svg+xml": return ".svg";
                default: return "";
            }
        }

        public static string office_type_for(string export_type) {
            switch (export_type) {
                case "application/vnd.oasis.opendocument.text": return DOCX;
                case "application/vnd.oasis.opendocument.spreadsheet": return XLSX;
                case "application/vnd.oasis.opendocument.presentation": return PPTX;
                default: return export_type;
            }
        }

        public static void apply_export(CloudEntry e) {
            if (e.export_type == "") return;
            string old_ext = export_extension(e.export_type);
            string type = office_type_for(e.export_type);
            string ext = export_extension(type);
            string name = e.name;
            if (old_ext != "" && old_ext != ext && name.has_suffix(old_ext)) name = name.substring(0, name.length - old_ext.length);
            if (ext != "" && !name.has_suffix(ext)) name += ext;
            e.export_type = type;
            e.content_type = type;
            e.name = name;
        }

        public static string remote_name(string local_name, CloudEntry? entry) {
            if (entry == null || entry.export_type == "") return local_name;
            string ext = export_extension(entry.export_type);
            if (ext != "" && local_name.has_suffix(ext) && local_name.length > ext.length) {
                return local_name.substring(0, local_name.length - ext.length);
            }
            return local_name;
        }

        public static Gee.List<NamedEntry> assign(Gee.List<CloudEntry> entries) {
            var sorted = new Gee.ArrayList<CloudEntry>();
            sorted.add_all(entries);
            sorted.sort((a, b) => {
                int c = strcmp(sanitize(a.name), sanitize(b.name));
                if (c != 0) return c;
                if (a.is_folder != b.is_folder) return a.is_folder ? -1 : 1;
                return strcmp(a.id, b.id);
            });
            var taken = new Gee.HashSet<string>();
            var wanted = new Gee.HashSet<string>();
            foreach (var e in sorted) wanted.add(sanitize(e.name));
            var result = new Gee.ArrayList<NamedEntry>();
            foreach (var e in sorted) {
                string base_name = sanitize(e.name);
                string name = base_name;
                if (taken.contains(name)) {
                    int n = 2;
                    do {
                        name = numbered(base_name, n++, e.is_folder);
                    } while (taken.contains(name) || wanted.contains(name));
                }
                taken.add(name);
                result.add(new NamedEntry(name, e));
            }
            return result;
        }

        public static bool is_reserved(string name, bool at_root) {
            if (!at_root) return false;
            return name == ".Trash" || name.has_prefix(".Trash-");
        }
    }
}
