namespace Singularity.AccountsDaemon {

    [DBus (name = "dev.sinty.Accounts")]
    public class Service : Object {
        private AccountStore store;
        private Gee.HashMap<string, SignInFlow> flows = new Gee.HashMap<string, SignInFlow>();
        private Gee.HashMap<string, string> tokens = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, int64?> expiry = new Gee.HashMap<string, int64?>();
        private Gee.HashSet<string> refreshing = new Gee.HashSet<string>();
        private Gee.HashMap<string, uint> credential_revision = new Gee.HashMap<string, uint>();

        public signal void account_added(string id);
        public signal void account_removed(string id);
        public signal void account_changed(string id);
        public signal void needs_attention(string id, string reason);
        public signal void sign_in_finished(string flow_id, string account_id, string error_message);

        [DBus (visible = false)]
        public signal void touched();

        [DBus (visible = false)]
        public bool busy {
            get { return flows.size > 0 || refreshing.size > 0; }
        }

        public Service(AccountStore store) {
            this.store = store;
            bool changed = false;
            foreach (var r in store.accounts) {
                if (Providers.upgrade(r)) changed = true;
            }
            if (changed) {
                try {
                    store.save();
                } catch (Error e) {
                    warning("%s", e.message);
                }
            }
        }

        private AccountRecord require(string id) throws AccountsError {
            touched();
            var r = store.find(id);
            if (r == null) throw new AccountsError.NOT_FOUND(_("There is no account %s").printf(id));
            return r;
        }

        private void persist() throws AccountsError {
            try {
                store.save();
            } catch (Error e) {
                throw new AccountsError.UNAVAILABLE(_("Could not save the account list: %s").printf(e.message));
            }
        }

        private AccountRecord require_credentials(string id, string capability, uint? revision = null) throws AccountsError {
            var r = require(id);
            if (capability == "mail-graph" && (r.provider != "microsoft" || r.auth != "oauth2")) {
                throw new AccountsError.INVALID(_("This account does not offer Microsoft Graph mail"));
            }
            string cap = capability == "mail-graph" ? "mail" : capability;
            if (!r.has_capability(cap) || !(cap in r.enabled) ||
                (revision != null && revision != credential_revision[id])) {
                throw new AccountsError.INVALID(_("This account does not offer %s").printf(cap));
            }
            return r;
        }

        private void mark_attention(AccountRecord r, string reason) {
            if (r.attention == reason) return;
            r.attention = reason;
            try {
                store.save();
            } catch (Error e) {
                warning("%s", e.message);
            }
            needs_attention(r.id, reason);
            account_changed(r.id);
        }

        private void clear_attention(AccountRecord r) {
            if (r.attention == "") return;
            r.attention = "";
            try {
                store.save();
            } catch (Error e) {
                warning("%s", e.message);
            }
            account_changed(r.id);
        }

        public HashTable<string, Variant>[] list_accounts() throws AccountsError {
            touched();
            HashTable<string, Variant>[] result = {};
            foreach (var r in store.accounts) result += r.to_variant(Providers.find(r.provider));
            return result;
        }

        public HashTable<string, Variant>[] list_providers() throws AccountsError {
            touched();
            HashTable<string, Variant>[] result = {};
            foreach (var p in Providers.all()) {
                if (p.auth != "oauth2") {
                    result += p.to_variant(true);
                    continue;
                }
                var client = OAuthConfig.load(p.id);
                result += p.to_variant(client.configured, client);
            }
            return result;
        }

