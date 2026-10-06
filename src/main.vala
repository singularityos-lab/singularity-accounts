using Singularity.AccountsDaemon;

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    var loop = new MainLoop();
    var store = new AccountStore(AccountStore.default_path());
    var service = new Service(store);
    int idle_limit = 600;
    string? env = Environment.get_variable("SINGULARITY_ACCOUNTS_IDLE");
    if (env != null) idle_limit = int.parse(env);
    int64 last = get_monotonic_time();
    service.touched.connect(() => last = get_monotonic_time());
    service.sign_in_finished.connect(() => last = get_monotonic_time());

    Bus.own_name(BusType.SESSION, "dev.sinty.Accounts", BusNameOwnerFlags.NONE,
        (conn) => {
            try {
                conn.register_object("/dev/sinty/Accounts", service);
            } catch (IOError e) {
                critical("cannot export the accounts service: %s", e.message);
                loop.quit();
            }
        },
        () => {},
        () => {
            warning("lost or could not own dev.sinty.Accounts");
            loop.quit();
        });

    if (idle_limit > 0) {
        Timeout.add_seconds(30, () => {
            if (service.busy) {
                last = get_monotonic_time();
            } else if ((get_monotonic_time() - last) / 1000000 > idle_limit) {
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }
    loop.run();
    return 0;
}
