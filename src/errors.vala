namespace Singularity.AccountsDaemon {

    [DBus (name = "dev.sinty.Accounts.Error")]
    public errordomain AccountsError {
        NOT_FOUND,
        NEEDS_REAUTH,
        NOT_CONFIGURED,
        NETWORK,
        AUTH_FAILED,
        PROTOCOL,
        CANCELLED,
        INVALID,
        CONFLICT,
        UNAVAILABLE
    }

    public string bytes_text(Bytes? bytes) {
        if (bytes == null || bytes.get_size() == 0) return "";
        var sb = new StringBuilder.sized(bytes.get_size() + 1);
        sb.append_len((string) bytes.get_data(), (ssize_t) bytes.get_size());
        return sb.str;
    }

    public string random_token(int bytes = 32) {
        var raw = new uint8[bytes];
        try {
            var f = File.new_for_path("/dev/urandom").read();
            size_t read;
            f.read_all(raw, out read);
            f.close();
        } catch (Error e) {
            for (int i = 0; i < bytes; i++) raw[i] = (uint8) Random.int_range(0, 256);
        }
        return base64url(raw);
    }

    public string base64url(uint8[] data) {
        return Base64.encode(data).replace("+", "-").replace("/", "_").replace("=", "");
    }

    public uint8[] base64url_decode(string text) {
        string s = text.replace("-", "+").replace("_", "/");
        while (s.length % 4 != 0) s += "=";
        return Base64.decode(s);
    }
}