        public async void get_access_token(string id, string capability, bool refresh, out string token, out int expires_in) throws AccountsError {
            token = "";
            expires_in = 0;
            var r = require_credentials(id, capability);
            if (r.auth != "oauth2") throw new AccountsError.INVALID(_("%s does not use tokens").printf(r.identity));
            uint revision = credential_revision[id];
            string resource = Providers.resource_for(r.provider, capability);
            string key = id + "|" + resource;
            int64 now = get_real_time() / 1000000;
            if (refresh) {
                tokens.unset(key);
                expiry.unset(key);
            }
            while (refreshing.contains(key)) {
                Timeout.add(50, get_access_token.callback);
                yield;
            }
            require_credentials(id, capability, revision);
            now = get_real_time() / 1000000;
            if (tokens.has_key(key) && expiry[key] > now + 30) {
                token = tokens[key];
                expires_in = (int) (expiry[key] - now);
                return;
            }
            refreshing.add(key);
            try {
                string? refresh_token = yield Secrets.lookup(id, "refresh-token");
                require_credentials(id, capability, revision);
                if (refresh_token == null || refresh_token == "") {
                    mark_attention(r, "reauth");
                    throw new AccountsError.NEEDS_REAUTH(_("Sign in to %s again in Settings").printf(r.identity));
                }
                var client = OAuthConfig.load(r.provider);
                if (!client.configured) throw new AccountsError.NOT_CONFIGURED(_("This system has no registration for %s sign-in").printf(r.provider));
                TokenSet ts;
                try {
                    ts = yield new TokenClient().refresh(client, refresh_token, r.provider == "microsoft" ? Providers.scopes_for(r.provider, resource, r.endpoint("granted-scopes")) : null);
                } catch (AccountsError.NEEDS_REAUTH e) {
                    require_credentials(id, capability, revision);
                    mark_attention(r, "reauth");
                    throw e;
                }
                require_credentials(id, capability, revision);
                if (ts.refresh_token != "" && ts.refresh_token != refresh_token) yield Secrets.store(r, "refresh-token", ts.refresh_token);
                require_credentials(id, capability, revision);
                int life = ts.expires_in > 0 ? ts.expires_in : 3600;
                now = get_real_time() / 1000000;
                int margin = int.min(60, life / 4);
                tokens[key] = ts.access_token;
                expiry[key] = now + life - margin;
                clear_attention(r);
                token = ts.access_token;
                expires_in = life - margin;
                if (resource == "mail" && Providers.legacy_imap_mail(r) && mail_probed.add(id)) {
                    string current = ts.refresh_token != "" ? ts.refresh_token : refresh_token;
                    migrate_mail.begin(r, client, current, revision);
                }
            } finally {
                refreshing.remove(key);
            }
        }

        private Gee.HashSet<string> mail_probed = new Gee.HashSet<string>();

        [DBus (visible = false)]
        public async bool migrate_mail(AccountRecord r, OAuthClient client, string refresh_token, uint revision) {
            string key = r.id + "|graph-mail";
            try {
                var ts = yield new TokenClient().refresh(client, refresh_token, Providers.scopes_for("microsoft", "graph-mail", r.endpoint("granted-scopes")));
                if (store.find(r.id) != r || revision != credential_revision[r.id] || !Providers.legacy_imap_mail(r)) return false;
                if (ts.scope != "") Providers.merge_granted(r, ts.scope);
                if (ts.refresh_token != "" && ts.refresh_token != refresh_token) yield Secrets.store(r, "refresh-token", ts.refresh_token);
                int life = ts.expires_in > 0 ? ts.expires_in : 3600;
                tokens[key] = ts.access_token;
                expiry[key] = get_real_time() / 1000000 + life - int.min(60, life / 4);
                Providers.use_graph_mail(r);
                persist();
                account_changed(r.id);
                return true;
            } catch (Error e) {
                debug("%s keeps IMAP mail: %s", r.id, e.message);
                return false;
            }
        }

        public async void get_credentials(string id, string capability, out string username, out string secret, out string mechanism) throws AccountsError {
            username = "";
            secret = "";
            mechanism = "";
            var r = require_credentials(id, capability);
            uint revision = credential_revision[id];
            if (r.auth == "oauth2") {
                int expires;
                string t;
                yield get_access_token(id, capability, false, out t, out expires);
                require_credentials(id, capability, revision);
                username = capability == "mail" ? r.endpoint("imap-user", r.identity) : r.identity;
                secret = t;
                mechanism = "oauth2";
                return;
            }
            string? password = yield Secrets.lookup(id, "password");
            require_credentials(id, capability, revision);
            if (password == null) {
                mark_attention(r, "reauth");
                throw new AccountsError.NEEDS_REAUTH(_("The password of %s is missing. Enter it again in Settings.").printf(r.identity));
            }
            username = capability == "mail" ? r.endpoint("imap-user", r.identity) : r.endpoint("dav-user", r.identity);
            secret = password;
            mechanism = r.endpoint("auth-scheme") == "ntlm" ? "ntlm" : "password";
        }

        public void set_capability_enabled(string id, string capability, bool enabled) throws AccountsError {
            var r = require(id);
            if (capability == Providers.MICROSOFT_IMAP_FALLBACK) {
                set_imap_fallback(r, enabled);
                return;
            }
            if (!r.has_capability(capability)) throw new AccountsError.INVALID(_("%s does not offer %s").printf(r.identity, capability));
            if (enabled && r.auth == "oauth2" && !Providers.granted(r, capability)) {
                r.endpoints["pending-consent"] = capability;
                persist();
                mark_attention(r, "consent");
                throw new AccountsError.NEEDS_REAUTH(_("Sign in to %s again to allow %s").printf(r.identity, capability == "videos" ? "YouTube" : capability));
            }
            if (enabled != (capability in r.enabled)) {
                credential_revision[id] = credential_revision[id] + 1;
                foreach (string key in tokens.keys.to_array()) {
                    if (key.has_prefix(id + "|")) {
                        tokens.unset(key);
                        expiry.unset(key);
                    }
                }
            }
            r.enable_capability(capability, enabled);
            persist();
            account_changed(id);
        }

