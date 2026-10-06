using Gtk;
using Singularity.AccountsDaemon;

namespace Singularity.AccountsSignIn {

    [DBus (name = "dev.sinty.Accounts")]
    public interface AccountsBus : Object {
        public abstract async void complete_sign_in(string flow_id, string address) throws GLib.Error;
        public abstract async void cancel_sign_in(string flow_id) throws GLib.Error;
        public signal void sign_in_finished(string flow_id, string account_id, string error_message);
    }

    public static bool switched_to_browser = false;
    public static bool cancelled = false;

    public class SignInWindow : Singularity.Widgets.Window {
        private string flow_id;
        private string start_url;
        private string redirect_uri;
        private string provider_name;
        private string provider_icon;
        private WebKit.WebView web;
        private Stack stack;
        private Singularity.Widgets.StatusPage status;
        private Image lock_icon;
        private Label host_label;
        private AccountsBus? bus;
        private bool handed_over;
        private bool done;
        private bool local_flow;

        public SignInWindow(Gtk.Application app, string flow_id, string url, string provider_name, string provider_icon) {
            base(app);
            this.flow_id = flow_id;
            this.start_url = url;
            this.provider_name = provider_name;
            this.provider_icon = provider_icon != "" ? provider_icon : "singularity-account-generic";
            this.redirect_uri = Redirect.redirect_of(url);
            this.local_flow = flow_id == "";
            set_title(_("Sign In to %s").printf(provider_name));
            set_default_size(520, 720);

            var address = new Box(Orientation.HORIZONTAL, 6);
            lock_icon = new Image.from_icon_name("channel-secure-symbolic");
            lock_icon.pixel_size = 12;
            address.append(lock_icon);
            host_label = new Label("");
            host_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            host_label.max_width_chars = 32;
            address.append(host_label);
            address.add_css_class("singularity-hover-label");
            add_bubble_widget(address);
            add_bubble_text(_("Cancel"), () => cancel_and_close());

            var session = new WebKit.NetworkSession.ephemeral();
            web = (WebKit.WebView) Object.new(typeof(WebKit.WebView), "network-session", session);
            var settings = web.get_settings();
            settings.set_user_agent_with_application_details("Singularity", "1.0");
            settings.enable_developer_extras = false;
            settings.javascript_can_open_windows_automatically = false;
            web.decide_policy.connect(on_decide_policy);
            web.notify["uri"].connect(update_address);
            web.load_changed.connect((ev) => {
                if (local_flow && handed_over && ev == WebKit.LoadEvent.FINISHED) {
                    done = true;
                    close();
                }
            });
            web.load_failed.connect((ev, uri, error) => {
                if (handed_over || error.matches(WebKit.NetworkError.quark(), WebKit.NetworkError.CANCELLED)) return false;
                if (error.matches(WebKit.PolicyError.quark(), WebKit.PolicyError.FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) return false;
                show_status("network-error", _("Could Not Open the Sign-In Page"), error.message, true);
                return true;
            });
            web.hexpand = true;
            web.vexpand = true;
            Singularity.Widgets.apply_view_edge(web);

            status = new Singularity.Widgets.StatusPage();
            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named(web, "web");
            stack.add_named(status, "status");
            var edge = new Box(Orientation.VERTICAL, 0);
            edge.append(stack);
            set_content(edge);

            close_request.connect(() => {
                if (!done) cancel_flow();
                return false;
            });
            if (!local_flow) connect_bus.begin();
            web.load_uri(url);
            update_address();
        }

        private async void connect_bus() {
            try {
                bus = yield Bus.get_proxy<AccountsBus>(BusType.SESSION, "dev.sinty.Accounts", "/dev/sinty/Accounts");
                bus.sign_in_finished.connect((flow, account, error_message) => {
                    if (flow != flow_id) return;
                    done = true;
                    if (error_message == "") {
                        close();
                    } else {
                        show_status("dialog-error", _("Sign-In Failed"), error_message, false);
                    }
                });
            } catch (GLib.Error e) {
                show_status("dialog-error", _("Online Accounts Unavailable"), e.message, false);
            }
        }

        private void update_address() {
            string uri = web.uri != null && web.uri != "" ? web.uri : start_url;
            try {
                var u = Uri.parse(uri, UriFlags.NONE);
                host_label.label = u.get_host() ?? uri;
                bool secure = u.get_scheme() == "https";
                lock_icon.icon_name = secure ? "channel-secure-symbolic" : "channel-insecure-symbolic";
                host_label.tooltip_text = secure ? _("Secure connection to %s").printf(u.get_host()) : _("Not a secure connection");
            } catch (UriError e) {
                host_label.label = uri;
            }
        }

        private bool on_decide_policy(WebKit.PolicyDecision decision, WebKit.PolicyDecisionType type) {
            if (type != WebKit.PolicyDecisionType.NAVIGATION_ACTION && type != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) return false;
            var action = ((WebKit.NavigationPolicyDecision) decision).navigation_action;
            string uri = action.get_request().uri;
            if (local_flow && redirect_uri != "" && Redirect.is_redirect(uri, redirect_uri)) {
                handed_over = true;
                return false;
            }
            if (redirect_uri != "" && Redirect.is_redirect(uri, redirect_uri)) {
                decision.ignore();
                hand_over.begin(uri);
                return true;
            }
            if (Redirect.is_blocked(uri)) {
                decision.ignore();
                show_blocked();
                return true;
            }
            if (type == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION) {
                decision.ignore();
                web.load_uri(uri);
                return true;
            }
            return false;
        }

        private async void hand_over(string uri) {
            if (handed_over) return;
            handed_over = true;
            show_status(provider_icon, _("Finishing Sign-In"), _("Checking the answer from %s.").printf(provider_name), false);
            try {
                if (bus == null) bus = yield Bus.get_proxy<AccountsBus>(BusType.SESSION, "dev.sinty.Accounts", "/dev/sinty/Accounts");
                yield bus.complete_sign_in(flow_id, uri);
            } catch (GLib.Error e) {
                done = true;
                show_status("dialog-error", _("Sign-In Failed"), strip(e.message), false);
            }
        }

        private static string strip(string message) {
            int at = message.index_of("dev.sinty.Accounts.Error.");
            if (at >= 0) {
                int colon = message.index_of(": ", at);
                if (colon >= 0) return message.substring(colon + 2);
            }
            return message;
        }

        private void show_blocked() {
            status.icon_name = provider_icon;
            status.title = _("Use Your Browser for %s").printf(provider_name);
            status.description = _("%s does not allow signing in from this window. Continue in your browser; if it shows an error page after you approve, copy its address into Settings.").printf(provider_name);
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.CENTER;
            var cancel = new Button.with_label(_("Cancel"));
            cancel.add_css_class("pill");
            cancel.clicked.connect(() => cancel_and_close());
            box.append(cancel);
            var open = new Button.with_label(_("Open in Your Browser"));
            open.add_css_class("pill");
            open.add_css_class("suggested-action");
            open.clicked.connect(() => {
                try {
                    AppInfo.launch_default_for_uri(start_url, null);
                } catch (GLib.Error e) {
                    warning("cannot open the browser: %s", e.message);
                }
                done = true;
                switched_to_browser = true;
                close();
            });
            box.append(open);
            status.child = box;
            stack.visible_child_name = "status";
        }

        private void show_status(string icon, string title, string description, bool can_retry) {
            status.icon_name = icon;
            status.title = title;
            status.description = description;
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.halign = Align.CENTER;
            if (can_retry) {
                var retry = new Button.with_label(_("Try Again"));
                retry.add_css_class("pill");
                retry.clicked.connect(() => {
                    stack.visible_child_name = "web";
                    web.load_uri(start_url);
                });
                box.append(retry);
            }
            if (done || can_retry) {
                var close_btn = new Button.with_label(_("Close"));
                close_btn.add_css_class("pill");
                close_btn.clicked.connect(() => close());
                box.append(close_btn);
            }
            status.child = box;
            stack.visible_child_name = "status";
        }

        private void cancel_flow() {
            if (done) return;
            done = true;
            if (local_flow) {
                cancelled = true;
                return;
            }
            if (bus != null) bus.cancel_sign_in.begin(flow_id);
        }

        private void cancel_and_close() {
            cancel_flow();
            close();
        }
    }

