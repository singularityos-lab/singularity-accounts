using Singularity.CloudMount;

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    var loop = new MainLoop();
    var controller = new Controller();
    var service = new Service(controller);
    bool started = false;

    SourceFunc shutdown = () => {
        controller.stop_all();
        loop.quit();
        return Source.REMOVE;
    };
    Unix.signal_add(ProcessSignal.TERM, () => shutdown());
    Unix.signal_add(ProcessSignal.INT, () => shutdown());
    Unix.signal_add(ProcessSignal.HUP, () => shutdown());

    Bus.own_name(BusType.SESSION, "dev.sinty.CloudMount", BusNameOwnerFlags.NONE,
        (conn) => {
            conn.exit_on_close = false;
            conn.on_closed.connect(() => {
                message("the session ended");
                shutdown();
            });
            try {
                conn.register_object("/dev/sinty/CloudMount", service);
            } catch (IOError e) {
                critical("cannot export the cloud mount service: %s", e.message);
                loop.quit();
            }
        },
        () => {
            if (started) return;
            started = true;
            controller.start.begin();
        },
        () => {
            if (!started) warning("dev.sinty.CloudMount is already running");
            else warning("lost dev.sinty.CloudMount");
            shutdown();
        });

    loop.run();
    return 0;
}
