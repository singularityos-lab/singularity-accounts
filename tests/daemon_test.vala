using Singularity.AccountsDaemon;

void check(bool ok, string label) {
    if (!ok) {
        stderr.printf("FAILED: %s\n", label);
        assert_not_reached();
    }
}

void test_pkce_rfc7636_vector() {
    check(Pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge");
    string v = Pkce.verifier();
    check(v.length >= 43 && v.length <= 128, "verifier length");
    check(!v.contains("+") && !v.contains("/") && !v.contains("="), "verifier alphabet");
}

string jwt(string payload) {
    return base64url("{\"alg\":\"none\"}".data) + "." + base64url(payload.data) + ".";
}

void test_id_token_identity() {
    var t = new TokenSet();
    t.id_token = jwt("{\"sub\":\"1\",\"email\":\"tester@gmail.test\",\"name\":\"Test Google\"}");
    check(t.identity() == "tester@gmail.test", "google email");
    check(t.display_name() == "Test Google", "name");
    t.id_token = jwt("{\"sub\":\"2\",\"preferred_username\":\"tester@outlook.test\"}");
    check(t.identity() == "tester@outlook.test", "microsoft preferred_username");
    t.id_token = "garbage";
    check(t.identity() == "", "invalid jwt");
}

void test_token_parse() {
    try {
        var t = TokenSet.parse("{\"access_token\":\"abc\",\"expires_in\":\"120\",\"refresh_token\":\"r1\",\"token_type\":\"Bearer\"}");
        check(t.access_token == "abc" && t.expires_in == 120 && t.refresh_token == "r1", "string expires_in");
        t = TokenSet.parse("{\"access_token\":\"x\",\"expires_in\":3599}");
        check(t.expires_in == 3599 && t.refresh_token == "", "numeric expires_in");
    } catch (Error e) {
        check(false, e.message);
    }
    bool threw = false;
    try {
        TokenSet.parse("{\"token_type\":\"Bearer\"}");
    } catch (Error e) {
        threw = true;
    }
    check(threw, "missing access token throws");
}

void test_records_roundtrip() {
    string dir = "";
    try {
        dir = DirUtils.make_tmp("accounts-test-XXXXXX");
    } catch (Error e) {
        check(false, e.message);
    }
    string path = Path.build_filename(dir, "accounts.json");
    var store = new AccountStore(path);
    var r = new AccountRecord();
    r.id = store.new_id();
    r.provider = "nextcloud";
    r.identity = "alice";
    r.server = "https://cloud.example";
    r.capabilities = { "calendar", "contacts", "files" };
    r.enabled = { "calendar", "files" };
    r.endpoints["caldav"] = "https://cloud.example/remote.php/dav/";
    store.accounts.add(r);
    try {
        store.save();
    } catch (Error e) {
        check(false, e.message);
    }
    var again = new AccountStore(path);
    var back = again.find(r.id);
    check(back != null, "record reloaded");
    check(back.identity == "alice" && back.server == "https://cloud.example", "fields");
    check(back.capabilities.length == 3 && "contacts" in back.capabilities, "capabilities");
    check(back.enabled.length == 2 && !("contacts" in back.enabled), "enabled");
    check(back.endpoint("caldav") == "https://cloud.example/remote.php/dav/", "endpoint");
    back.enable_capability("contacts", true);
    check("contacts" in back.enabled, "enable");
    back.enable_capability("files", false);
    check(!("files" in back.enabled) && "calendar" in back.enabled, "disable keeps others");
    check(again.find_identity("nextcloud", "ALICE", "https://cloud.example") != null, "identity lookup is case insensitive");
    var v = back.to_variant(Providers.find("nextcloud"));
    check(v.lookup("icon").get_string() == "singularity-account-nextcloud", "variant icon");
    check(v.lookup("endpoints").is_of_type(new VariantType("a{ss}")), "variant endpoints");
    FileUtils.unlink(path);
    DirUtils.remove(dir);
}

void test_oauth_config_files() {
    string dir = "";
    try {
        dir = DirUtils.make_tmp("oauth-test-XXXXXX");
    } catch (Error e) {
        check(false, e.message);
    }
    string path = Path.build_filename(dir, "clients.json");
    try {
        FileUtils.set_contents(path, """{"google":{"installed":{"client_id":"g-id","client_secret":"g-secret","auth_uri":"http://127.0.0.1:18081/o/oauth2/v2/auth","token_uri":"http://127.0.0.1:18081/token"}},"microsoft":{"client_id":"m-id","tenant":"organizations","endpoints":{"graph":"http://127.0.0.1:18084/v1.0/","imap-port":993}}}""");
    } catch (Error e) {
        check(false, e.message);
    }
    var g = new OAuthClient();
    g.provider = "google";
    OAuthConfig.apply_file(g, path);
    check(g.configured && g.client_id == "g-id" && g.client_secret == "g-secret", "google installed format");
    check(g.token_uri == "http://127.0.0.1:18081/token", "google token uri");
    var m = new OAuthClient();
    m.provider = "microsoft";
    OAuthConfig.apply_file(m, path);
    check(m.client_id == "m-id" && m.client_secret == "", "microsoft public client");
    check(m.auth_uri.contains("/organizations/oauth2/v2.0/authorize"), "tenant");
    check(m.endpoints["graph"] == "http://127.0.0.1:18084/v1.0/" && m.endpoints["imap-port"] == "993", "endpoint overrides");
    var none = new OAuthClient();
    none.provider = "google";
    OAuthConfig.apply_file(none, Path.build_filename(dir, "missing.json"));
    check(!none.configured, "missing file leaves it unconfigured");
    FileUtils.unlink(path);
    DirUtils.remove(dir);
}

void test_provider_defaults() {
    check(Providers.normalize_server("cloud.example.com/") == "https://cloud.example.com", "normalize adds https");
    check(Providers.normalize_server("http://127.0.0.1:18080/index.php") == "http://127.0.0.1:18080", "normalize strips index.php");
    var r = new AccountRecord();
    r.provider = "google";
    r.auth = "oauth2";
    r.identity = "tester@gmail.test";
    var client = new OAuthClient();
    client.endpoints["imap-host"] = "127.0.0.1";
    Providers.apply_defaults(r, client);
    check(r.endpoint("caldav") == "https://apidata.googleusercontent.com/caldav/v2/tester@gmail.test/user", "google caldav template");
    check(r.endpoint("imap-host") == "127.0.0.1", "override wins");
    check(r.endpoint("mail-auth") == "xoauth2" && r.endpoint("tasks-api") == "google", "google apis");
    var n = new AccountRecord();
    n.provider = "nextcloud";
    n.server = "https://cloud.example";
    n.identity = "alice";
    Providers.apply_defaults(n, null);
    check(n.endpoint("webdav") == "https://cloud.example/remote.php/dav/files/alice/", "nextcloud webdav");
    check(Providers.resource_for("microsoft", "mail") == "mail" && Providers.resource_for("microsoft", "files") == "graph", "microsoft resources");
    check(Providers.scopes_for("microsoft", "mail").contains("IMAP.AccessAsUser.All"), "mail scopes");
    check(!Providers.scopes_for("microsoft", "graph").contains("outlook.office.com"), "graph scopes do not mix resources");
    check(Providers.resource_for("microsoft", "mail-graph") == "graph-mail", "Graph mail has a separate token cache");
    string[] graph_mail = Providers.scopes_for("microsoft", "graph-mail").split(" ");
    check("https://graph.microsoft.com/Mail.ReadWrite" in graph_mail, "Graph mail can read and change messages");
    check("https://graph.microsoft.com/Mail.Send" in graph_mail, "Graph mail can send messages");
    check("https://graph.microsoft.com/MailboxSettings.ReadWrite" in graph_mail, "Graph mail can change rules");
    check(!("https://outlook.office.com/SMTP.Send" in graph_mail), "Graph Mail refresh excludes SMTP resource");
    check(!("https://graph.microsoft.com/Files.ReadWrite" in graph_mail), "Graph Mail token does not request Files access");
    check(!Providers.scopes_for("microsoft", "graph").contains("/Mail."), "ordinary Graph refresh does not expand Mail consent");
    check(!Providers.scopes_for("microsoft", "graph-mail").contains(".Shared") && !Providers.scopes_for("microsoft", "graph").contains(".Shared"), "refresh skips shared scopes that were never granted");
    string partly = "openid Mail.ReadWrite.Shared https://graph.microsoft.com/calendars.readwrite.shared";
    string mail_refresh = Providers.scopes_for("microsoft", "graph-mail", partly);
    check(mail_refresh.contains("https://graph.microsoft.com/Mail.ReadWrite.Shared") && !mail_refresh.contains("Mail.Send.Shared"), "Graph Mail refresh keeps the granted shared mailbox scope");
    string graph_refresh = Providers.scopes_for("microsoft", "graph", partly);
    check(graph_refresh.contains("Calendars.ReadWrite.Shared") && !graph_refresh.contains("Contacts.ReadWrite.Shared") && !graph_refresh.contains("Mail."), "Graph refresh keeps only its granted shared scopes");
    var m = new AccountRecord();
    m.provider = "microsoft";
    m.auth = "oauth2";
    m.identity = "tester@outlook.test";
    Providers.apply_defaults(m, null);
    check(m.endpoint("mail-api") == "graph", "new Microsoft accounts use Graph mail");
    m.endpoints["mail-api"] = "imap";
    Providers.apply_defaults(m, null);
    check(m.endpoint("mail-api") == "imap", "existing mail protocol is kept");
    var legacy = new AccountRecord();
    legacy.provider = "microsoft";
    legacy.auth = "oauth2";
    legacy.capabilities = { "mail", "files" };
    Providers.upgrade(legacy);
    check(legacy.endpoint("mail-api") == "", "account upgrade does not migrate existing mail caches");
}

void test_dav_probe_parsing() {
    string xml = """<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/dav/principals/alice/</d:href></d:current-user-principal><cal:calendar-home-set><d:href>/dav/calendars/alice/</d:href></cal:calendar-home-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>""";
    check(DavProbe.has_home(xml, "calendar-home-set"), "calendar home found");
    check(!DavProbe.has_home(xml, "addressbook-home-set"), "no address book home");
    check(DavProbe.principal_href(xml) == "/dav/principals/alice/", "principal");
    string empty = """<multistatus xmlns="DAV:"><response><href>/</href><propstat><prop><calendar-home-set xmlns="urn:ietf:params:xml:ns:caldav"/></prop><status>HTTP/1.1 404 Not Found</status></propstat></response></multistatus>""";
    check(!DavProbe.has_home(empty, "calendar-home-set"), "empty home is not a home");
}

async void check_app_data_authorization() throws Error {
    foreach (string provider in new string[] { "google", "microsoft" }) {
        var client = new OAuthClient();
        client.provider = provider;
        client.client_id = "consent-test";
        client.auth_uri = "https://sign-in.example/authorize";
        var flow = new OAuthFlow(provider, client);
        string url = yield flow.start();
        flow.cancel();
        var uri = Uri.parse(url, UriFlags.NONE);
        var query = Uri.parse_params(uri.get_query(), -1, "&", UriParamsFlags.NONE);
        string[] scopes = query.lookup("scope").split(" ");
        check(uri.get_host() == "sign-in.example", "authorization endpoint kept");
        check(query.lookup("code_challenge_method") == "S256", "consent keeps PKCE");
        check(query.lookup("state") != "", "consent keeps state");
        if (provider == "google") {
            check("https://www.googleapis.com/auth/drive.appdata" in scopes, "Google application data requested");
            check("https://www.googleapis.com/auth/drive" in scopes, "Google Files access kept");
            check("https://mail.google.com/" in scopes, "Google Mail access kept");
            check(query.lookup("prompt") == "consent", "Google re-sign-in requests consent");
        } else {
            check("https://graph.microsoft.com/Files.ReadWrite.AppFolder" in scopes, "Microsoft application folder requested");
            check("https://graph.microsoft.com/Files.ReadWrite" in scopes, "Microsoft Files access kept");
            check(!("https://outlook.office.com/IMAP.AccessAsUser.All" in scopes), "Microsoft sign-in does not ask for IMAP");
            check(!("https://outlook.office.com/SMTP.Send" in scopes), "Microsoft sign-in does not ask for SMTP");
            foreach (string shared in new string[] { "Mail.ReadWrite.Shared", "Mail.Send.Shared", "Calendars.ReadWrite.Shared", "Contacts.ReadWrite.Shared" }) {
                check("https://graph.microsoft.com/" + shared in scopes, "Microsoft sign-in asks for " + shared);
            }
            var fallback = new OAuthFlow(provider, client);
            fallback.capabilities = { "mail", Providers.MICROSOFT_IMAP_FALLBACK };
            string fallback_url = yield fallback.start();
            fallback.cancel();
            string[] fallback_scopes = Uri.parse_params(Uri.parse(fallback_url, UriFlags.NONE).get_query(), -1, "&", UriParamsFlags.NONE).lookup("scope").split(" ");
            check("https://outlook.office.com/IMAP.AccessAsUser.All" in fallback_scopes && "https://outlook.office.com/SMTP.Send" in fallback_scopes, "IMAP fallback consent asks for IMAP and SMTP");
            check("https://graph.microsoft.com/Mail.ReadWrite" in scopes, "Microsoft Graph Mail requested");
            check("https://graph.microsoft.com/Mail.Send" in scopes, "Microsoft Graph sending requested");
            check("https://graph.microsoft.com/MailboxSettings.ReadWrite" in scopes, "Microsoft Graph rules requested");
            string[] refresh_scopes = Providers.scopes_for(provider, "graph").split(" ");
            check("https://graph.microsoft.com/Files.ReadWrite" in refresh_scopes, "existing Graph refresh kept");
            check(!("https://graph.microsoft.com/Files.ReadWrite.AppFolder" in refresh_scopes), "ordinary refresh does not expand consent");
            check(!("https://outlook.office.com/IMAP.AccessAsUser.All" in refresh_scopes), "Graph refresh stays on its resource");
            string[] mail_scopes = Providers.scopes_for(provider, "mail").split(" ");
            check(!("https://graph.microsoft.com/Files.ReadWrite.AppFolder" in mail_scopes), "Mail refresh stays on its resource");
        }
    }
}

void test_app_data_authorization() {
    var loop = new MainLoop();
    check_app_data_authorization.begin((obj, res) => {
        try {
            check_app_data_authorization.end(res);
        } catch (Error e) {
            check(false, e.message);
        }
        loop.quit();
    });
    loop.run();
}

async void check_graph_mail_gate() throws Error {
    string dir = DirUtils.make_tmp("graph-mail-gate-XXXXXX");
    var store = new AccountStore(Path.build_filename(dir, "accounts.json"));
    foreach (string id in new string[] { "disabled", "unsupported", "google", "password" }) {
        var record = new AccountRecord();
        record.id = id;
        record.provider = id == "google" ? "google" : "microsoft";
        record.auth = id == "password" ? "password" : "oauth2";
        record.capabilities = id == "unsupported" ? new string[] { "files", "photos" } : new string[] { "mail", "photos" };
        record.enabled = id == "disabled" ? new string[] { "photos" } : record.capabilities;
        store.accounts.add(record);
    }
    var service = new Service(store);
    foreach (var record in store.accounts) {
        bool rejected = false;
        try {
            string token;
            int expires;
            yield service.get_access_token(record.id, "mail-graph", false, out token, out expires);
        } catch (AccountsError.INVALID e) {
            rejected = true;
        }
        check(rejected, "Graph Mail gate rejects " + record.id + " before accessing the keyring");
        check(record.attention == "", "invalid route does not mark the account for sign-in");
        foreach (string capability in new string[] { "unknown", "calendar", record.id == "disabled" ? "mail" : "unknown" }) {
            foreach (bool refresh in new bool[] { false, true }) {
                rejected = false;
                try {
                    string token;
                    int expires;
                    yield service.get_access_token(record.id, capability, refresh, out token, out expires);
                } catch (AccountsError.INVALID e) {
                    rejected = true;
                }
                check(rejected, "generic token gate rejects " + record.id + " " + capability);
            }
            rejected = false;
            try {
                string username;
                string secret;
                string mechanism;
                yield service.get_credentials(record.id, capability, out username, out secret, out mechanism);
            } catch (AccountsError.INVALID e) {
                rejected = true;
            }
            check(rejected && record.attention == "", "generic credentials gate rejects before keyring access");
        }
    }
    DirUtils.remove(dir);
}

void test_graph_mail_gate() {
    var loop = new MainLoop();
    check_graph_mail_gate.begin((obj, res) => {
        try {
            check_graph_mail_gate.end(res);
        } catch (Error e) {
            check(false, e.message);
        }
        loop.quit();
    });
    loop.run();
}

async void check_credential_refresh_gate() throws Error {
    string dir = DirUtils.make_tmp("credential-gate-XXXXXX");
    var store = new AccountStore(Path.build_filename(dir, "accounts.json"));
    var record = new AccountRecord();
    record.id = "synthetic-refresh";
    record.identity = "fixture@example.test";
    record.provider = "microsoft";
    record.auth = "oauth2";
    record.capabilities = { "mail", "files" };
    record.enabled = record.capabilities;
    Providers.use_imap_mail(record);
    store.accounts.add(record);
    var service = new Service(store);
    yield Secrets.store(record, "refresh-token", "synthetic-refresh-token");
    int requests = 0;
    bool hold = false;
    Soup.ServerMessage? pending = null;
    var server = new Soup.Server("server-header", "Account capability fixture");
    server.add_handler("/token", (srv, message, path, query) => {
        requests++;
        message.set_status(200, null);
        message.set_response("application/json", Soup.MemoryUse.COPY,
            ("{\"access_token\":\"synthetic-" + requests.to_string() + "\",\"expires_in\":3600}").data);
        if (hold) {
            message.pause();
            pending = message;
        }
    });
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    string uri = server.get_uris().data.to_string() + "token";
    string config = OAuthConfig.user_path();
    string original = "";
    bool had_config = FileUtils.test(config, FileTest.EXISTS);
    if (had_config) FileUtils.get_contents(config, out original);
    DirUtils.create_with_parents(Path.get_dirname(config), 0700);
    FileUtils.set_contents(config, "{\"microsoft\":{\"client_id\":\"synthetic-client\",\"token_uri\":\"" + uri + "\"}}");
    Error? failure = null;
    try {
        foreach (string cap in new string[] { "mail", "mail-graph", "files" }) {
            string token;
            int expires;
            yield service.get_access_token(record.id, cap, false, out token, out expires);
            int count = requests;
            string first = token;
            yield service.get_access_token(record.id, cap, false, out token, out expires);
            check(requests == count && token == first, "daemon cache is warm for " + cap);
            string toggle = cap == "files" ? "files" : "mail";
            service.set_capability_enabled(record.id, toggle, false);
            bool rejected = false;
            token = "";
            expires = 0;
            try {
                yield service.get_access_token(record.id, cap, false, out token, out expires);
            } catch (AccountsError.INVALID e) { rejected = true; }
            check(rejected && (token == null || token == "") && expires == 0 && requests == count, "disabled daemon cache refuses " + cap);
            service.set_capability_enabled(record.id, toggle, true);
            yield service.get_access_token(record.id, cap, false, out token, out expires);
            check(requests == count + 1 && token != first, "re-enabled capability fetches a fresh token");
            foreach (bool reenable in new bool[] { false, true }) {
                hold = true;
                pending = null;
                int finished = 0;
                int denied = 0;
                service.get_access_token.begin(record.id, cap, true, (obj, res) => {
                    string received;
                    int life;
                    try { service.get_access_token.end(res, out received, out life); }
                    catch (AccountsError.INVALID e) { denied++; }
                    catch (Error e) { check(false, e.message); }
                    finished++;
                });
                int64 deadline = get_monotonic_time() + 5000000;
                while (pending == null && get_monotonic_time() < deadline) {
                    Timeout.add(10, check_credential_refresh_gate.callback);
                    yield;
                }
                check(pending != null, "refresh reached the private HTTP server");
                service.get_access_token.begin(record.id, cap, false, (obj, res) => {
                    string received;
                    int life;
                    try { service.get_access_token.end(res, out received, out life); }
                    catch (AccountsError.INVALID e) { denied++; }
                    catch (Error e) { check(false, e.message); }
                    finished++;
                });
                Timeout.add(30, check_credential_refresh_gate.callback);
                yield;
                service.set_capability_enabled(record.id, toggle, false);
                if (reenable) service.set_capability_enabled(record.id, toggle, true);
                hold = false;
                pending.unpause();
                while (finished != 2 && get_monotonic_time() < deadline) {
                    Timeout.add(10, check_credential_refresh_gate.callback);
                    yield;
                }
                check(finished == 2 && denied == 2, "in-flight and queued refresh refuse after the capability changes");
                service.set_capability_enabled(record.id, toggle, true);
                count = requests;
                yield service.get_access_token(record.id, cap, false, out token, out expires);
                check(requests == count + 1, "refused refresh is not cached");
            }
        }
    } catch (Error e) {
        failure = e;
    }
    server.disconnect();
    yield Secrets.clear(record.id);
    if (had_config) FileUtils.set_contents(config, original);
    else FileUtils.unlink(config);
    FileUtils.unlink(store.path);
    DirUtils.remove(dir);
    if (failure != null) throw failure;
}

void test_credential_refresh_gate() {
    if (Environment.get_variable("ACCOUNTS_TEST_KEYRING") != "1") {
        Test.skip("Requires the isolated Secret Service fixture");
        return;
    }
    var loop = new MainLoop();
    check_credential_refresh_gate.begin((obj, res) => {
        try { check_credential_refresh_gate.end(res); }
        catch (Error e) { check(false, e.message); }
        loop.quit();
    });
    loop.run();
}

void test_client_priority() {
    string data_dir = Path.build_filename(Environment.get_variable("ACCOUNTS_TEST_DATA"), "singularity");
    DirUtils.create_with_parents(data_dir, 0700);
    string dist = Path.build_filename(data_dir, "oauth-clients.json");
    try {
        FileUtils.set_contents(dist, """{"google":{"client_id":"dist-id","client_secret":"dist-secret"}}""");
        FileUtils.unlink(OAuthConfig.user_path());
    } catch (Error e) {
        check(false, e.message);
    }
    check(OAuthConfig.kind_of("/etc/singularity/oauth-clients.json") == "system", "etc is system");
    check(OAuthConfig.kind_of(OAuthConfig.user_path()) == "user", "user path");
    var etc_google = new OAuthClient();
    etc_google.provider = "google";
    OAuthConfig.apply_file(etc_google, "/etc/singularity/oauth-clients.json");
    var etc_ms = new OAuthClient();
    etc_ms.provider = "microsoft";
    OAuthConfig.apply_file(etc_ms, "/etc/singularity/oauth-clients.json");
    string fallback = etc_google.configured ? "system" : "distribution";
    var c = OAuthConfig.load("google");
    check(c.source_kind == fallback && (etc_google.configured || (c.client_id == "dist-id" && c.source == dist)), "distribution file wins over built in, /etc over both");
    try {
        OAuthConfig.store_user("google", "user-id", "user-secret");
    } catch (Error e) {
        check(false, e.message);
    }
    c = OAuthConfig.load("google");
    check(c.client_id == "user-id" && c.client_secret == "user-secret" && c.source_kind == "user", "user override wins");
    try {
        OAuthConfig.store_user("google", "", "");
    } catch (Error e) {
        check(false, e.message);
    }
    c = OAuthConfig.load("google");
    check(c.source_kind == fallback, "removing the override falls back");
    var m = OAuthConfig.load("microsoft");
    check(m.source_kind == (etc_ms.configured ? "system" : BuildConfig.MICROSOFT_CLIENT_ID != "" ? "built-in" : ""), "built in is the lowest source");
    var info = Providers.find("google").to_variant(c.configured, c);
    check(info.lookup("client-source").get_string() == fallback, "variant source");
    check(info.lookup("client-secret") == null, "secret never exported");
    FileUtils.unlink(dist);
}

string parse_or_error(string pasted, string redirect, string state) {
    try {
        return "code:" + Redirect.parse(pasted, redirect, state);
    } catch (AccountsError e) {
        if (e is AccountsError.CANCELLED) return "cancelled";
        if (e is AccountsError.AUTH_FAILED) return "provider-error";
        return "invalid";
    }
}

void test_redirect_paste() {
    string r = "http://127.0.0.1:40263/";
    check(parse_or_error("http://127.0.0.1:40263/?state=S1&code=4%2F0Ab&scope=email", r, "S1") == "code:4/0Ab", "valid address, code decoded");
    check(parse_or_error("  127.0.0.1:40263/?code=abc&state=S1  ", r, "S1") == "code:abc", "address without scheme and with spaces");
    check(parse_or_error("http://localhost:40263/?state=S1&code=abc", r, "S1") == "code:abc", "localhost equals 127.0.0.1");
    check(parse_or_error("http://127.0.0.1:40263/?state=OTHER&code=abc", r, "S1") == "invalid", "state mismatch refused");
    check(parse_or_error("http://127.0.0.1:40263/?code=abc", r, "S1") == "invalid", "missing state refused");
    check(parse_or_error("http://127.0.0.1:40263/?state=S1", r, "S1") == "invalid", "missing code refused");
    check(parse_or_error("http://127.0.0.1:40264/?state=S1&code=abc", r, "S1") == "invalid", "other port refused");
    check(parse_or_error("https://evil.example/?state=S1&code=abc", r, "S1") == "invalid", "other host refused");
    check(parse_or_error("http://127.0.0.1:40263/other?state=S1&code=abc", r, "S1") == "invalid", "other path refused");
    check(parse_or_error("http://127.0.0.1:40263/", r, "S1") == "invalid", "no query refused");
    check(parse_or_error("not an address at all", r, "S1") == "invalid", "garbage refused");
    check(parse_or_error("http://127.0.0.1:40263/?state=S1&error=access_denied", r, "S1") == "cancelled", "denied");
    check(parse_or_error("http://127.0.0.1:40263/?state=S1&error=server_error", r, "S1") == "provider-error", "provider error");
    check(parse_or_error("http://localhost:5555/?state=S1&code=x", "http://localhost:5555/", "S1") == "code:x", "microsoft loopback");
}

void test_redirect_match() {
    string r = "http://127.0.0.1:44957/";
    check(Redirect.is_redirect("http://127.0.0.1:44957/?state=a&code=b", r), "exact loopback");
    check(Redirect.is_redirect("http://localhost:44957/?code=b", r), "localhost counts");
    check(Redirect.is_redirect("http://[::1]:44957/?code=b", r), "ipv6 loopback counts");
    check(!Redirect.is_redirect("http://127.0.0.1:44958/?code=b", r), "other port");
    check(!Redirect.is_redirect("http://127.0.0.1:44957/other?code=b", r), "other path");
    check(!Redirect.is_redirect("https://127.0.0.1:44957/?code=b", r), "other scheme");
    check(!Redirect.is_redirect("https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A44957%2F", r), "authorize page is not the redirect");
    check(!Redirect.is_redirect("http://evil.example:44957/?code=b", "http://evil.example:44957/"), "only loopback hosts are intercepted");
    check(!Redirect.is_redirect("garbage", r), "garbage");
    check(Redirect.redirect_of("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A44957%2F&state=s") == r, "redirect from authorize url");
    check(Redirect.redirect_of("https://cloud.example/login/v2/flow/abc") == "", "no redirect in a login flow page");
    string err = Base64.encode("Error 403: disallowed_useragent".data).replace("+", "-").replace("/", "_").replace("=", "");
    check(Redirect.is_blocked("https://accounts.google.com/signin/oauth/error?authError=" + err + "&client_id=x"), "encoded disallowed_useragent");
    check(Redirect.is_blocked("https://accounts.google.com/signin/oauth/error?error=disallowed_useragent"), "plain disallowed_useragent");
    check(Redirect.is_blocked("https://accounts.google.com/v3/signin/rejected?continue=x"), "browser not secure page");
    check(!Redirect.is_blocked("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&scope=email"), "normal sign-in page");
}

void test_photos_upgrade() {
    var google = new AccountRecord();
    google.provider = "google";
    google.auth = "oauth2";
    google.identity = "tester@gmail.test";
    google.capabilities = { "mail", "calendar", "contacts", "tasks", "files" };
    google.enabled = { "mail", "files" };
    check(Providers.upgrade(google), "google upgraded");
    check(google.has_capability("photos") && "photos" in google.enabled, "google photos on");
    check(google.endpoint("photos-api") == "google" && google.endpoint("google-photos-picker") != "", "google photos endpoints");
    check(!Providers.upgrade(google), "upgrade runs once");
    var cloud = new AccountRecord();
    cloud.provider = "nextcloud";
    cloud.server = "https://cloud.example";
    cloud.identity = "alice";
    cloud.endpoints["dav-user"] = "alice";
    cloud.capabilities = { "calendar", "files" };
    check(Providers.upgrade(cloud), "nextcloud upgraded");
    check(cloud.endpoint("photos") == "https://cloud.example/remote.php/dav/photos/alice/", "nextcloud photos root");
    var own = new AccountRecord();
    own.provider = "owncloud";
    own.capabilities = { "files" };
    check(!Providers.upgrade(own), "owncloud has no photos");
    var mail = new AccountRecord();
    mail.provider = "google";
    mail.auth = "password";
    mail.capabilities = { "mail" };
    check(!Providers.upgrade(mail), "google app password account has no photos");
}


Soup.Server media_mock() {
    var server = new Soup.Server("server-header", "mock");
    server.add_handler(null, (srv, msg, path, query) => {
        string body = "";
        uint status = 200;
        if (path == "/Users/AuthenticateByName") {
            var req = (string) msg.get_request_body().flatten().get_data();
            if (req.contains("\"Pw\":\"good\"") && msg.get_request_headers().get_one("X-Emby-Authorization").contains("Client=\"Singularity\"")) {
                body = """{"User":{"Id":"u-42","Name":"Alice"},"AccessToken":"tok","ServerId":"srv"}""";
            } else {
                status = 401;
            }
        } else if (path == "/rest/ping.view") {
            string salt = query.lookup("s");
            string expected = Checksum.compute_for_string(ChecksumType.MD5, "good" + salt);
            if (query.lookup("t") == expected && query.lookup("u") == "alice") body = """{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","openSubsonic":true}}""";
            else body = """{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password"}}}""";
        } else if (path == "/1/validate-token") {
            if (msg.get_request_headers().get_one("Authorization") == "Token good") body = """{"code":200,"message":"Token valid.","valid":true,"user_name":"alice"}""";
            else body = """{"code":200,"message":"Token invalid.","valid":false}""";
        } else if (path == "/v1/me") {
            if (msg.get_request_headers().get_one("Authorization") == "Bearer at") body = """{"id":"spotuser","display_name":"Spot User","product":"premium"}""";
            else status = 401;
        } else {
            status = 404;
        }
        msg.set_status(status, null);
        msg.set_response("application/json", Soup.MemoryUse.COPY, body.data);
    });
    try {
        server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    } catch (Error e) {
        check(false, e.message);
    }
    return server;
}

string mock_url(Soup.Server server) {
    uint port = 0;
    foreach (var u in server.get_uris()) port = u.get_port();
    return "http://127.0.0.1:%u".printf(port);
}

async void media_checks(string base_url) {
    var http = new HttpProbe(false);
    var j = new AccountRecord();
    j.provider = "jellyfin";
    j.server = base_url;
    try {
        yield MediaProviders.check_jellyfin(http, j, "alice", "good");
    } catch (Error e) {
        check(false, "jellyfin: " + e.message);
    }
    check(j.endpoint("jellyfin-user-id") == "u-42" && j.identity == "alice", "jellyfin user");
    check(j.has_capability("music") && j.has_capability("videos"), "jellyfin capabilities");
    check(j.display_name.has_prefix("Alice"), "jellyfin display name");
    bool refused = false;
    try {
        yield MediaProviders.check_jellyfin(http, new AccountRecord() { server = base_url }, "alice", "bad");
    } catch (AccountsError.AUTH_FAILED e) {
        refused = true;
    } catch (Error e) {
    }
    check(refused, "jellyfin wrong password");

    var sub = new AccountRecord();
    sub.provider = "subsonic";
    sub.server = base_url;
    try {
        yield MediaProviders.check_subsonic(http, sub, "alice", "good");
    } catch (Error e) {
        check(false, "subsonic: " + e.message);
    }
    check(sub.endpoint("subsonic-type") == "navidrome" && sub.display_name.contains("Navidrome"), "navidrome detected");
    refused = false;
    try {
        yield MediaProviders.check_subsonic(http, new AccountRecord() { server = base_url }, "alice", "bad");
    } catch (AccountsError.AUTH_FAILED e) {
        refused = true;
    } catch (Error e) {
    }
    check(refused, "subsonic wrong password");

    var lb = new AccountRecord();
    lb.server = base_url;
    try {
        yield MediaProviders.check_listenbrainz(http, lb, "good");
    } catch (Error e) {
        check(false, "listenbrainz: " + e.message);
    }
    check(lb.identity == "alice" && lb.endpoint("listenbrainz") == base_url, "listenbrainz user");
    refused = false;
    try {
        yield MediaProviders.check_listenbrainz(http, new AccountRecord() { server = base_url }, "bad");
    } catch (AccountsError.AUTH_FAILED e) {
        refused = true;
    } catch (Error e) {
    }
    check(refused, "listenbrainz wrong token");

    var client = new OAuthClient();
    client.provider = "spotify";
    client.endpoints["spotify-api"] = base_url + "/v1/";
    var result = new SignInResult();
    try {
        yield MediaProviders.spotify_identity(client, "at", result);
    } catch (Error e) {
        check(false, "spotify: " + e.message);
    }
    check(result.identity == "spotuser" && result.display_name == "Spot User" && result.server == "premium", "spotify identity");
}

void test_media_providers() {
    var server = media_mock();
    var loop = new MainLoop();
    media_checks.begin(mock_url(server), (o, r) => {
        media_checks.end(r);
        loop.quit();
    });
    loop.run();
    server.disconnect();
}

void test_media_capabilities() {
    string[] google = Providers.default_capabilities("google");
    check(!("videos" in google) && "photos" in google, "videos needs its own consent");
    check(!Providers.consent_scopes("google", google).contains("youtube"), "default Google consent has no YouTube");
    string[] with_videos = google;
    with_videos += "videos";
    check(Providers.consent_scopes("google", with_videos).contains("youtube.readonly"), "YouTube scope when asked");
    check(Providers.consent_scopes("google", null) == Providers.GOOGLE_SCOPES, "legacy consent unchanged");
    check(Providers.consent_scopes("spotify").contains("user-modify-playback-state"), "spotify scopes");
    var r = new AccountRecord();
    r.provider = "google";
    r.auth = "oauth2";
    r.capabilities = { "mail", "photos" };
    check(Providers.upgrade(r), "google gets videos");
    check(r.has_capability("videos") && !("videos" in r.enabled), "videos offered but off");
    check(!Providers.granted(r, "videos"), "no YouTube grant yet");
    r.endpoints["granted-scopes"] = "openid " + Providers.GOOGLE_VIDEOS_SCOPE;
    check(Providers.granted(r, "videos"), "granted after consent");
    check(Providers.granted(r, "mail"), "other capabilities need no new consent");
    var nc = new AccountRecord();
    nc.provider = "nextcloud";
    nc.capabilities = { "files", "photos" };
    check(Providers.upgrade(nc) && "music" in nc.enabled && nc.endpoint("music-api") == "webdav", "nextcloud music");
    check(!Providers.upgrade(nc), "music upgrade once");
    check(nc.has_capability("videos") && !("videos" in nc.enabled) && nc.endpoint("videos-api") == "webdav", "nextcloud videos offered but off");
    string[] on = Providers.default_enabled("nextcloud", { "files", "music", "videos" });
    check("music" in on && !("videos" in on), "new nextcloud accounts start with videos off");
    check(Providers.find("spotify").auth == "oauth2" && Providers.find("jellyfin").auth == "password", "media providers listed");
    var sc = new OAuthClient();
    check(MediaProviders.spotify_port(sc) == 43019 && MediaProviders.spotify_redirect(43019) == "http://127.0.0.1:43019/callback", "spotify fixed redirect");
    sc.endpoints["redirect-port"] = "40111";
    check(MediaProviders.spotify_port(sc) == 40111, "spotify redirect port override");
    check(OAuthConfig.user_only("spotify") && !OAuthConfig.user_only("google"), "spotify client only from the user");
    check(MediaProviders.subsonic_query("a b", "pw", "salt").contains("u=a%20b&t=" + Checksum.compute_for_string(ChecksumType.MD5, "pwsalt")), "subsonic token");
}

AccountRecord microsoft_record(string id, string? mail_api) {
    var r = new AccountRecord();
    r.id = id;
    r.provider = "microsoft";
    r.auth = "oauth2";
    r.identity = id + "@example.test";
    r.capabilities = { "mail", "calendar", "files" };
    r.enabled = r.capabilities;
    r.endpoints["imap-host"] = "outlook.office365.com";
    r.endpoints["granted-scopes"] = "openid https://graph.microsoft.com/User.Read";
    if (mail_api != null) r.endpoints["mail-api"] = mail_api;
    return r;
}

async void check_microsoft_mail_route() throws Error {
    string dir = DirUtils.make_tmp("mail-route-XXXXXX");
    var store = new AccountStore(Path.build_filename(dir, "accounts.json"));
    var legacy = microsoft_record("legacy", null);
    var refused = microsoft_record("refused", "imap");
    var chosen = microsoft_record("chosen", null);
    chosen.endpoints["mail-fallback"] = "imap";
    chosen.endpoints["mail-api"] = "imap";
    var fresh = microsoft_record("fresh", "graph");
    foreach (var r in new AccountRecord[] { legacy, refused, chosen, fresh }) store.accounts.add(r);
    var service = new Service(store);
    var requested = new Gee.ArrayList<string>();
    bool allow_mail = true;
    bool allow_imap = true;
    var server = new Soup.Server("server-header", "Microsoft token fixture");
    server.add_handler("/token", (srv, message, path, query) => {
        var body = message.get_request_body().flatten();
        var form = Uri.parse_params((string) body.get_data(), (ssize_t) body.get_size(), "&", UriParamsFlags.NONE);
        string scope = form.lookup("scope") ?? "";
        requested.add(scope);
        bool imap = scope.contains("outlook.office.com");
        if ((imap && !allow_imap) || (!imap && !allow_mail)) {
            message.set_status(400, null);
            message.set_response("application/json", Soup.MemoryUse.COPY, "{\"error\":\"invalid_grant\",\"error_description\":\"AADSTS65001 consent required\"}".data);
            return;
        }
        string granted = imap ? "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"
            : "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Mail.ReadWrite.Shared";
        message.set_status(200, null);
        message.set_response("application/json", Soup.MemoryUse.COPY, ("{\"access_token\":\"fixture-" + requested.size.to_string() + "\",\"expires_in\":3600,\"scope\":\"" + granted + "\"}").data);
    });
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    var client = new OAuthClient();
    client.provider = "microsoft";
    client.client_id = "fixture-client";
    client.token_uri = server.get_uris().data.to_string() + "token";
    string changed = "";
    service.account_changed.connect((id) => changed += id + " ");

    check(Providers.legacy_imap_mail(legacy) && !Providers.legacy_imap_mail(chosen) && !Providers.legacy_imap_mail(fresh), "legacy IMAP accounts are told apart from a chosen fallback");
    bool moved = yield service.migrate_mail(legacy, client, "fixture-refresh", 0);
    check(moved && legacy.endpoint("mail-api") == "graph", "old IMAP Microsoft account moves to Graph mail");
    check(requested.size == 1 && requested[0].contains("https://graph.microsoft.com/Mail.ReadWrite") && !requested[0].contains("outlook.office.com"), "migration asks only for Graph Mail");
    check(Providers.microsoft_granted(legacy.endpoint("granted-scopes"), "https://graph.microsoft.com/Mail.ReadWrite.Shared"), "migration records the shared mailbox grant");
    check(legacy.endpoint("imap-host") == "outlook.office365.com" && legacy.attention == "", "migration keeps the account data and asks nothing");
    check("legacy" in changed, "migration tells the apps");
    var reloaded = new AccountStore(store.path).find("legacy");
    check(reloaded != null && reloaded.endpoint("mail-api") == "graph", "migration is saved");
    string token;
    int expires;
    int before = requested.size;
    yield service.get_access_token("legacy", "mail-graph", false, out token, out expires);
    check(token == "fixture-1" && requested.size == before, "the migrated account already has its Graph Mail token");

    allow_mail = false;
    moved = yield service.migrate_mail(refused, client, "fixture-refresh", 0);
    check(!moved && refused.endpoint("mail-api") == "imap" && refused.attention == "", "a tenant without Graph mail keeps IMAP without a sign-in prompt");
    moved = yield service.migrate_mail(chosen, client, "fixture-refresh", 0);
    check(!moved && chosen.endpoint("mail-api") == "imap", "a chosen IMAP fallback is never migrated");
    allow_mail = true;

    bool asked = false;
    try {
        service.set_capability_enabled("fresh", Providers.MICROSOFT_IMAP_FALLBACK, true);
    } catch (AccountsError.NEEDS_REAUTH e) {
        asked = true;
    }
    check(asked && fresh.attention == "consent" && fresh.endpoint("pending-consent") == Providers.MICROSOFT_IMAP_FALLBACK && fresh.endpoint("mail-api") == "graph", "turning on IMAP asks for consent first");
    service.set_capability_enabled("fresh", Providers.MICROSOFT_IMAP_FALLBACK, false);
    check(fresh.attention == "" && fresh.endpoint("pending-consent") == "" && fresh.endpoint("mail-api") == "graph", "turning it off again drops the request");
    fresh.endpoints["pending-consent"] = Providers.MICROSOFT_IMAP_FALLBACK;
    allow_imap = false;
    string message = yield service.settle_mail(fresh, client, "fixture-refresh");
    check(message != "" && fresh.endpoint("mail-api") == "graph" && fresh.endpoint("pending-consent") == "", "a tenant that refuses IMAP keeps Graph and says why");
    fresh.endpoints["pending-consent"] = Providers.MICROSOFT_IMAP_FALLBACK;
    allow_imap = true;
    message = yield service.settle_mail(fresh, client, "fixture-refresh");
    check(message == "" && fresh.endpoint("mail-api") == "imap" && fresh.endpoint("mail-fallback") == "imap" && Providers.imap_granted(fresh), "IMAP fallback is switched on after consent");
    service.set_capability_enabled("fresh", Providers.MICROSOFT_IMAP_FALLBACK, false);
    check(fresh.endpoint("mail-api") == "graph" && fresh.endpoint("mail-fallback") == "", "IMAP fallback can be switched back to Graph");
    service.set_capability_enabled("fresh", Providers.MICROSOFT_IMAP_FALLBACK, true);
    check(fresh.endpoint("mail-api") == "imap", "a granted fallback switches without a new sign-in");
    bool invalid = false;
    try {
        var google = new AccountRecord();
        google.id = "google";
        google.provider = "google";
        google.auth = "oauth2";
        google.capabilities = { "mail" };
        store.accounts.add(google);
        service.set_capability_enabled("google", Providers.MICROSOFT_IMAP_FALLBACK, true);
    } catch (AccountsError.INVALID e) {
        invalid = true;
    }
    check(invalid, "only Microsoft accounts have the IMAP fallback");

    var resign = microsoft_record("resign", null);
    resign.endpoints["granted-scopes"] = "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send";
    message = yield service.settle_mail(resign, client, "fixture-refresh");
    check(message == "" && resign.endpoint("mail-api") == "graph", "signing in again moves an old IMAP account to Graph");

    string config = OAuthConfig.user_path();
    string original = "";
    bool had_config = FileUtils.test(config, FileTest.EXISTS);
    if (had_config) FileUtils.get_contents(config, out original);
    DirUtils.create_with_parents(Path.get_dirname(config), 0700);
    FileUtils.set_contents(config, "{\"microsoft\":{\"client_id\":\"fixture-client\",\"auth_uri\":\"https://sign-in.example/authorize\"}}");
    Error? failure = null;
    try {
        foreach (string id in new string[] { "fresh", "legacy" }) {
            var settings = new HashTable<string, Variant>(str_hash, str_equal);
            settings.insert("account", id);
            string flow_id;
            string url;
            yield service.begin_sign_in("microsoft", settings, out flow_id, out url);
            service.cancel_sign_in(flow_id);
            string scope = Uri.parse_params(Uri.parse(url, UriFlags.NONE).get_query(), -1, "&", UriParamsFlags.NONE).lookup("scope");
            bool imap = scope.contains("https://outlook.office.com/IMAP.AccessAsUser.All");
            check(id == "fresh" ? imap : !imap, id == "fresh" ? "signing in again keeps the chosen IMAP fallback" : "signing in again on Graph asks for no IMAP");
        }
    } catch (Error e) {
        failure = e;
    }
    if (had_config) FileUtils.set_contents(config, original);
    else FileUtils.unlink(config);
    server.disconnect();
    FileUtils.unlink(store.path);
    DirUtils.remove(dir);
    if (failure != null) throw failure;
}

async void check_refresh_migrates() throws Error {
    string dir = DirUtils.make_tmp("refresh-migrate-XXXXXX");
    var store = new AccountStore(Path.build_filename(dir, "accounts.json"));
    var legacy = microsoft_record("refresh-legacy", null);
    store.accounts.add(legacy);
    var service = new Service(store);
    yield Secrets.store(legacy, "refresh-token", "fixture-refresh");
    var scopes = new Gee.ArrayList<string>();
    var server = new Soup.Server("server-header", "Microsoft token fixture");
    server.add_handler("/token", (srv, message, path, query) => {
        var body = message.get_request_body().flatten();
        var form = Uri.parse_params((string) body.get_data(), (ssize_t) body.get_size(), "&", UriParamsFlags.NONE);
        scopes.add(form.lookup("scope") ?? "");
        message.set_status(200, null);
        message.set_response("application/json", Soup.MemoryUse.COPY, ("{\"access_token\":\"fixture-" + scopes.size.to_string() + "\",\"expires_in\":3600}").data);
    });
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    string config = OAuthConfig.user_path();
    string original = "";
    bool had_config = FileUtils.test(config, FileTest.EXISTS);
    if (had_config) FileUtils.get_contents(config, out original);
    DirUtils.create_with_parents(Path.get_dirname(config), 0700);
    FileUtils.set_contents(config, "{\"microsoft\":{\"client_id\":\"fixture-client\",\"token_uri\":\"" + server.get_uris().data.to_string() + "token\"}}");
    Error? failure = null;
    try {
        string token;
        int expires;
        yield service.get_access_token(legacy.id, "mail", false, out token, out expires);
        check(token == "fixture-1" && scopes[0].contains("IMAP.AccessAsUser.All"), "an old account still gets its IMAP token first");
        int64 deadline = get_monotonic_time() + 5000000;
        while (legacy.endpoint("mail-api") != "graph" && get_monotonic_time() < deadline) {
            Timeout.add(10, check_refresh_migrates.callback);
            yield;
        }
        check(legacy.endpoint("mail-api") == "graph" && scopes.size == 2 && scopes[1].contains("Mail.ReadWrite"), "the next IMAP refresh moves the account to Graph mail");
        yield service.get_access_token(legacy.id, "mail-graph", false, out token, out expires);
        check(token == "fixture-2" && scopes.size == 2, "Graph Mail token comes from the migration");
    } catch (Error e) {
        failure = e;
    }
    server.disconnect();
    yield Secrets.clear(legacy.id);
    if (had_config) FileUtils.set_contents(config, original);
    else FileUtils.unlink(config);
    FileUtils.unlink(store.path);
    DirUtils.remove(dir);
    if (failure != null) throw failure;
}

void test_refresh_migrates() {
    if (Environment.get_variable("ACCOUNTS_TEST_KEYRING") != "1") {
        Test.skip("Requires the isolated Secret Service fixture");
        return;
    }
    var loop = new MainLoop();
    check_refresh_migrates.begin((obj, res) => {
        try { check_refresh_migrates.end(res); }
        catch (Error e) { check(false, e.message); }
        loop.quit();
    });
    loop.run();
}

void test_microsoft_mail_route() {
    var loop = new MainLoop();
    check_microsoft_mail_route.begin((obj, res) => {
        try { check_microsoft_mail_route.end(res); }
        catch (Error e) { check(false, e.message); }
        loop.quit();
    });
    loop.run();
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/accounts-daemon/pkce", test_pkce_rfc7636_vector);
    Test.add_func("/accounts-daemon/id-token", test_id_token_identity);
    Test.add_func("/accounts-daemon/token-parse", test_token_parse);
    Test.add_func("/accounts-daemon/records", test_records_roundtrip);
    Test.add_func("/accounts-daemon/oauth-config", test_oauth_config_files);
    Test.add_func("/accounts-daemon/providers", test_provider_defaults);
    Test.add_func("/accounts-daemon/app-data-consent", test_app_data_authorization);
    Test.add_func("/accounts-daemon/graph-mail-gate", test_graph_mail_gate);
    Test.add_func("/accounts-daemon/credential-refresh-gate", test_credential_refresh_gate);
    Test.add_func("/accounts-daemon/dav-probe", test_dav_probe_parsing);
    Test.add_func("/accounts-daemon/client-priority", test_client_priority);
    Test.add_func("/accounts-daemon/redirect-paste", test_redirect_paste);
    Test.add_func("/accounts-daemon/redirect-match", test_redirect_match);
    Test.add_func("/accounts-daemon/photos-upgrade", test_photos_upgrade);
    Test.add_func("/accounts-daemon/media-providers", test_media_providers);
    Test.add_func("/accounts-daemon/media-capabilities", test_media_capabilities);
    Test.add_func("/accounts-daemon/microsoft-mail-route", test_microsoft_mail_route);
    Test.add_func("/accounts-daemon/refresh-migrates-mail", test_refresh_migrates);
    return Test.run();
}