        private void forget_tokens(string id) {
            credential_revision[id] = credential_revision[id] + 1;
            foreach (string key in tokens.keys.to_array()) {
                if (key.has_prefix(id + "|")) {
                    tokens.unset(key);
                    expiry.unset(key);
                }
            }
        }

        private void set_imap_fallback(AccountRecord r, bool enabled) throws AccountsError {
            if (r.provider != "microsoft" || r.auth != "oauth2" || !r.has_capability("mail")) {
                throw new AccountsError.INVALID(_("%s does not offer IMAP and SMTP as a fallback").printf(r.identity));
            }
            if (enabled && !Providers.imap_granted(r)) {
                r.endpoints["pending-consent"] = Providers.MICROSOFT_IMAP_FALLBACK;
                persist();
                mark_attention(r, "consent");
                throw new AccountsError.NEEDS_REAUTH(_("Sign in to %s again to allow IMAP and SMTP").printf(r.identity));
            }
            if (enabled) {
                Providers.use_imap_mail(r);
            } else {
                Providers.use_graph_mail(r);
                if (r.endpoint("pending-consent") == Providers.MICROSOFT_IMAP_FALLBACK) {
                    r.endpoints.unset("pending-consent");
                    if (r.attention == "consent") r.attention = "";
                }
            }
            forget_tokens(r.id);
            persist();
            account_changed(r.id);
        }

        public void set_display_name(string id, string name) throws AccountsError {
            var r = require(id);
            r.display_name = name.strip();
            persist();
            account_changed(id);
        }

        public async void remove_account(string id) throws AccountsError {
            var r = require(id);
            store.accounts.remove(r);
            persist();
            yield Secrets.clear(id);
            foreach (var k in tokens.keys.to_array()) {
                if (k.has_prefix(id + "|")) {
                    tokens.unset(k);
                    expiry.unset(k);
                }
            }
            delete_tree(Path.build_filename(Environment.get_user_data_dir(), "singularity", "accounts", id));
            delete_tree(Path.build_filename(Environment.get_user_cache_dir(), "singularity", "cloud-files", id));
            account_removed(id);
        }

        private static void delete_tree(string path) {
            var file = File.new_for_path(path);
            if (!file.query_exists()) return;
            try {
                var e = file.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
                FileInfo? info;
                while ((info = e.next_file()) != null) {
                    string child = Path.build_filename(path, info.get_name());
                    if (info.get_file_type() == FileType.DIRECTORY) delete_tree(child);
                    else FileUtils.unlink(child);
                }
            } catch (Error e) {
                warning("cannot clean %s: %s", path, e.message);
            }
            DirUtils.remove(path);
        }

        private static string setting(HashTable<string, Variant> settings, string key, string fallback = "") {
            var v = settings.lookup(key);
            if (v == null) return fallback;
            if (v.is_of_type(VariantType.STRING)) return v.get_string().strip();
            if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean() ? "true" : "false";
            if (v.is_of_type(VariantType.INT32)) return v.get_int32().to_string();
            if (v.is_of_type(VariantType.UINT32)) return v.get_uint32().to_string();
            return fallback;
        }

        private static uint16 port_of(string text, uint16 fallback) {
            uint64 p;
            if (uint64.try_parse(text, out p) && p > 0 && p <= 65535) return (uint16) p;
            return fallback;
        }

