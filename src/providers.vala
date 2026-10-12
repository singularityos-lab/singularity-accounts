namespace Singularity.AccountsDaemon {

    public class ProviderInfo : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string description { get; construct; }
        public string icon { get; construct; }
        public string auth { get; construct; }
        public string[] capabilities { get; construct; }

        public ProviderInfo(string id, string name, string description, string icon, string auth, string[] capabilities) {
            Object(id: id, name: name, description: description, icon: icon, auth: auth, capabilities: capabilities);
        }

        public HashTable<string, Variant> to_variant(bool configured, OAuthClient? client = null) {
            var t = new HashTable<string, Variant>(str_hash, str_equal);
            t.insert("id", id);
            t.insert("name", name);
            t.insert("description", description);
            t.insert("icon", icon);
            t.insert("auth", auth);
            t.insert("capabilities", capabilities);
            t.insert("configured", configured);
            if (client != null) {
                t.insert("client-source", client.configured ? client.source_kind : "");
                t.insert("client-path", client.configured ? client.source : "");
                t.insert("client-id", client.client_id);
                t.insert("client-has-secret", client.client_secret != "");
            }
            return t;
        }
    }

    namespace Providers {
        public const string GOOGLE_SCOPES = "openid email profile https://mail.google.com/ https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/carddav https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/drive.appdata https://www.googleapis.com/auth/photospicker.mediaitems.readonly https://www.googleapis.com/auth/photoslibrary.appendonly https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata";
        public const string GOOGLE_BASE_SCOPES = "openid email profile";
        public const string SPOTIFY_SCOPES = "user-read-private user-library-read playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state user-read-currently-playing";
        public const string GOOGLE_VIDEOS_SCOPE = "https://www.googleapis.com/auth/youtube.readonly";
        public const string GOOGLE_CHAT_SCOPES = "https://www.googleapis.com/auth/chat.spaces.readonly https://www.googleapis.com/auth/chat.messages https://www.googleapis.com/auth/chat.memberships.readonly https://www.googleapis.com/auth/chat.users.readstate";
        public const string MICROSOFT_CHAT_SCOPES = "https://graph.microsoft.com/Chat.ReadWrite https://graph.microsoft.com/ChatMessage.Send https://graph.microsoft.com/People.Read https://graph.microsoft.com/User.ReadBasic.All";
        public const string MICROSOFT_MAIL_SCOPES = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send";
        public const string MICROSOFT_GRAPH_SCOPES = "offline_access openid email profile https://graph.microsoft.com/User.Read https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/Contacts.ReadWrite https://graph.microsoft.com/Tasks.ReadWrite https://graph.microsoft.com/Files.ReadWrite";
        public const string MICROSOFT_GRAPH_FILES_SHARED_SCOPES = "https://graph.microsoft.com/Files.ReadWrite.All https://graph.microsoft.com/Sites.Read.All";
        public const string MICROSOFT_GRAPH_MAIL_SCOPES = "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/MailboxSettings.ReadWrite";
        public const string MICROSOFT_GRAPH_MAIL_SHARED_SCOPES = "https://graph.microsoft.com/Mail.ReadWrite.Shared https://graph.microsoft.com/Mail.Send.Shared";
        public const string MICROSOFT_GRAPH_SHARED_SCOPES = "https://graph.microsoft.com/Calendars.ReadWrite.Shared https://graph.microsoft.com/Contacts.ReadWrite.Shared";
        public const string MICROSOFT_IMAP_FALLBACK = "mail-imap";

        private ProviderInfo[]? cache;

        public ProviderInfo[] all() {
            if (cache != null) return cache;
            cache = {
                new ProviderInfo("nextcloud", "Nextcloud", _("Calendars, contacts, tasks and files on a Nextcloud server"),
                    "singularity-account-nextcloud", "login-flow", { "calendar", "contacts", "tasks", "files", "photos", "notes", "music", "videos", "chat" }),
                new ProviderInfo("google", "Google", _("Mail, calendar, contacts, tasks, Drive and Google Photos"),
                    "singularity-account-google", "oauth2", { "mail", "calendar", "contacts", "tasks", "files", "photos", "videos", "chat" }),
                new ProviderInfo("microsoft", "Microsoft", _("Outlook.com and Microsoft 365 mail, calendar, contacts, To Do and OneDrive"),
                    "singularity-account-microsoft", "oauth2", { "mail", "calendar", "contacts", "tasks", "files", "photos", "chat" }),
                new ProviderInfo("owncloud", "ownCloud", _("Calendars, contacts, tasks and files on an ownCloud server"),
                    "singularity-account-owncloud", "password", { "calendar", "contacts", "tasks", "files" }),
                new ProviderInfo("exchange", "Exchange", _("Mail and calendar on an Exchange server in your organization"),
                    "singularity-account-exchange", "password", { "mail", "calendar" }),
                new ProviderInfo("imap", _("Mail (IMAP and SMTP)"), _("Any mail account with its server details"),
                    "singularity-account-mail", "password", { "mail" }),
                new ProviderInfo("proton", "Proton", _("Proton Mail through Proton Mail Bridge"),
                    "singularity-account-secure-mail", "password", { "mail" }),
                new ProviderInfo("caldav", _("Calendar and Contacts (CalDAV, CardDAV)"), _("Any CalDAV or CardDAV server"),
                    "singularity-account-caldav", "password", { "calendar", "contacts", "tasks" }),
                new ProviderInfo("webdav", _("Files (WebDAV)"), _("Any WebDAV file server"),
                    "singularity-account-webdav", "password", { "files" }),
                new ProviderInfo("jellyfin", "Jellyfin", _("Music and videos on your Jellyfin server"),
                    "singularity-account-media-server", "password", { "music", "videos" }),
                new ProviderInfo("subsonic", _("Navidrome and Subsonic"), _("Music on a Navidrome, Subsonic, Airsonic or gonic server"),
                    "singularity-account-media-server", "password", { "music" }),
                new ProviderInfo("listenbrainz", "ListenBrainz", _("Keep a public history of the music you listen to"),
                    "singularity-account-listening", "password", { "music" }),
                new ProviderInfo("spotify", "Spotify", _("Browse your Spotify library and control playback on your devices. Needs your own developer client ID."),
                    "singularity-account-music-service", "oauth2", { "music" })
            };
            return cache;
        }

        public ProviderInfo? find(string id) {
            foreach (var p in all()) if (p.id == id) return p;
            return null;
        }

        public string normalize_server(string input) {
            string s = input.strip();
            if (s == "") return s;
            if (!s.has_prefix("http://") && !s.has_prefix("https://")) s = "https://" + s;
            while (s.has_suffix("/")) s = s.substring(0, s.length - 1);
            if (s.has_suffix("/index.php")) s = s.substring(0, s.length - 10);
            return s;
        }

        public string host_of(string url) {
            try {
                return Uri.parse(url, UriFlags.NONE).get_host() ?? url;
            } catch (UriError e) {
                return url;
            }
        }

        public string resource_for(string provider, string capability) {
            if (provider == "microsoft") {
                if (capability == "mail") return "mail";
                if (capability == "mail-graph") return "graph-mail";
                if (capability == "chat") return "graph-chat";
                return "graph";
            }
            return "default";
        }

        public string scope_for_capability(string provider, string capability) {
            if (provider == "spotify") return SPOTIFY_SCOPES;
            if (provider == "microsoft") return capability == "chat" ? MICROSOFT_CHAT_SCOPES : "";
            if (provider != "google") return "";
            switch (capability) {
                case "mail": return "https://mail.google.com/";
                case "calendar": return "https://www.googleapis.com/auth/calendar";
                case "contacts": return "https://www.googleapis.com/auth/carddav";
                case "tasks": return "https://www.googleapis.com/auth/tasks";
                case "files": return "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/drive.appdata";
                case "photos": return "https://www.googleapis.com/auth/photospicker.mediaitems.readonly https://www.googleapis.com/auth/photoslibrary.appendonly https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata";
                case "videos": return GOOGLE_VIDEOS_SCOPE;
                case "chat": return GOOGLE_CHAT_SCOPES;
                default: return "";
            }
        }

        public string[] default_enabled(string provider, string[] capabilities) {
            string[] on = {};
            foreach (string c in capabilities) {
                if (needs_consent(provider, c)) continue;
                if (provider == "nextcloud" && c == "videos") continue;
                on += c;
            }
            return on;
        }

        public bool needs_consent(string provider, string capability) {
            if (capability == "chat") return provider == "google" || provider == "microsoft";
            return provider == "google" && capability == "videos";
        }

        public string[] default_capabilities(string provider) {
            string[] caps = {};
            var info = find(provider);
            if (info == null) return caps;
            foreach (string c in info.capabilities) if (!needs_consent(provider, c)) caps += c;
            return caps;
        }

        public bool has_scope(string granted, string scope) {
            foreach (string s in granted.split(" ")) if (s == scope) return true;
            return false;
        }

        public bool granted(AccountRecord r, string capability) {
            if (!needs_consent(r.provider, capability)) return true;
            string scope = scope_for_capability(r.provider, capability);
            foreach (string s in scope.split(" ")) {
                bool ok = r.provider == "microsoft" ? microsoft_granted(r.endpoint("granted-scopes"), s) : has_scope(r.endpoint("granted-scopes"), s);
                if (!ok) return false;
            }
            return true;
        }

        public string scopes_for(string provider, string resource, string granted = "") {
            if (provider == "google") return GOOGLE_SCOPES;
            if (resource == "mail") return MICROSOFT_MAIL_SCOPES;
            if (resource == "graph-chat") return "offline_access https://graph.microsoft.com/User.Read " + MICROSOFT_CHAT_SCOPES;
            bool mail = resource == "graph-mail";
            var sb = new StringBuilder(mail ? "offline_access " + MICROSOFT_GRAPH_MAIL_SCOPES : MICROSOFT_GRAPH_SCOPES);
            foreach (string s in (mail ? MICROSOFT_GRAPH_MAIL_SHARED_SCOPES : MICROSOFT_GRAPH_SHARED_SCOPES).split(" ")) {
                if (microsoft_granted(granted, s)) sb.append(" ").append(s);
            }
            if (!mail) {
                foreach (string s in MICROSOFT_GRAPH_FILES_SHARED_SCOPES.split(" ")) {
                    if (microsoft_granted(granted, s)) sb.append(" ").append(s);
                }
            }
            return sb.str;
        }

        private string short_scope(string scope) {
            string s = scope.down();
            return s.has_prefix("https://graph.microsoft.com/") ? s.substring(28) : s;
        }

        public bool microsoft_granted(string granted, string scope) {
            string want = short_scope(scope);
            foreach (string s in granted.split(" ")) if (s != "" && short_scope(s) == want) return true;
            return false;
        }

        public void merge_granted(AccountRecord r, string scope) {
            string granted = r.endpoint("granted-scopes");
            foreach (string sc in scope.split(" ")) {
                if (sc != "" && !has_scope(granted, sc)) granted = granted == "" ? sc : granted + " " + sc;
            }
            if (granted != "") r.endpoints["granted-scopes"] = granted;
        }

        public bool graph_mail_granted(AccountRecord r) {
            string granted = r.endpoint("granted-scopes");
            foreach (string s in MICROSOFT_GRAPH_MAIL_SCOPES.split(" ")) {
                if (!s.has_suffix("MailboxSettings.ReadWrite") && !microsoft_granted(granted, s)) return false;
            }
            return true;
        }

        public bool imap_granted(AccountRecord r) {
            return has_scope(r.endpoint("granted-scopes"), "https://outlook.office.com/IMAP.AccessAsUser.All");
        }

        public bool legacy_imap_mail(AccountRecord r) {
            return r.provider == "microsoft" && r.auth == "oauth2" && r.has_capability("mail")
                && r.endpoint("mail-api") != "graph" && r.endpoint("mail-fallback") != "imap";
        }

        public void use_graph_mail(AccountRecord r) {
            r.endpoints["mail-api"] = "graph";
            r.endpoints.unset("mail-fallback");
        }

        public void use_imap_mail(AccountRecord r) {
            r.endpoints["mail-api"] = "imap";
            r.endpoints["mail-fallback"] = "imap";
        }

        public bool upgrade(AccountRecord r) {
            bool changed = upgrade_photos(r);
            var info = find(r.provider);
            if (info == null) return changed;
            if (r.provider == "google" && r.auth == "oauth2" && !r.has_capability("videos")) {
                string[] caps = r.capabilities;
                caps += "videos";
                r.capabilities = caps;
                r.endpoints["youtube"] = "https://www.googleapis.com/youtube/v3/";
                r.endpoints["videos-api"] = "youtube";
                changed = true;
            }
            if (r.provider == "nextcloud" && !r.has_capability("videos")) {
                string[] caps = r.capabilities;
                caps += "videos";
                r.capabilities = caps;
                r.endpoints["videos-api"] = "webdav";
                changed = true;
            }
            if ((r.provider == "google" || r.provider == "microsoft") && r.auth == "oauth2" && !r.has_capability("chat")) {
                string[] caps = r.capabilities;
                caps += "chat";
                r.capabilities = caps;
                r.endpoints["chat-api"] = r.provider == "google" ? "google-chat" : "teams";
                changed = true;
            }
            if (r.provider == "nextcloud" && !r.has_capability("chat")) {
                string[] caps = r.capabilities;
                caps += "chat";
                r.capabilities = caps;
                string[] on = r.enabled;
                on += "chat";
                r.enabled = on;
                r.endpoints["chat-api"] = "talk";
                changed = true;
            }
            if (r.provider == "nextcloud" && !r.has_capability("music")) {
                string[] caps = r.capabilities;
                caps += "music";
                r.capabilities = caps;
                string[] on = r.enabled;
                on += "music";
                r.enabled = on;
                r.endpoints["music-api"] = "webdav";
                changed = true;
            }
            return changed;
        }

        private bool upgrade_photos(AccountRecord r) {
            var info = find(r.provider);
            if (info == null || !("photos" in info.capabilities) || r.has_capability("photos")) return false;
            if (r.provider == "google" && r.auth != "oauth2") return false;
            string[] caps = r.capabilities;
            caps += "photos";
            r.capabilities = caps;
            string[] on = r.enabled;
            on += "photos";
            r.enabled = on;
            var d = new Gee.HashMap<string, string>();
            if (r.provider == "nextcloud") {
                d["photos"] = r.server + "/remote.php/dav/photos/" + Uri.escape_string(r.endpoint("dav-user", r.identity), "@", false) + "/";
                d["photos-api"] = "nextcloud";
            } else if (r.provider == "google") {
                d["google-photos"] = "https://photoslibrary.googleapis.com/v1/";
                d["google-photos-picker"] = "https://photospicker.googleapis.com/v1/";
                d["photos-api"] = "google";
            } else if (r.provider == "microsoft") {
                d["photos-api"] = "onedrive";
            }
            foreach (var e in d.entries) {
                if (!r.endpoints.has_key(e.key)) r.endpoints[e.key] = e.value;
            }
            if (r.auth == "oauth2") {
                var client = OAuthConfig.load(r.provider);
                foreach (var e in client.endpoints.entries) {
                    if (e.key.has_prefix("google-photos")) r.endpoints[e.key] = e.value.replace("{email}", r.identity);
                }
            }
            return true;
        }

        public string consent_scopes(string provider, string[]? capabilities = null) {
            if (provider == "spotify") return SPOTIFY_SCOPES;
            if (provider == "google") {
                if (capabilities == null) return GOOGLE_SCOPES;
                var sb = new StringBuilder(GOOGLE_BASE_SCOPES);
                foreach (string c in capabilities) {
                    string scope = scope_for_capability(provider, c);
                    if (scope != "") sb.append(" ").append(scope);
                }
                return sb.str;
            }
            string scopes = MICROSOFT_GRAPH_SCOPES + " " + MICROSOFT_GRAPH_MAIL_SCOPES + " " + MICROSOFT_GRAPH_MAIL_SHARED_SCOPES + " "
                + MICROSOFT_GRAPH_SHARED_SCOPES + " " + MICROSOFT_GRAPH_FILES_SHARED_SCOPES + " https://graph.microsoft.com/Files.ReadWrite.AppFolder";
            if (capabilities != null && "chat" in capabilities) scopes += " " + MICROSOFT_CHAT_SCOPES;
            if (capabilities != null && MICROSOFT_IMAP_FALLBACK in capabilities) scopes += " https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send";
            return scopes;
        }

        private void put_all(AccountRecord r, Gee.Map<string, string> values) {
            foreach (var e in values.entries) r.endpoints[e.key] = e.value.replace("{email}", r.identity);
        }

        public void apply_defaults(AccountRecord r, OAuthClient? client) {
            var d = new Gee.HashMap<string, string>();
            switch (r.provider) {
                case "nextcloud":
                case "owncloud": {
                    string user = r.endpoint("dav-user", r.identity);
                    d["caldav"] = r.server + "/remote.php/dav/";
                    d["carddav"] = r.server + "/remote.php/dav/";
                    d["webdav"] = r.server + "/remote.php/dav/files/" + Uri.escape_string(user, "@", false) + "/";
                    d["calendar-api"] = "caldav";
                    d["contacts-api"] = "carddav";
                    d["tasks-api"] = "caldav";
                    d["files-api"] = "webdav";
                    if (r.provider == "nextcloud") {
                        d["photos"] = r.server + "/remote.php/dav/photos/" + Uri.escape_string(user, "@", false) + "/";
                        d["photos-api"] = "nextcloud";
                        d["music-api"] = "webdav";
                        d["chat-api"] = "talk";
                    }
                    break;
                }
                case "google":
                    d["mail-address"] = "{email}";
                    d["imap-host"] = "imap.gmail.com";
                    d["imap-port"] = "993";
                    d["imap-security"] = "tls";
                    d["imap-user"] = "{email}";
                    d["smtp-host"] = "smtp.gmail.com";
                    d["smtp-port"] = "465";
                    d["smtp-security"] = "tls";
                    d["smtp-user"] = "{email}";
                    if (r.auth == "oauth2") {
                        d["mail-auth"] = "xoauth2";
                        d["caldav"] = "https://apidata.googleusercontent.com/caldav/v2/{email}/user";
                        d["carddav"] = "https://www.googleapis.com/carddav/v1/principals/{email}/lists/default/";
                        d["google-tasks"] = "https://tasks.googleapis.com/tasks/v1/";
                        d["google-drive"] = "https://www.googleapis.com/drive/v3/";
                        d["google-drive-upload"] = "https://www.googleapis.com/upload/drive/v3/";
                        d["calendar-api"] = "caldav";
                        d["contacts-api"] = "carddav";
                        d["tasks-api"] = "google";
                        d["files-api"] = "google-drive";
                        d["google-photos"] = "https://photoslibrary.googleapis.com/v1/";
                        d["google-photos-picker"] = "https://photospicker.googleapis.com/v1/";
                        d["photos-api"] = "google";
                        d["youtube"] = "https://www.googleapis.com/youtube/v3/";
                        d["videos-api"] = "youtube";
                        d["google-chat"] = "https://chat.googleapis.com/v1/";
                        d["chat-api"] = "google-chat";
                    } else {
                        d["mail-auth"] = "password";
                    }
                    break;
                case "microsoft":
                    d["mail-address"] = "{email}";
                    d["mail-api"] = "graph";
                    d["imap-host"] = "outlook.office365.com";
                    d["imap-port"] = "993";
                    d["imap-security"] = "tls";
                    d["imap-user"] = "{email}";
                    d["smtp-host"] = "smtp.office365.com";
                    d["smtp-port"] = "587";
                    d["smtp-security"] = "starttls";
                    d["smtp-user"] = "{email}";
                    d["mail-auth"] = "xoauth2";
                    d["graph"] = "https://graph.microsoft.com/v1.0/";
                    d["calendar-api"] = "graph";
                    d["contacts-api"] = "graph";
                    d["tasks-api"] = "graph";
                    d["files-api"] = "onedrive";
                    d["photos-api"] = "onedrive";
                    d["chat-api"] = "teams";
                    break;
                case "spotify":
                    d["spotify-api"] = "https://api.spotify.com/v1/";
                    d["music-api"] = "spotify";
                    break;
                default:
                    break;
            }
            foreach (var e in d.entries) {
                if (!r.endpoints.has_key(e.key)) r.endpoints[e.key] = e.value.replace("{email}", r.identity);
            }
            if (client != null) put_all(r, client.endpoints);
        }
    }
}
