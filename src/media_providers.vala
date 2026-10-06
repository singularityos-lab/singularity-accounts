namespace Singularity.AccountsDaemon {

    namespace MediaProviders {
        public const string JELLYFIN_CLIENT = "Singularity";
        public const string SUBSONIC_VERSION = "1.16.1";
        public const uint SPOTIFY_PORT = 43019;
        public const string SPOTIFY_CALLBACK = "/callback";

        public uint spotify_port(OAuthClient client) {
            string? v = client.endpoints["redirect-port"];
            uint64 p = 0;
            if (v != null && uint64.try_parse(v, out p) && p > 0 && p < 65536) return (uint) p;
            return SPOTIFY_PORT;
        }

        public string spotify_redirect(uint port) {
            return "http://127.0.0.1:%u%s".printf(port, SPOTIFY_CALLBACK);
        }

        public string jellyfin_authorization(string device_id, string? token = null) {
            string h = "MediaBrowser Client=\"%s\", Device=\"Singularity\", DeviceId=\"%s\", Version=\"1.0\"".printf(JELLYFIN_CLIENT, device_id);
            if (token != null && token != "") h += ", Token=\"%s\"".printf(token);
            return h;
        }

        private Json.Object parse_object(string body, string what) throws AccountsError {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(body);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("%s sent an unexpected answer").printf(what));
                return root.get_object();
            } catch (AccountsError e) {
                throw e;
            } catch (Error e) {
                throw new AccountsError.PROTOCOL(_("%s sent an unexpected answer").printf(what));
            }
        }

        private string member(Json.Object o, string key) {
            if (!o.has_member(key) || o.get_member(key).get_node_type() != Json.NodeType.VALUE) return "";
            var v = o.get_member(key).get_value();
            if (v.type() == typeof(string)) return o.get_string_member(key);
            if (v.type() == typeof(int64)) return o.get_int_member(key).to_string();
            if (v.type() == typeof(bool)) return o.get_boolean_member(key) ? "true" : "false";
            return "";
        }

        public async void check_jellyfin(HttpProbe http, AccountRecord r, string user, string secret) throws AccountsError {
            string device = Checksum.compute_for_string(ChecksumType.SHA256, r.server + "\n" + user).substring(0, 16);
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("X-Emby-Authorization", jellyfin_authorization(device));
            headers.insert("Accept", "application/json");
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("Username").add_string_value(user);
            b.set_member_name("Pw").add_string_value(secret);
            b.end_object();
            var g = new Json.Generator();
            g.set_root(b.get_root());
            var reply = yield http.request("POST", r.server + "/Users/AuthenticateByName", jellyfin_authorization(device), "application/json", g.to_data(null), headers);
            if (reply.status == 401 || reply.status == 403) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            if (reply.status == 404) throw new AccountsError.PROTOCOL(_("%s is not a Jellyfin server").printf(Providers.host_of(r.server)));
            if (reply.status != 200) throw new AccountsError.PROTOCOL(_("The server answered HTTP %u").printf(reply.status));
            var o = parse_object(reply.body, "Jellyfin");
            if (!o.has_member("User") || o.get_member("User").get_node_type() != Json.NodeType.OBJECT) throw new AccountsError.PROTOCOL(_("%s is not a Jellyfin server").printf(Providers.host_of(r.server)));
            var u = o.get_object_member("User");
            r.endpoints["jellyfin"] = r.server;
            r.endpoints["jellyfin-user-id"] = member(u, "Id");
            r.endpoints["jellyfin-device"] = device;
            r.endpoints["dav-user"] = user;
            r.endpoints["music-api"] = "jellyfin";
            r.endpoints["videos-api"] = "jellyfin";
            if (o.has_member("ServerId")) r.endpoints["jellyfin-server-id"] = member(o, "ServerId");
            r.identity = user;
            r.display_name = "%s (%s)".printf(member(u, "Name") != "" ? member(u, "Name") : user, Providers.host_of(r.server));
            r.capabilities = { "music", "videos" };
        }

        public string subsonic_query(string user, string secret, string salt) {
            string token = Checksum.compute_for_string(ChecksumType.MD5, secret + salt);
            return "u=%s&t=%s&s=%s&v=%s&c=singularity&f=json".printf(Uri.escape_string(user, null, false), token, salt, SUBSONIC_VERSION);
        }

        public async void check_subsonic(HttpProbe http, AccountRecord r, string user, string secret) throws AccountsError {
            string salt = random_token(8);
            var reply = yield http.request("GET", r.server + "/rest/ping.view?" + subsonic_query(user, secret, salt), null);
            if (reply.status == 404) throw new AccountsError.PROTOCOL(_("%s is not a Subsonic or Navidrome server").printf(Providers.host_of(r.server)));
            if (reply.status == 401 || reply.status == 403) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            if (reply.status != 200) throw new AccountsError.PROTOCOL(_("The server answered HTTP %u").printf(reply.status));
            var o = parse_object(reply.body, "Subsonic");
            if (!o.has_member("subsonic-response")) throw new AccountsError.PROTOCOL(_("%s is not a Subsonic or Navidrome server").printf(Providers.host_of(r.server)));
            var s = o.get_object_member("subsonic-response");
            if (member(s, "status") != "ok") {
                string code = "";
                if (s.has_member("error") && s.get_member("error").get_node_type() == Json.NodeType.OBJECT) code = member(s.get_object_member("error"), "code");
                if (code == "40" || code == "41" || code == "44") throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
                throw new AccountsError.PROTOCOL(_("The server refused the connection (error %s)").printf(code));
            }
            r.endpoints["subsonic"] = r.server;
            r.endpoints["subsonic-type"] = member(s, "type");
            r.endpoints["dav-user"] = user;
            r.endpoints["music-api"] = "subsonic";
            r.identity = user;
            string kind = member(s, "type") == "navidrome" ? "Navidrome" : "Subsonic";
            r.display_name = "%s (%s, %s)".printf(user, kind, Providers.host_of(r.server));
            r.capabilities = { "music" };
        }

        public async void check_listenbrainz(HttpProbe http, AccountRecord r, string token) throws AccountsError {
            var reply = yield http.request("GET", r.server + "/1/validate-token", "Token " + token);
            if (reply.status == 401) throw new AccountsError.AUTH_FAILED(_("ListenBrainz did not accept the token"));
            if (reply.status != 200) throw new AccountsError.PROTOCOL(_("The server answered HTTP %u").printf(reply.status));
            var o = parse_object(reply.body, "ListenBrainz");
            if (member(o, "valid") != "true") throw new AccountsError.AUTH_FAILED(_("ListenBrainz did not accept the token"));
            string name = member(o, "user_name");
            r.endpoints["listenbrainz"] = r.server;
            r.endpoints["music-api"] = "listenbrainz";
            r.endpoints["dav-user"] = name;
            r.identity = name;
            r.display_name = name;
            r.capabilities = { "music" };
        }

        public async void spotify_identity(OAuthClient client, string access_token, SignInResult result) throws AccountsError {
            string api = client.endpoints.has_key("spotify-api") ? client.endpoints["spotify-api"] : "https://api.spotify.com/v1/";
            var reply = yield new HttpProbe(false).request("GET", api + "me", "Bearer " + access_token);
            if (reply.status != 200) throw new AccountsError.PROTOCOL(_("Spotify did not say which account signed in (HTTP %u)").printf(reply.status));
            var o = parse_object(reply.body, "Spotify");
            result.identity = member(o, "id");
            result.display_name = member(o, "display_name") != "" ? member(o, "display_name") : result.identity;
            result.server = member(o, "product");
        }
    }
}