        private async AccountRecord prepare(string provider, HashTable<string, Variant> settings, string secret) throws AccountsError {
            var info = Providers.find(provider);
            if (info == null || info.auth == "oauth2" && provider != "google") {
                throw new AccountsError.INVALID(_("Accounts of type %s cannot be added with a password").printf(provider));
            }
            if (secret == "") throw new AccountsError.INVALID(_("Enter the password"));
            var r = new AccountRecord();
            r.provider = provider;
            r.auth = "password";
            bool accept_invalid = setting(settings, "accept-invalid-tls") == "true";
            if (accept_invalid) r.endpoints["tls-accept-invalid"] = "true";
            switch (provider) {
                case "imap":
                case "proton":
                case "google":
                case "exchange": {
                    string email = setting(settings, "email");
                    if (!email.contains("@")) throw new AccountsError.INVALID(_("Enter a valid email address"));
                    r.identity = email;
                    string user = setting(settings, "username", email);
                    if (user == "") user = email;
                    if (provider == "exchange") {
                        yield prepare_exchange(r, settings, user, secret, accept_invalid);
                        if (setting(settings, "imap-host") == "") break;
                    }
                    OAuthClient? client = provider == "google" ? OAuthConfig.load("google") : null;
                    if (provider == "google") Providers.apply_defaults(r, client);
                    string imap_host = setting(settings, "imap-host", r.endpoint("imap-host", provider == "proton" ? "127.0.0.1" : ""));
                    string smtp_host = setting(settings, "smtp-host", r.endpoint("smtp-host", provider == "proton" ? "127.0.0.1" : ""));
                    string imap_sec = setting(settings, "imap-security", r.endpoint("imap-security", provider == "proton" ? "starttls" : "tls"));
                    string smtp_sec = setting(settings, "smtp-security", r.endpoint("smtp-security", provider == "proton" ? "starttls" : "tls"));
                    uint16 imap_port = port_of(setting(settings, "imap-port", r.endpoint("imap-port")), provider == "proton" ? 1143 : imap_sec == "tls" ? 993 : 143);
                    uint16 smtp_port = port_of(setting(settings, "smtp-port", r.endpoint("smtp-port")), provider == "proton" ? 1025 : smtp_sec == "tls" ? 465 : 587);
                    if (imap_host == "" || smtp_host == "") throw new AccountsError.INVALID(_("Enter the incoming and outgoing servers"));
                    if (provider == "proton") {
                        accept_invalid = true;
                        r.endpoints["tls-accept-invalid"] = "true";
                    }
                    if (accept_invalid || r.endpoint("tls-accept-invalid") == "true") accept_invalid = true;
                    yield new MailProbe(imap_host, accept_invalid).imap_login(imap_port, imap_sec, user, secret, "password");
                    yield new MailProbe(smtp_host, accept_invalid).smtp_login(smtp_port, smtp_sec, user, secret, "password");
                    r.endpoints["mail-address"] = email;
                    r.endpoints["mail-name"] = setting(settings, "name");
                    r.endpoints["imap-host"] = imap_host;
                    r.endpoints["imap-port"] = imap_port.to_string();
                    r.endpoints["imap-security"] = imap_sec;
                    r.endpoints["imap-user"] = user;
                    r.endpoints["smtp-host"] = smtp_host;
                    r.endpoints["smtp-port"] = smtp_port.to_string();
                    r.endpoints["smtp-security"] = smtp_sec;
                    r.endpoints["smtp-user"] = user;
                    r.endpoints["mail-auth"] = "password";
                    string[] caps = provider == "exchange" ? r.capabilities : new string[0];
                    caps += "mail";
                    r.capabilities = caps;
                    r.server = imap_host;
                    break;
                }
                case "caldav": {
                    string server = Providers.normalize_server(setting(settings, "server"));
                    string user = setting(settings, "username");
                    if (server == "" || user == "") throw new AccountsError.INVALID(_("Enter the server address and user name"));
                    bool calendars, contacts;
                    yield DavProbe.check(new HttpProbe(accept_invalid), server, HttpProbe.basic(user, secret), out calendars, out contacts);
                    if (!calendars && !contacts) throw new AccountsError.PROTOCOL(_("The server offers neither calendars nor address books"));
                    string[] caps = {};
                    if (calendars) {
                        caps += "calendar";
                        caps += "tasks";
                        r.endpoints["caldav"] = server;
                        r.endpoints["calendar-api"] = "caldav";
                        r.endpoints["tasks-api"] = "caldav";
                    }
                    if (contacts) {
                        caps += "contacts";
                        r.endpoints["carddav"] = server;
                        r.endpoints["contacts-api"] = "carddav";
                    }
                    r.capabilities = caps;
                    r.server = server;
                    r.identity = user;
                    r.endpoints["dav-user"] = user;
                    break;
                }
                case "webdav": {
                    string server = setting(settings, "server");
                    if (!server.has_prefix("http")) server = "https://" + server;
                    if (!server.has_suffix("/")) server += "/";
                    string user = setting(settings, "username");
                    if (user == "") throw new AccountsError.INVALID(_("Enter the server address and user name"));
                    yield DavProbe.check_webdav(new HttpProbe(accept_invalid), server, HttpProbe.basic(user, secret));
                    r.capabilities = { "files" };
                    r.endpoints["webdav"] = server;
                    r.endpoints["files-api"] = "webdav";
                    r.endpoints["dav-user"] = user;
                    r.server = server;
                    r.identity = user + "@" + Providers.host_of(server);
                    break;
                }
                case "nextcloud":
                case "owncloud": {
                    string server = Providers.normalize_server(setting(settings, "server"));
                    string user = setting(settings, "username");
                    if (server == "" || user == "") throw new AccountsError.INVALID(_("Enter the server address and user name"));
                    r.server = server;
                    r.identity = user;
                    r.endpoints["dav-user"] = user;
                    yield describe_cloud(r, user, secret, accept_invalid);
                    break;
                }
                case "jellyfin":
                case "subsonic": {
                    string server = Providers.normalize_server(setting(settings, "server"));
                    string user = setting(settings, "username");
                    if (server == "" || user == "") throw new AccountsError.INVALID(_("Enter the server address and user name"));
                    r.server = server;
                    if (provider == "jellyfin") yield MediaProviders.check_jellyfin(new HttpProbe(accept_invalid), r, user, secret);
                    else yield MediaProviders.check_subsonic(new HttpProbe(accept_invalid), r, user, secret);
                    break;
                }
                case "listenbrainz": {
                    string server = Providers.normalize_server(setting(settings, "server", "https://api.listenbrainz.org"));
                    if (server == "") server = "https://api.listenbrainz.org";
                    r.server = server;
                    yield MediaProviders.check_listenbrainz(new HttpProbe(accept_invalid), r, secret);
                    break;
                }
                default:
                    throw new AccountsError.INVALID(_("Unknown account type %s").printf(provider));
            }
            if (r.display_name == "") r.display_name = setting(settings, "display-name");
            return r;
        }

