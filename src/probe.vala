namespace Singularity.AccountsDaemon {

    public class HttpResult : Object {
        public uint status;
        public string body = "";
        public Soup.MessageHeaders? headers;
        public string url = "";
    }

    public class HttpProbe : Object {
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
        public bool accept_invalid { get; set; default = false; }

        public HttpProbe(bool accept_invalid = false) {
            session = new Soup.Session();
            session.user_agent = "Singularity Online Accounts";
            session.timeout = 30;
            this.accept_invalid = accept_invalid;
        }

        public async HttpResult request(string method, string url, string? authorization, string? content_type = null,
                                        string? body = null, HashTable<string, string>? headers = null) throws AccountsError {
            string current = url;
            for (int hop = 0; hop < 6; hop++) {
                Soup.Message msg;
                try {
                    var parsed = Uri.parse(current, UriFlags.ENCODED);
                    if (parsed.get_path() == "") {
                        parsed = Uri.build(UriFlags.ENCODED, parsed.get_scheme(), parsed.get_userinfo(), parsed.get_host(), parsed.get_port(), "/", parsed.get_query(), parsed.get_fragment());
                    }
                    msg = new Soup.Message.from_uri(method, parsed);
                } catch (UriError e) {
                    throw new AccountsError.INVALID(_("The address %s is not valid").printf(current));
                }
                msg.add_flags(Soup.MessageFlags.NO_REDIRECT);
                if (authorization != null) msg.request_headers.replace("Authorization", authorization);
                if (headers != null) headers.foreach((k, v) => msg.request_headers.replace(k, v));
                if (body != null) msg.set_request_body_from_bytes(content_type, new Bytes(body.data));
                if (accept_invalid) msg.accept_certificate.connect(() => true);
                Bytes data;
                try {
                    data = yield read_bounded(session, msg, 4 * 1024 * 1024, Priority.DEFAULT, null);
                } catch (Error e) {
                    string host = current;
                    try {
                        host = Uri.parse(current, UriFlags.NONE).get_host() ?? current;
                    } catch (UriError ue) {
                    }
                    throw new AccountsError.NETWORK(_("Could not reach %s: %s").printf(host, e.message));
                }
                uint status = msg.status_code;
                if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                    string? location = msg.response_headers.get_one("Location");
                    if (location != null) {
                        try {
                            current = Uri.resolve_relative(current, location, UriFlags.ENCODED);
                        } catch (UriError e) {
                            current = location;
                        }
                        continue;
                    }
                }
                var result = new HttpResult();
                result.status = status;
                result.body = bytes_text(data);
                result.headers = msg.response_headers;
                result.url = current;
                return result;
            }
            throw new AccountsError.PROTOCOL(_("Too many redirects"));
        }

        public static string basic(string user, string secret) {
            return "Basic " + Base64.encode((user + ":" + secret).data);
        }
    }

    public class MailProbe : Object {
        private IOStream? stream;
        private DataInputStream? input;
        private OutputStream? output;
        private bool accept_invalid;
        private string host;

        public MailProbe(string host, bool accept_invalid) {
            this.host = host;
            this.accept_invalid = accept_invalid;
        }

        private async void connect_to(uint16 port, bool tls) throws AccountsError {
            var client = new SocketClient();
            client.timeout = 20;
            if (tls) {
                client.tls = true;
                client.event.connect((ev, connectable, conn) => {
                    if (ev == SocketClientEvent.TLS_HANDSHAKING && accept_invalid) {
                        ((TlsClientConnection) conn).accept_certificate.connect(() => true);
                    }
                });
            }
            try {
                var conn = yield client.connect_to_host_async(host, port, null);
                set_stream(conn);
            } catch (Error e) {
                throw new AccountsError.NETWORK(_("Could not reach %s: %s").printf(host, e.message));
            }
        }

        private void set_stream(IOStream s) {
            stream = s;
            input = new DataInputStream(s.input_stream);
            input.newline_type = DataStreamNewlineType.CR_LF;
            output = s.output_stream;
        }

        private async void start_tls() throws AccountsError {
            try {
                var tls = TlsClientConnection.new(stream, new NetworkAddress(host, 0));
                if (accept_invalid) tls.accept_certificate.connect(() => true);
                yield tls.handshake_async(Priority.DEFAULT, null);
                set_stream(tls);
            } catch (Error e) {
                throw new AccountsError.NETWORK(_("Secure connection to %s failed: %s").printf(host, e.message));
            }
        }

        private async string read_line() throws AccountsError {
            try {
                string? line = yield input.read_line_async(Priority.DEFAULT, null);
                if (line == null) throw new AccountsError.NETWORK(_("%s closed the connection").printf(host));
                return line;
            } catch (AccountsError e) {
                throw e;
            } catch (Error e) {
                throw new AccountsError.NETWORK(e.message);
            }
        }

        private async void write_line(string line) throws AccountsError {
            try {
                size_t written;
                yield output.write_all_async((line + "\r\n").data, Priority.DEFAULT, null, out written);
            } catch (Error e) {
                throw new AccountsError.NETWORK(e.message);
            }
        }

        private async void close() {
            try {
                if (stream != null) yield stream.close_async();
            } catch (Error e) {
            }
        }

        private static string quote(string s) {
            return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
        }

        private async string imap_command(string tag, string command) throws AccountsError {
            yield write_line(tag + " " + command);
            while (true) {
                string line = yield read_line();
                if (line.has_prefix("+")) {
                    yield write_line("");
                    continue;
                }
                if (line.has_prefix(tag + " ")) return line.substring(tag.length + 1);
            }
        }

        public async void imap_login(uint16 port, string security, string user, string secret, string mechanism) throws AccountsError {
            yield connect_to(port, security == "tls");
            string greeting = yield read_line();
            if (!greeting.has_prefix("* OK") && !greeting.has_prefix("* PREAUTH")) {
                yield close();
                throw new AccountsError.PROTOCOL(_("%s is not an IMAP server").printf(host));
            }
            if (security == "starttls") {
                string r = yield imap_command("a1", "STARTTLS");
                if (!r.has_prefix("OK")) {
                    yield close();
                    throw new AccountsError.PROTOCOL(_("%s does not offer STARTTLS").printf(host));
                }
                yield start_tls();
            }
            string result;
            if (mechanism == "oauth2") {
                string sasl = Base64.encode(("user=" + user + "\x01" + "auth=Bearer " + secret + "\x01\x01").data);
                result = yield imap_command("a2", "AUTHENTICATE XOAUTH2 " + sasl);
            } else {
                result = yield imap_command("a2", "LOGIN %s %s".printf(quote(user), quote(secret)));
            }
            yield imap_command("a3", "LOGOUT");
            yield close();
            if (!result.has_prefix("OK")) throw new AccountsError.AUTH_FAILED(_("The mail server refused the user name or password"));
        }

        private async string smtp_reply() throws AccountsError {
            string line = "";
            do {
                line = yield read_line();
            } while (line.length > 3 && line[3] == '-');
            return line;
        }

        public async void smtp_login(uint16 port, string security, string user, string secret, string mechanism) throws AccountsError {
            yield connect_to(port, security == "tls");
            string greeting = yield smtp_reply();
            if (!greeting.has_prefix("220")) {
                yield close();
                throw new AccountsError.PROTOCOL(_("%s is not an SMTP server").printf(host));
            }
            yield write_line("EHLO singularity");
            yield smtp_reply();
            if (security == "starttls") {
                yield write_line("STARTTLS");
                string r = yield smtp_reply();
                if (!r.has_prefix("220")) {
                    yield close();
                    throw new AccountsError.PROTOCOL(_("%s does not offer STARTTLS").printf(host));
                }
                yield start_tls();
                yield write_line("EHLO singularity");
                yield smtp_reply();
            }
            if (mechanism == "oauth2") {
                yield write_line("AUTH XOAUTH2 " + Base64.encode(("user=" + user + "\x01" + "auth=Bearer " + secret + "\x01\x01").data));
            } else {
                uint8[] plain = new uint8[user.length * 2 + secret.length + 2];
                int i = 0;
                foreach (uint8 b in user.data) plain[i++] = b;
                plain[i++] = 0;
                foreach (uint8 b in user.data) plain[i++] = b;
                plain[i++] = 0;
                foreach (uint8 b in secret.data) plain[i++] = b;
                yield write_line("AUTH PLAIN " + Base64.encode(plain[0:i]));
            }
            string reply = yield smtp_reply();
            if (reply.has_prefix("334")) {
                yield write_line("");
                reply = yield smtp_reply();
            }
            yield write_line("QUIT");
            yield close();
            if (!reply.has_prefix("235")) throw new AccountsError.AUTH_FAILED(_("The outgoing mail server refused the user name or password"));
        }
    }

    namespace DavProbe {
        private const string BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="urn:ietf:params:xml:ns:carddav"><d:prop><d:resourcetype/><d:current-user-principal/><c:calendar-home-set/><a:addressbook-home-set/></d:prop></d:propfind>""";

        public bool has_home(string xml, string element) {
            try {
                var re = new Regex("<([a-zA-Z0-9]+:)?" + element + "[^>]*>\\s*<([a-zA-Z0-9]+:)?href[^>]*>\\s*[^<\\s]");
                return re.match(xml);
            } catch (RegexError e) {
                return false;
            }
        }

        public string principal_href(string xml) {
            try {
                var re = new Regex("<([a-zA-Z0-9]+:)?current-user-principal[^>]*>\\s*<([a-zA-Z0-9]+:)?href[^>]*>\\s*([^<\\s]+)");
                MatchInfo info;
                if (re.match(xml, 0, out info)) return info.fetch(3);
            } catch (RegexError e) {
            }
            return "";
        }

        public async void check(HttpProbe http, string url, string authorization, out bool calendars, out bool contacts) throws AccountsError {
            calendars = false;
            contacts = false;
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Depth", "0");
            var r = yield http.request("PROPFIND", url, authorization, "application/xml; charset=utf-8", BODY, headers);
            if (r.status == 404 || r.status == 405) {
                string wk;
                try {
                    wk = Uri.resolve_relative(url, "/.well-known/caldav", UriFlags.ENCODED);
                } catch (UriError e) {
                    wk = url;
                }
                r = yield http.request("PROPFIND", wk, authorization, "application/xml; charset=utf-8", BODY, headers);
            }
            if (r.status == 401 || r.status == 403) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            if (r.status != 207) throw new AccountsError.PROTOCOL(_("The server did not answer as a CalDAV or CardDAV server (HTTP %u)").printf(r.status));
            calendars = has_home(r.body, "calendar-home-set") || r.body.contains("calendar xmlns") || r.body.contains(":calendar/>");
            contacts = has_home(r.body, "addressbook-home-set") || r.body.contains(":addressbook/>");
            string principal = principal_href(r.body);
            if ((!calendars || !contacts) && principal != "") {
                string purl;
                try {
                    purl = Uri.resolve_relative(r.url, principal, UriFlags.ENCODED);
                } catch (UriError e) {
                    purl = principal;
                }
                var p = yield http.request("PROPFIND", purl, authorization, "application/xml; charset=utf-8", BODY, headers);
                if (p.status == 207) {
                    calendars = calendars || has_home(p.body, "calendar-home-set");
                    contacts = contacts || has_home(p.body, "addressbook-home-set");
                }
            }
        }

        public async void check_webdav(HttpProbe http, string url, string authorization) throws AccountsError {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Depth", "0");
            var r = yield http.request("PROPFIND", url, authorization, "application/xml; charset=utf-8",
                "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>", headers);
            if (r.status == 401 || r.status == 403) throw new AccountsError.AUTH_FAILED(_("The server refused the user name or password"));
            if (r.status != 207) throw new AccountsError.PROTOCOL(_("The server did not answer as a WebDAV server (HTTP %u)").printf(r.status));
        }
    }
}
