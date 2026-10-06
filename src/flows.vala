namespace Singularity.AccountsDaemon {

    public class SignInResult : Object {
        public string identity { get; set; default = ""; }
        public string display_name { get; set; default = ""; }
        public string server { get; set; default = ""; }
        public string login_name { get; set; default = ""; }
        public string secret { get; set; default = ""; }
        public TokenSet? tokens { get; set; default = null; }
    }

    public abstract class SignInFlow : Object {
        public string id { get; construct; }
        public string provider { get; construct; }
        public string reauth_id { get; set; default = ""; }
        protected bool finished;
        private uint timeout_id;

        public signal void completed(SignInResult? result, string error_message);

        protected SignInFlow(string provider) {
            Object(id: random_token(12), provider: provider);
        }

        public abstract async string start() throws AccountsError;

        protected virtual void stop() {
        }

        protected void arm_timeout(uint seconds) {
            timeout_id = Timeout.add_seconds(seconds, () => {
                timeout_id = 0;
                finish(null, _("The sign-in took too long and was stopped. Try again."));
                return Source.REMOVE;
            });
        }

        protected void finish(SignInResult? result, string error_message) {
            if (finished) return;
            finished = true;
            if (timeout_id != 0) Source.remove(timeout_id);
            timeout_id = 0;
            stop();
            completed(result, error_message);
        }

        public void cancel() {
            finish(null, _("The sign-in was cancelled."));
        }
    }

    public class OAuthFlow : SignInFlow {
        public OAuthClient client { get; construct; }
        public string[]? capabilities { get; set; default = null; }
        private Soup.Server? server;
        private string state = "";
        private string verifier = "";
        private string redirect_uri = "";
        private bool answered;

        public OAuthFlow(string provider, OAuthClient client) {
            Object(id: random_token(12), provider: provider, client: client);
        }

        protected override void stop() {
            if (server != null) {
                var s = server;
                server = null;
                Timeout.add_seconds(2, () => {
                    s.disconnect();
                    return Source.REMOVE;
                });
            }
        }

        private static string page(string title, string text) {
            return """<!doctype html><html><head><meta charset="utf-8"><title>%s</title><style>body{font-family:Inter,system-ui,sans-serif;background:#242424;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center;max-width:32em}h1{font-size:22px}p{opacity:.75}</style></head><body><main><h1>%s</h1><p>%s</p></main></body></html>""".printf(
                Markup.escape_text(title), Markup.escape_text(title), Markup.escape_text(text));
        }

        public string build_authorize_url() {
            var sb = new StringBuilder(client.auth_uri);
            sb.append(client.auth_uri.contains("?") ? "&" : "?");
            var p = new HashTable<string, string>(str_hash, str_equal);
            p.insert("client_id", client.client_id);
            p.insert("redirect_uri", redirect_uri);
            p.insert("response_type", "code");
            p.insert("scope", Providers.consent_scopes(provider, capabilities));
            p.insert("state", state);
            p.insert("code_challenge", Pkce.challenge(verifier));
            p.insert("code_challenge_method", "S256");
            if (provider == "google") {
                p.insert("access_type", "offline");
                p.insert("prompt", "consent");
                p.insert("include_granted_scopes", "true");
            } else if (provider == "spotify") {
                p.insert("show_dialog", "true");
            } else {
                p.insert("response_mode", "query");
                p.insert("prompt", "select_account");
            }
            sb.append(TokenClient.form(p));
            return sb.str;
        }

        public override async string start() throws AccountsError {
            if (!client.configured) throw new AccountsError.NOT_CONFIGURED(_("This system has no registration for %s sign-in").printf(provider));
            state = random_token(16);
            verifier = Pkce.verifier();
            server = new Soup.Server("server-header", "Singularity");
            server.add_handler(null, handle);
            uint port = 0;
            uint fixed_port = provider == "spotify" ? MediaProviders.spotify_port(client) : 0;
            try {
                server.listen_local(fixed_port, Soup.ServerListenOptions.IPV4_ONLY);
                foreach (var uri in server.get_uris()) port = uri.get_port();
            } catch (Error e) {
                if (fixed_port != 0) throw new AccountsError.UNAVAILABLE(_("Port %u is in use by another program. Close it and sign in again.").printf(fixed_port));
                throw new AccountsError.UNAVAILABLE(_("Could not start the sign-in listener: %s").printf(e.message));
            }
            try {
                if (fixed_port == 0) server.listen_local(port, Soup.ServerListenOptions.IPV6_ONLY);
            } catch (Error e) {
            }
            redirect_uri = provider == "microsoft" ? "http://localhost:%u/".printf(port) : "http://127.0.0.1:%u/".printf(port);
            if (provider == "spotify") redirect_uri = MediaProviders.spotify_redirect(port);
            arm_timeout(600);
            return build_authorize_url();
        }

        private void respond(Soup.ServerMessage msg, uint status, string title, string text) {
            msg.set_status(status, null);
            msg.set_response("text/html; charset=utf-8", Soup.MemoryUse.COPY, page(title, text).data);
        }

        private void handle(Soup.Server srv, Soup.ServerMessage msg, string path, HashTable<string, string>? query) {
            if ((path != "/" && path != MediaProviders.SPOTIFY_CALLBACK) || query == null || answered) {
                respond(msg, 404, _("Not Found"), "");
                return;
            }
            if (query.lookup("state") != state) {
                respond(msg, 400, _("Sign-In Failed"), _("The answer did not belong to this sign-in. Start again from Settings."));
                return;
            }
            answered = true;
            string? error = query.lookup("error");
            if (error != null) {
                respond(msg, 200, _("Sign-In Cancelled"), _("You can close this tab and go back to Settings."));
                finish(null, error == "access_denied" ? _("Access was not granted.") : _("The provider reported an error: %s").printf(query.lookup("error_description") ?? error));
                return;
            }
            string? code = query.lookup("code");
            if (code == null) {
                respond(msg, 400, _("Sign-In Failed"), _("The provider did not send an authorization code."));
                finish(null, _("The provider did not send an authorization code."));
                return;
            }
            respond(msg, 200, _("Signed In"), _("You can close this tab and go back to Settings."));
            exchange.begin(code);
        }

        public void complete_from_address(string pasted) throws AccountsError {
            if (answered || finished) throw new AccountsError.INVALID(_("This sign-in has already finished"));
            string code = Redirect.parse(pasted, redirect_uri, state);
            answered = true;
            exchange.begin(code);
        }

        private async void exchange(string code) {
            try {
                var tokens = yield new TokenClient().exchange_code(client, code, redirect_uri, verifier);
                if (tokens.refresh_token == "") throw new AccountsError.PROTOCOL(_("The provider did not grant offline access"));
                var result = new SignInResult();
                result.tokens = tokens;
                result.identity = tokens.identity();
                result.display_name = tokens.display_name();
                result.secret = tokens.refresh_token;
                if (provider == "spotify") yield MediaProviders.spotify_identity(client, tokens.access_token, result);
                if (result.identity == "") throw new AccountsError.PROTOCOL(_("The provider did not say which account signed in"));
                finish(result, "");
            } catch (Error e) {
                finish(null, e.message);
            }
        }
    }

    public class NextcloudFlow : SignInFlow {
        public string server { get; construct; }
        public bool accept_invalid { get; construct; }
        private string poll_url = "";
        private string poll_token = "";
        private uint poll_source;

        public NextcloudFlow(string server, bool accept_invalid) {
            Object(id: random_token(12), provider: "nextcloud", server: server, accept_invalid: accept_invalid);
        }

        protected override void stop() {
            if (poll_source != 0) Source.remove(poll_source);
            poll_source = 0;
        }

        public override async string start() throws AccountsError {
            var http = new HttpProbe(accept_invalid);
            var r = yield http.request("POST", server + "/index.php/login/v2", null, "application/x-www-form-urlencoded", "");
            if (r.status == 404) throw new AccountsError.PROTOCOL(_("%s is not a Nextcloud server, or it is too old for browser sign-in. Use an app password instead.").printf(Providers.host_of(server)));
            if (r.status != 200) throw new AccountsError.PROTOCOL(_("The server refused to start the sign-in (HTTP %u)").printf(r.status));
            string login;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(r.body);
                var o = parser.get_root().get_object();
                var poll = o.get_object_member("poll");
                poll_token = poll.get_string_member("token");
                poll_url = poll.get_string_member("endpoint");
                login = o.get_string_member("login");
            } catch (Error e) {
                throw new AccountsError.PROTOCOL(_("%s did not answer like a Nextcloud server").printf(Providers.host_of(server)));
            }
            arm_timeout(1200);
            poll_source = Timeout.add_seconds(2, () => {
                poll.begin();
                return Source.CONTINUE;
            });
            return login;
        }

        private bool polling;

        private async void poll() {
            if (polling || finished) return;
            polling = true;
            try {
                var http = new HttpProbe(accept_invalid);
                var r = yield http.request("POST", poll_url, null, "application/x-www-form-urlencoded", "token=" + Uri.escape_string(poll_token, null, false));
                if (r.status == 200) {
                    var parser = new Json.Parser();
                    parser.load_from_data(r.body);
                    var o = parser.get_root().get_object();
                    var result = new SignInResult();
                    result.server = Providers.normalize_server(o.get_string_member("server"));
                    result.login_name = o.get_string_member("loginName");
                    result.secret = o.get_string_member("appPassword");
                    result.identity = result.login_name;
                    finish(result, "");
                }
            } catch (Error e) {
                debug("poll: %s", e.message);
            }
            polling = false;
        }
    }
}