        private async void describe_cloud(AccountRecord r, string user, string secret, bool accept_invalid) throws AccountsError {
            var http = new HttpProbe(accept_invalid);
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("OCS-APIRequest", "true");
            headers.insert("Accept", "application/json");
            var who = yield http.request("GET", r.server + "/ocs/v2.php/cloud/user?format=json", HttpProbe.basic(user, secret), null, null, headers);
            if (who.status == 401 || who.status == 403) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            if (who.status == 404) throw new AccountsError.PROTOCOL(_("%s is not a Nextcloud or ownCloud server").printf(Providers.host_of(r.server)));
            if (who.status != 200) throw new AccountsError.PROTOCOL(_("The server answered HTTP %u").printf(who.status));
            try {
                var parser = new Json.Parser();
                parser.load_from_data(who.body);
                var data = parser.get_root().get_object().get_object_member("ocs").get_object_member("data");
                if (data.has_member("id")) {
                    r.endpoints["dav-user"] = data.get_string_member("id");
                }
                if (data.has_member("display-name") && data.get_member("display-name").get_node_type() == Json.NodeType.VALUE) {
                    r.display_name = data.get_string_member("display-name");
                }
            } catch (Error e) {
            }
            string[] caps = { "calendar", "contacts", "tasks", "files" };
            var caps_reply = yield http.request("GET", r.server + "/ocs/v2.php/cloud/capabilities?format=json", HttpProbe.basic(user, secret), null, null, headers);
            if (caps_reply.status == 200 && caps_reply.body.contains("\"notes\"")) {
                caps += "notes";
                r.endpoints["notes"] = r.server + "/index.php/apps/notes/api/v1/";
            }
            if (r.provider == "nextcloud") {
                caps += "photos";
                caps += "music";
                caps += "videos";
                r.endpoints["music-api"] = "webdav";
                r.endpoints["videos-api"] = "webdav";
                if (caps_reply.status == 200 && caps_reply.body.contains("\"spreed\"")) {
                    caps += "chat";
                    r.endpoints["chat-api"] = "talk";
                }
            }
            r.capabilities = caps;
            if (r.display_name != "") r.display_name = "%s (%s)".printf(r.display_name, Providers.host_of(r.server));
            Providers.apply_defaults(r, null);
        }

        private const string AUTODISCOVER = """<?xml version="1.0" encoding="utf-8"?><Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006"><Request><EMailAddress>%s</EMailAddress><AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema></Request></Autodiscover>""";

        private const string EWS_PROBE = """<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"><soap:Header><t:RequestServerVersion Version="Exchange2013"/></soap:Header><soap:Body><m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds><t:DistinguishedFolderId Id="calendar"/></m:FolderIds></m:GetFolder></soap:Body></soap:Envelope>""";

        private static string? find_tag(string xml, string tag) {
            try {
                var re = new Regex("<([a-zA-Z0-9]+:)?" + tag + ">\\s*([^<\\s]+)\\s*</");
                MatchInfo info;
                if (re.match(xml, 0, out info)) return info.fetch(2);
            } catch (RegexError e) {
            }
            return null;
        }

