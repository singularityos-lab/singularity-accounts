import json
import sys


def literal(value):
    text = value if isinstance(value, str) else ""
    return '"' + "".join(c if c.isalnum() or c in "-._~@:+/=" else "\\u%04x" % ord(c) for c in text.strip()) + '"'


def entry(data, provider):
    item = data.get(provider) if isinstance(data, dict) else None
    if isinstance(item, dict) and isinstance(item.get("installed"), dict):
        item = item["installed"]
    return item if isinstance(item, dict) else {}


data = {}
if len(sys.argv) > 2:
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
out = sys.argv[-1]
google = entry(data, "google")
microsoft = entry(data, "microsoft")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("namespace Singularity.AccountsDaemon.BuildConfig {\n")
    fh.write("    public const string GOOGLE_CLIENT_ID = %s;\n" % literal(google.get("client_id", "")))
    fh.write("    public const string GOOGLE_CLIENT_SECRET = %s;\n" % literal(google.get("client_secret", "")))
    fh.write("    public const string MICROSOFT_CLIENT_ID = %s;\n" % literal(microsoft.get("client_id", "")))
    fh.write("    public const string MICROSOFT_TENANT = %s;\n" % literal(microsoft.get("tenant", "")))
    fh.write("}\n")
