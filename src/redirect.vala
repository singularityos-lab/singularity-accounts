namespace Singularity.AccountsDaemon {

    namespace Redirect {
        private string origin(Uri u) {
            string host = (u.get_host() ?? "").down();
            if (host == "localhost" || host == "[::1]" || host == "::1") host = "127.0.0.1";
            return "%s://%s:%d".printf((u.get_scheme() ?? "").down(), host, u.get_port());
        }

        public string parse(string pasted, string redirect_uri, string expected_state) throws AccountsError {
            string text = pasted.strip();
            if (text != "" && !text.contains("://")) text = "http://" + text;
            Uri got;
            Uri want;
            try {
                got = Uri.parse(text, UriFlags.ENCODED);
                want = Uri.parse(redirect_uri, UriFlags.ENCODED);
            } catch (UriError e) {
                throw new AccountsError.INVALID(_("That is not the address of the sign-in page"));
            }
            string got_path = got.get_path() == "" ? "/" : got.get_path();
            string want_path = want.get_path() == "" ? "/" : want.get_path();
            if (origin(got) != origin(want) || got_path != want_path) {
                throw new AccountsError.INVALID(_("That address does not belong to this sign-in. Copy the address of the page your browser showed after you approved."));
            }
            string? query = got.get_query();
            if (query == null || query == "") throw new AccountsError.INVALID(_("The address has no sign-in answer in it"));
            HashTable<string, string> fields;
            try {
                fields = Uri.parse_params(query, -1, "&", UriParamsFlags.NONE);
            } catch (UriError e) {
                throw new AccountsError.INVALID(_("The address has no sign-in answer in it"));
            }
            if (fields.lookup("state") != expected_state) {
                throw new AccountsError.INVALID(_("That address belongs to another sign-in. Start again and copy the new address."));
            }
            string? error = fields.lookup("error");
            if (error != null) {
                if (error == "access_denied") throw new AccountsError.CANCELLED(_("Access was not granted."));
                throw new AccountsError.AUTH_FAILED(_("The provider reported an error: %s").printf(fields.lookup("error_description") ?? error));
            }
            string? code = fields.lookup("code");
            if (code == null || code == "") throw new AccountsError.INVALID(_("The address has no authorization code in it"));
            return code;
        }

        public bool is_redirect(string uri, string redirect_uri) {
            try {
                var got = Uri.parse(uri, UriFlags.ENCODED);
                var want = Uri.parse(redirect_uri, UriFlags.ENCODED);
                string host = (got.get_host() ?? "").down();
                if (host != "127.0.0.1" && host != "localhost" && host != "::1" && host != "[::1]") return false;
                string got_path = got.get_path() == "" ? "/" : got.get_path();
                string want_path = want.get_path() == "" ? "/" : want.get_path();
                return origin(got) == origin(want) && got_path == want_path;
            } catch (UriError e) {
                return false;
            }
        }

        public string redirect_of(string authorize_url) {
            try {
                var u = Uri.parse(authorize_url, UriFlags.ENCODED);
                string? query = u.get_query();
                if (query == null) return "";
                var fields = Uri.parse_params(query, -1, "&", UriParamsFlags.NONE);
                return fields.lookup("redirect_uri") ?? "";
            } catch (UriError e) {
                return "";
            }
        }

        private bool mentions_block(string text) {
            string t = text.down();
            return t.contains("disallowed_useragent") || t.contains("disallowed useragent");
        }

        public bool is_blocked(string uri) {
            try {
                var u = Uri.parse(uri, UriFlags.ENCODED);
                string path = u.get_path() ?? "";
                if (path.contains("/signin/rejected") || path.contains("/signin/disallowed")) return true;
                string? query = u.get_query();
                if (query == null) return false;
                var fields = Uri.parse_params(query, -1, "&", UriParamsFlags.NONE);
                bool found = false;
                fields.foreach((k, v) => {
                    if (mentions_block(v)) found = true;
                    if (k == "authError") {
                        string padded = v.replace("-", "+").replace("_", "/");
                        while (padded.length % 4 != 0) padded += "=";
                        uint8[] raw = Base64.decode(padded);
                        var sb = new StringBuilder();
                        sb.append_len((string) raw, raw.length);
                        if (mentions_block(sb.str)) found = true;
                    }
                });
                return found;
            } catch (UriError e) {
                return false;
            }
        }
    }
}