        private async void prepare_exchange(AccountRecord r, HashTable<string, Variant> settings, string user, string secret, bool accept_invalid) throws AccountsError {
            var http = new HttpProbe(accept_invalid);
            string domain = r.identity.substring(r.identity.index_of("@") + 1);
            string server = setting(settings, "server");
            string[] candidates = {};
            if (server != "") {
                string base_url = Providers.normalize_server(server);
                candidates += base_url + "/autodiscover/autodiscover.xml";
            }
            candidates += "https://%s/autodiscover/autodiscover.xml".printf(domain);
            candidates += "https://autodiscover.%s/autodiscover/autodiscover.xml".printf(domain);
            string ews = "";
            bool refused = false;
            foreach (string url in candidates) {
                try {
                    var reply = yield http.request("POST", url, HttpProbe.basic(user, secret), "text/xml; charset=utf-8", AUTODISCOVER.printf(Markup.escape_text(r.identity)));
                    if (reply.status == 401) refused = true;
                    if (reply.status != 200) continue;
                    string? found = find_tag(reply.body, "EwsUrl");
                    if (found != null) {
                        ews = found;
                        break;
                    }
                } catch (AccountsError e) {
                    debug("autodiscover %s: %s", url, e.message);
                }
            }
            if (ews == "" && server != "") ews = Providers.normalize_server(server) + "/EWS/Exchange.asmx";
            if (ews == "") {
                if (refused) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
                throw new AccountsError.PROTOCOL(_("Could not find the Exchange server for %s. Enter the server name.").printf(domain));
            }
            var probe = yield http.request("POST", ews, HttpProbe.basic(user, secret), "text/xml; charset=utf-8", EWS_PROBE);
            if (probe.status == 401) {
                string challenge = probe.headers != null ? (probe.headers.get_list("WWW-Authenticate") ?? "") : "";
                if (challenge.contains("NTLM") && !challenge.contains("Basic")) {
                    throw new AccountsError.AUTH_FAILED(_("The Exchange server only accepts Windows (NTLM) sign-in, which Singularity cannot check yet"));
                }
                throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            }
            if (probe.status != 200 || !probe.body.contains("NoError")) {
                throw new AccountsError.PROTOCOL(_("The Exchange server answered HTTP %u").printf(probe.status));
            }
            r.server = ews;
            r.endpoints["ews"] = ews;
            r.endpoints["calendar-api"] = "ews";
            r.endpoints["dav-user"] = user;
            r.capabilities = { "calendar" };
        }

        public async string add_account(string provider, HashTable<string, Variant> settings, string secret) throws AccountsError {
            touched();
            var r = yield prepare(provider, settings, secret);
            if (store.find_identity(r.provider, r.identity, r.server) != null) {
                throw new AccountsError.INVALID(_("%s is already added").printf(r.identity));
            }
            r.id = store.new_id();
            r.created = get_real_time() / 1000000;
            r.enabled = Providers.default_enabled(r.provider, r.capabilities);
            yield Secrets.store(r, "password", secret);
            store.accounts.add(r);
            persist();
            account_added(r.id);
            return r.id;
        }

        public async void update_password(string id, string secret) throws AccountsError {
            var r = require(id);
            if (r.auth != "password") throw new AccountsError.INVALID(_("%s signs in through the browser").printf(r.identity));
            var s = new HashTable<string, Variant>(str_hash, str_equal);
            s.insert("email", r.endpoint("mail-address", r.identity));
            s.insert("username", r.provider == "imap" || r.provider == "proton" || r.provider == "google" ? r.endpoint("imap-user", r.identity) : r.endpoint("dav-user", r.identity));
            s.insert("server", r.provider == "exchange" ? r.endpoint("ews") : r.server);
            foreach (string k in new string[] { "imap-host", "imap-port", "imap-security", "smtp-host", "smtp-port", "smtp-security" }) {
                if (r.endpoints.has_key(k)) s.insert(k, r.endpoints[k]);
            }
            if (r.endpoint("tls-accept-invalid") == "true") s.insert("accept-invalid-tls", true);
            if (r.provider == "exchange") {
                s.remove("imap-host");
                if (r.endpoints.has_key("imap-host")) s.insert("imap-host", r.endpoints["imap-host"]);
            }
            yield prepare(r.provider, s, secret);
            yield Secrets.store(r, "password", secret);
            clear_attention(r);
            account_changed(id);
        }

        public async void begin_sign_in(string provider, HashTable<string, Variant> settings, out string flow_id, out string url) throws AccountsError {
            flow_id = "";
            url = "";
            touched();
            string reauth = setting(settings, "account");
            AccountRecord? existing = reauth != "" ? require(reauth) : null;
            SignInFlow flow;
            if (provider == "google" || provider == "microsoft" || provider == "spotify") {
                var oauth = new OAuthFlow(provider, OAuthConfig.load(provider));
                if (provider == "google" || provider == "microsoft") oauth.capabilities = wanted_capabilities(provider, settings, existing);
                flow = oauth;
            } else if (provider == "nextcloud") {
                string server = Providers.normalize_server(setting(settings, "server", existing != null ? existing.server : ""));
                if (server == "") throw new AccountsError.INVALID(_("Enter the server address"));
                bool accept_invalid = setting(settings, "accept-invalid-tls") == "true" || (existing != null && existing.endpoint("tls-accept-invalid") == "true");
                flow = new NextcloudFlow(server, accept_invalid);
            } else {
                throw new AccountsError.INVALID(_("Accounts of type %s do not sign in through the browser").printf(provider));
            }
            flow.reauth_id = reauth;
            url = yield flow.start();
            flows[flow.id] = flow;
            flow_id = flow.id;
            flow.completed.connect((result, error_message) => {
                flows.unset(flow.id);
                complete_flow.begin(flow, result, error_message);
            });
        }

