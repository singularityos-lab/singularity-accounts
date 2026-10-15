namespace Singularity.AccountsDaemon {

    public class OAuthClient : Object {
        public string provider { get; set; default = ""; }
        public string client_id { get; set; default = ""; }
        public string client_secret { get; set; default = ""; }
        public string auth_uri { get; set; default = ""; }
        public string token_uri { get; set; default = ""; }
        public string source { get; set; default = ""; }
        public string source_kind { get; set; default = ""; }
        public Gee.HashMap<string, string> endpoints = new Gee.HashMap<string, string>();

        public bool configured {
            get { return client_id.strip() != ""; }
        }
    }

    public class OAuthConfig : Object {
        public static string user_path() {
            return Path.build_filename(Environment.get_user_config_dir(), "singularity", "accounts", "oauth-clients.json");
        }

        public static string[] system_paths() {
            string[] paths = {};
            foreach (string dir in Environment.get_system_data_dirs()) {
                paths += Path.build_filename(dir, "singularity", "oauth-clients.json");
            }
            paths += "/opt/local/share/singularity/oauth-clients.json";
            paths += "/etc/singularity/oauth-clients.json";
            return paths;
        }

        private static string defaults_auth(string provider) {
            if (provider == "spotify") return "https://accounts.spotify.com/authorize";
            return provider == "google"
                ? "https://accounts.google.com/o/oauth2/v2/auth"
                : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
        }

        private static string defaults_token(string provider) {
            if (provider == "spotify") return "https://accounts.spotify.com/api/token";
            return provider == "google"
                ? "https://oauth2.googleapis.com/token"
                : "https://login.microsoftonline.com/common/oauth2/v2.0/token";
        }

        private static string str(Json.Object o, string key) {
            if (!o.has_member(key)) return "";
            var n = o.get_member(key);
            if (n.get_node_type() != Json.NodeType.VALUE) return "";
            var v = n.get_value();
            if (v.type() == typeof(string)) return n.get_string();
            if (v.type() == typeof(int64)) return n.get_int().to_string();
            if (v.type() == typeof(bool)) return n.get_boolean() ? "true" : "false";
            return "";
        }

        public static void apply_file(OAuthClient client, string path) {
            if (!FileUtils.test(path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var all = root.get_object();
                if (!all.has_member(client.provider)) return;
                var o = all.get_object_member(client.provider);
                if (o.has_member("installed") && o.get_member("installed").get_node_type() == Json.NodeType.OBJECT) {
                    o = o.get_object_member("installed");
                }
                if (str(o, "client_id") != "") {
                    client.client_id = str(o, "client_id");
                    client.client_secret = str(o, "client_secret");
                    client.source = path;
                    client.source_kind = kind_of(path);
                }
                string tenant = str(o, "tenant");
                if (tenant != "" && client.provider == "microsoft") {
                    client.auth_uri = "https://login.microsoftonline.com/%s/oauth2/v2.0/authorize".printf(tenant);
                    client.token_uri = "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf(tenant);
                }
                if (str(o, "auth_uri") != "") client.auth_uri = str(o, "auth_uri");
                if (str(o, "token_uri") != "") client.token_uri = str(o, "token_uri");
                if (o.has_member("endpoints") && o.get_member("endpoints").get_node_type() == Json.NodeType.OBJECT) {
                    var eo = o.get_object_member("endpoints");
                    foreach (string k in eo.get_members()) client.endpoints[k] = str(eo, k);
                }
            } catch (Error e) {
                warning("cannot read %s: %s", path, e.message);
            }
        }

        public static string kind_of(string path) {
            if (path == user_path()) return "user";
            if (path.has_prefix("/etc/")) return "system";
            return "distribution";
        }

        public static void apply_built_in(OAuthClient client) {
            string id = client.provider == "google" ? BuildConfig.GOOGLE_CLIENT_ID
                : client.provider == "microsoft" ? BuildConfig.MICROSOFT_CLIENT_ID : "";
            if (id.strip() == "") return;
            client.client_id = id.strip();
            client.client_secret = client.provider == "google" ? BuildConfig.GOOGLE_CLIENT_SECRET.strip() : "";
            client.source = "";
            client.source_kind = "built-in";
            string tenant = BuildConfig.MICROSOFT_TENANT.strip();
            if (client.provider == "microsoft" && tenant != "") {
                client.auth_uri = "https://login.microsoftonline.com/%s/oauth2/v2.0/authorize".printf(tenant);
                client.token_uri = "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf(tenant);
            }
        }

        public static OAuthClient load(string provider) {
            var client = new OAuthClient();
            client.provider = provider;
            client.auth_uri = defaults_auth(provider);
            client.token_uri = defaults_token(provider);
            if (!user_only(provider)) {
                apply_built_in(client);
                foreach (string p in system_paths()) apply_file(client, p);
            }
            apply_file(client, user_path());
            return client;
        }

        public static bool user_only(string provider) {
            return provider == "spotify";
        }

        public static void store_user(string provider, string client_id, string client_secret) throws Error {
            var root = new Json.Object();
            string path = user_path();
            if (FileUtils.test(path, FileTest.EXISTS)) {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                if (parser.get_root() != null && parser.get_root().get_node_type() == Json.NodeType.OBJECT) root = parser.get_root().get_object();
            }
            Json.Object entry = root.has_member(provider) ? root.get_object_member(provider) : new Json.Object();
            if (client_id.strip() == "") {
                entry.remove_member("client_id");
                entry.remove_member("client_secret");
            } else {
                entry.set_string_member("client_id", client_id.strip());
                if (client_secret.strip() != "") entry.set_string_member("client_secret", client_secret.strip());
                else entry.remove_member("client_secret");
            }
            if (entry.get_size() == 0) root.remove_member(provider);
            else root.set_object_member(provider, entry);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.set_root(node);
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            FileUtils.set_contents_full(path, gen.to_data(null), -1, FileSetContentsFlags.CONSISTENT, 0600);
        }
    }

    namespace Pkce {
        public string verifier() {
            return random_token(48);
        }

        public string challenge(string verifier) {
            var checksum = new Checksum(ChecksumType.SHA256);
            checksum.update(verifier.data, verifier.length);
            uint8[] digest = new uint8[32];
            size_t len = 32;
            checksum.get_digest(digest, ref len);
            return base64url(digest);
        }
    }

    public class TokenSet : Object {
        public string access_token { get; set; default = ""; }
        public string refresh_token { get; set; default = ""; }
        public string id_token { get; set; default = ""; }
        public int expires_in { get; set; default = 3600; }
        public string scope { get; set; default = ""; }

        public static TokenSet parse(string body) throws AccountsError {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(body);
                var o = parser.get_root().get_object();
                var t = new TokenSet();
                if (o.has_member("access_token")) t.access_token = o.get_string_member("access_token");
                if (o.has_member("refresh_token")) t.refresh_token = o.get_string_member("refresh_token");
                if (o.has_member("id_token")) t.id_token = o.get_string_member("id_token");
                if (o.has_member("scope")) t.scope = o.get_string_member("scope");
                if (o.has_member("expires_in")) {
                    var n = o.get_member("expires_in");
                    t.expires_in = n.get_value().type() == typeof(string) ? int.parse(n.get_string()) : (int) n.get_int();
                }
                if (t.access_token == "") throw new AccountsError.PROTOCOL(_("The sign-in server did not return a token"));
                return t;
            } catch (AccountsError e) {
                throw e;
            } catch (Error e) {
                throw new AccountsError.PROTOCOL(_("The sign-in server sent an unexpected answer"));
            }
        }

        public static Json.Object? jwt_claims(string jwt) {
            var parts = jwt.split(".");
            if (parts.length < 2) return null;
            try {
                uint8[] raw = base64url_decode(parts[1]);
                var sb = new StringBuilder();
                sb.append_len((string) raw, raw.length);
                var parser = new Json.Parser();
                parser.load_from_data(sb.str);
                var root = parser.get_root();
                return root != null && root.get_node_type() == Json.NodeType.OBJECT ? root.get_object() : null;
            } catch (Error e) {
                return null;
            }
        }

        public string identity() {
            var claims = jwt_claims(id_token);
            if (claims == null) return "";
            foreach (string key in new string[] { "email", "preferred_username", "upn", "unique_name" }) {
                if (claims.has_member(key)) {
                    string v = claims.get_string_member(key);
                    if (v != null && v != "") return v;
                }
            }
            return "";
        }

        public string display_name() {
            var claims = jwt_claims(id_token);
            if (claims != null && claims.has_member("name")) return claims.get_string_member("name");
            return "";
        }
    }

    public class TokenClient : Object {
        private static async Bytes read_bounded(Soup.Session session, Soup.Message message, int64 limit, int priority, Cancellable? cancellable) throws Error {
            var stream = yield session.send_async(message, priority, cancellable);
            if (message.response_headers.get_content_length() > limit) throw new IOError.MESSAGE_TOO_LARGE("The response is too large");
            var body = new ByteArray();
            var chunk = new uint8[65536];
            ssize_t n;
            while ((n = yield stream.read_async(chunk, priority, cancellable)) > 0) {
                if (body.len + n > limit) {
                    try {
                        stream.close(null);
                    } catch (Error e) {
                    }
                    throw new IOError.MESSAGE_TOO_LARGE("The response is too large");
                }
                body.append(chunk[0:(int) n]);
            }
            try {
                stream.close(null);
            } catch (Error e) {
            }
            return ByteArray.free_to_bytes((owned) body);
        }
        private Soup.Session session;

        public TokenClient() {
            session = new Soup.Session();
            session.user_agent = "Singularity Online Accounts";
            session.timeout = 30;
        }

        public static string form(HashTable<string, string> fields) {
            var sb = new StringBuilder();
            fields.foreach((k, v) => {
                if (sb.len > 0) sb.append_c('&');
                sb.append(Uri.escape_string(k, null, false)).append_c('=').append(Uri.escape_string(v, null, false));
            });
            return sb.str;
        }

        public async TokenSet request(string url, HashTable<string, string> fields) throws AccountsError {
            var msg = new Soup.Message("POST", url);
            if (msg == null) throw new AccountsError.INVALID(_("The sign-in address is not valid"));
            msg.request_headers.append("Accept", "application/json");
            msg.set_request_body_from_bytes("application/x-www-form-urlencoded", new Bytes(form(fields).data));
            Bytes body;
            try {
                body = yield read_bounded(session, msg, 1024 * 1024, Priority.DEFAULT, null);
            } catch (Error e) {
                throw new AccountsError.NETWORK(_("Could not reach the sign-in server: %s").printf(e.message));
            }
            string text = bytes_text(body);
            if (msg.status_code >= 200 && msg.status_code < 300) return TokenSet.parse(text);
            string error = "";
            string description = "";
            try {
                var parser = new Json.Parser();
                parser.load_from_data(text);
                var o = parser.get_root().get_object();
                if (o.has_member("error")) error = o.get_string_member("error");
                if (o.has_member("error_description")) description = o.get_string_member("error_description");
            } catch (Error e) {
            }
            if (error == "invalid_grant" || error == "interaction_required" || error == "consent_required") {
                throw new AccountsError.NEEDS_REAUTH(_("The sign-in expired or was revoked. Sign in again."));
            }
            if (error == "invalid_client" || error == "unauthorized_client") {
                throw new AccountsError.NOT_CONFIGURED(_("The provider rejected this system's registration (%s)").printf(error));
            }
            throw new AccountsError.PROTOCOL(_("The sign-in server refused the request: %s").printf(description != "" ? description : (error != "" ? error : "HTTP %u".printf(msg.status_code))));
        }

        public async TokenSet exchange_code(OAuthClient client, string code, string redirect_uri, string verifier) throws AccountsError {
            var f = new HashTable<string, string>(str_hash, str_equal);
            f.insert("grant_type", "authorization_code");
            f.insert("code", code);
            f.insert("redirect_uri", redirect_uri);
            f.insert("client_id", client.client_id);
            if (client.client_secret != "") f.insert("client_secret", client.client_secret);
            f.insert("code_verifier", verifier);
            return yield request(client.token_uri, f);
        }

        public async TokenSet refresh(OAuthClient client, string refresh_token, string? scope) throws AccountsError {
            var f = new HashTable<string, string>(str_hash, str_equal);
            f.insert("grant_type", "refresh_token");
            f.insert("refresh_token", refresh_token);
            f.insert("client_id", client.client_id);
            if (client.client_secret != "") f.insert("client_secret", client.client_secret);
            if (scope != null && scope != "") f.insert("scope", scope);
            return yield request(client.token_uri, f);
        }
    }
}
