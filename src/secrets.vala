namespace Singularity.AccountsDaemon {

    namespace Secrets {
        private Secret.Schema? schema_instance;

        private Secret.Schema schema() {
            if (schema_instance == null) {
                schema_instance = new Secret.Schema("dev.sinty.Accounts", Secret.SchemaFlags.NONE,
                    "account", Secret.SchemaAttributeType.STRING,
                    "kind", Secret.SchemaAttributeType.STRING);
            }
            return schema_instance;
        }

        public async void store(AccountRecord r, string kind, string secret) throws AccountsError {
            try {
                bool ok = yield Secret.password_store(schema(), Secret.COLLECTION_DEFAULT,
                    _("Online account %s (%s)").printf(r.identity, kind), secret, null, "account", r.id, "kind", kind);
                if (!ok) throw new AccountsError.UNAVAILABLE(_("The keyring did not store the secret"));
            } catch (AccountsError e) {
                throw e;
            } catch (Error e) {
                throw new AccountsError.UNAVAILABLE(_("The keyring is not available: %s").printf(e.message));
            }
        }

        public async string? lookup(string account_id, string kind) throws AccountsError {
            try {
                return yield Secret.password_lookup(schema(), null, "account", account_id, "kind", kind);
            } catch (Error e) {
                throw new AccountsError.UNAVAILABLE(_("The keyring is not available: %s").printf(e.message));
            }
        }

        public async void clear(string account_id) {
            foreach (string kind in new string[] { "password", "refresh-token" }) {
                try {
                    yield Secret.password_clear(schema(), null, "account", account_id, "kind", kind);
                } catch (Error e) {
                    warning("cannot clear %s secret of %s: %s", kind, account_id, e.message);
                }
            }
        }
    }
}