        private static string[] wanted_capabilities(string provider, HashTable<string, Variant> settings, AccountRecord? existing) {
            var wanted = new Gee.ArrayList<string>();
            if (existing != null) {
                foreach (string c in existing.enabled) if (!wanted.contains(c)) wanted.add(c);
                foreach (string c in existing.capabilities) {
                    if (!Providers.needs_consent(provider, c) && !wanted.contains(c)) wanted.add(c);
                }
                string pending = existing.endpoint("pending-consent");
                if (pending != "" && !wanted.contains(pending)) wanted.add(pending);
                if (existing.endpoint("mail-fallback") == "imap" && !wanted.contains(Providers.MICROSOFT_IMAP_FALLBACK)) wanted.add(Providers.MICROSOFT_IMAP_FALLBACK);
            } else {
                foreach (string c in Providers.default_capabilities(provider)) wanted.add(c);
            }
            foreach (string c in setting(settings, "capabilities").split(",")) {
                if (c.strip() != "" && !wanted.contains(c.strip())) wanted.add(c.strip());
            }
            return wanted.to_array();
        }

        public string get_sign_in_helper() throws AccountsError {
            touched();
            string? env = Environment.get_variable("SINGULARITY_ACCOUNTS_SIGNIN");
            if (env != null && FileUtils.test(env, FileTest.IS_EXECUTABLE)) return env;
            try {
                string self = FileUtils.read_link("/proc/self/exe");
                string helper = Path.build_filename(Path.get_dirname(self), "singularity-accounts-signin");
                if (FileUtils.test(helper, FileTest.IS_EXECUTABLE)) return helper;
            } catch (FileError e) {
            }
            return "";
        }

        public void complete_sign_in(string flow_id, string address) throws AccountsError {
            touched();
            var flow = flows[flow_id] as OAuthFlow;
            if (flow == null) throw new AccountsError.NOT_FOUND(_("There is no browser sign-in %s waiting").printf(flow_id));
            flow.complete_from_address(address);
        }

        public void cancel_sign_in(string flow_id) throws AccountsError {
            touched();
            var flow = flows[flow_id];
            if (flow == null) throw new AccountsError.NOT_FOUND(_("There is no sign-in %s").printf(flow_id));
            flow.cancel();
        }

        private async void complete_flow(SignInFlow flow, SignInResult? result, string error_message) {
            touched();
            if (result == null) {
                sign_in_finished(flow.id, "", error_message != "" ? error_message : _("The sign-in failed."));
                return;
            }
            try {
                string id = flow.provider == "nextcloud"
                    ? yield finish_nextcloud(flow, result)
                    : yield finish_oauth(flow, result);
                sign_in_finished(flow.id, id, "");
            } catch (Error e) {
                sign_in_finished(flow.id, "", e.message);
            }
        }