    public class SignInApp : Singularity.Application {
        private string flow_id = "";
        private string url = "";
        private string provider_name = "";
        private string provider_icon = "";

        public SignInApp() {
            base("dev.sinty.AccountsSignIn", ApplicationFlags.NON_UNIQUE);
            add_main_option("flow", 0, OptionFlags.NONE, OptionArg.STRING, "Sign-in flow identifier", "ID");
            add_main_option("url", 0, OptionFlags.NONE, OptionArg.STRING, "Sign-in page address", "URL");
            add_main_option("provider-name", 0, OptionFlags.NONE, OptionArg.STRING, "Provider name", "NAME");
            add_main_option("provider-icon", 0, OptionFlags.NONE, OptionArg.STRING, "Provider icon name", "ICON");
            handle_local_options.connect((options) => {
                string? v;
                if (options.lookup("flow", "s", out v)) flow_id = v;
                if (options.lookup("url", "s", out v)) url = v;
                if (options.lookup("provider-name", "s", out v)) provider_name = v;
                if (options.lookup("provider-icon", "s", out v)) provider_icon = v;
                if (url == "") {
                    printerr("usage: singularity-accounts-signin [--flow ID] --url URL --provider-name NAME\n");
                    return 2;
                }
                return -1;
            });
        }

        protected override void activate() {
            base.activate();
            var window = new SignInWindow(this, flow_id, url, provider_name != "" ? provider_name : _("Your Account"), provider_icon);
            window.present();
        }
    }
}

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    Environment.set_application_name(_("Online Accounts"));
    int status = new Singularity.AccountsSignIn.SignInApp().run(args);
    if (Singularity.AccountsSignIn.switched_to_browser) return 3;
    if (Singularity.AccountsSignIn.cancelled) return 1;
    return status;
}