        private async string finish_oauth(SignInFlow flow, SignInResult result) throws AccountsError {
            var client = OAuthConfig.load(flow.provider);
            AccountRecord? r = null;
            if (flow.reauth_id != "") {
                r = require(flow.reauth_id);
                if (r.identity.down() != result.identity.down()) {
                    throw new AccountsError.INVALID(_("You signed in as %s, but this account is %s.").printf(result.identity, r.identity));
                }
            } else {
                r = store.find_identity(flow.provider, result.identity, "");
            }
            bool created = r == null;
            if (created) {
                var info = Providers.find(flow.provider);
                r = new AccountRecord();
                r.id = store.new_id();
                r.provider = flow.provider;
                r.auth = "oauth2";
                r.identity = result.identity;
                r.display_name = result.identity;
                r.created = get_real_time() / 1000000;
                r.capabilities = info.capabilities;
                r.enabled = Providers.default_capabilities(flow.provider);
                Providers.apply_defaults(r, client);
            }
            if (flow.provider == "spotify" && result.server != "") r.endpoints["spotify-product"] = result.server;
            if (result.tokens != null && result.tokens.scope != "") {
                string granted = r.endpoint("granted-scopes");
                foreach (string sc in result.tokens.scope.split(" ")) {
                    if (sc != "" && !Providers.has_scope(granted, sc)) granted = granted == "" ? sc : granted + " " + sc;
                }
                r.endpoints["granted-scopes"] = granted;
            }
            string imap_refused = flow.provider == "microsoft" ? yield settle_mail(r, client, result.secret) : "";
            string pending = r.endpoint("pending-consent");
            if (pending != "" && Providers.granted(r, pending)) {
                r.enable_capability(pending, true);
                r.endpoints.unset("pending-consent");
                credential_revision[r.id] = credential_revision[r.id] + 1;
            }
            yield Secrets.store(r, "refresh-token", result.secret);
            foreach (var k in tokens.keys.to_array()) {
                if (k.has_prefix(r.id + "|")) {
                    tokens.unset(k);
                    expiry.unset(k);
                }
            }
            if (result.tokens != null && flow.provider == "google") {
                int life = result.tokens.expires_in > 0 ? result.tokens.expires_in : 3600;
                tokens[r.id + "|default"] = result.tokens.access_token;
                expiry[r.id + "|default"] = get_real_time() / 1000000 + life - int.min(60, life / 4);
            }
            r.attention = "";
            if (created) store.accounts.add(r);
            persist();
            if (created) account_added(r.id);
            else account_changed(r.id);
            if (imap_refused != "") throw new AccountsError.PROTOCOL(imap_refused);
            return r.id;
        }

        [DBus (visible = false)]
        public async string settle_mail(AccountRecord r, OAuthClient client, string refresh_token) {
            bool wants_imap = r.endpoint("pending-consent") == Providers.MICROSOFT_IMAP_FALLBACK || r.endpoint("mail-fallback") == "imap";
            if (r.endpoint("pending-consent") == Providers.MICROSOFT_IMAP_FALLBACK) r.endpoints.unset("pending-consent");
            if (!wants_imap) {
                if (Providers.legacy_imap_mail(r) && Providers.graph_mail_granted(r)) Providers.use_graph_mail(r);
                return "";
            }
            try {
                var ts = yield new TokenClient().refresh(client, refresh_token, Providers.MICROSOFT_MAIL_SCOPES);
                if (ts.scope != "") Providers.merge_granted(r, ts.scope);
                Providers.merge_granted(r, "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send");
                Providers.use_imap_mail(r);
                return "";
            } catch (Error e) {
                Providers.use_graph_mail(r);
                return _("You are signed in, but %s does not allow IMAP and SMTP. Mail keeps using Microsoft Graph.").printf(r.identity);
            }
        }

        private async string finish_nextcloud(SignInFlow flow, SignInResult result) throws AccountsError {
            var nc = (NextcloudFlow) flow;
            var probe = new AccountRecord();
            probe.provider = "nextcloud";
            probe.server = result.server != "" ? result.server : nc.server;
            probe.identity = result.login_name;
            probe.endpoints["dav-user"] = result.login_name;
            if (nc.accept_invalid) probe.endpoints["tls-accept-invalid"] = "true";
            yield describe_cloud(probe, result.login_name, result.secret, nc.accept_invalid);
            AccountRecord? r = null;
            if (flow.reauth_id != "") {
                r = require(flow.reauth_id);
                if (r.identity.down() != result.login_name.down()) {
                    throw new AccountsError.INVALID(_("You signed in as %s, but this account is %s.").printf(result.login_name, r.identity));
                }
            } else {
                r = store.find_identity("nextcloud", result.login_name, probe.server);
            }
            bool created = r == null;
            if (created) {
                r = probe;
                r.id = store.new_id();
                r.created = get_real_time() / 1000000;
                r.enabled = Providers.default_enabled(r.provider, r.capabilities);
            }
            yield Secrets.store(r, "password", result.secret);
            r.attention = "";
            if (created) store.accounts.add(r);
            persist();
            if (created) account_added(r.id);
            else account_changed(r.id);
            return r.id;
        }

        public void report_problem(string id, string capability, string reason) throws AccountsError {
            var r = require(id);
            foreach (var k in tokens.keys.to_array()) {
                if (k.has_prefix(id + "|")) {
                    tokens.unset(k);
                    expiry.unset(k);
                }
            }
            mark_attention(r, reason == "" ? "reauth" : reason);
        }

        public void set_oauth_client(string provider, string client_id, string client_secret) throws AccountsError {
            touched();
            if (provider != "google" && provider != "microsoft" && provider != "spotify") throw new AccountsError.INVALID(_("%s does not use an OAuth client").printf(provider));
            try {
                OAuthConfig.store_user(provider, client_id, client_secret);
            } catch (Error e) {
                throw new AccountsError.UNAVAILABLE(e.message);
            }
        }
    }
}
