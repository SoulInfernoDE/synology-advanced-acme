#!/usr/bin/env python3
"""Build-time helper: extract the option metadata of every acme.sh DNS plugin.

Each acme.sh dnsapi script carries a `dns_<id>_info='...'` block that lists its
name, website and the environment variables it reads. The GUI uses this JSON to
render a form for any DNS provider without shipping provider-specific code.

It also writes "<output>.keys" ("<plugin> <VAR>" per line), the allowlist the
backend uses before exporting user-supplied variables.

Usage: gen-dnsapi.py <acme.sh dnsapi dir> <output json> <output keys>
"""
import json
import re
import sys
from pathlib import Path

INFO_RE = re.compile(r"^dns_([A-Za-z0-9_]+)_info='(.*?)'", re.S | re.M)


def parse_options(lines):
    opts = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        key, _, desc = line.partition(" ")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        opts.append({
            "key": key,
            "desc": desc.strip(),
            "optional": "optional" in desc.lower(),
        })
    return opts


def parse(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    m = INFO_RE.search(text)
    plugin_id = path.stem
    if not m:
        return {"id": plugin_id, "name": plugin_id[4:], "site": "", "docs": "",
                "options": [], "optionsAlt": []}
    body = m.group(2).splitlines()
    entry = {"id": plugin_id, "name": body[0].strip() if body else plugin_id,
             "site": "", "docs": "", "options": [], "optionsAlt": []}
    section = None
    buf = {"Options": [], "OptionsAlt": []}
    for raw in body[1:]:
        head = raw.split(":", 1)[0].strip()
        if not raw.startswith(" ") and head in ("Site", "Docs", "Issues", "Author", "Options", "OptionsAlt"):
            value = raw.split(":", 1)[1].strip() if ":" in raw else ""
            section = head if head in buf else None
            if head == "Site":
                entry["site"] = value
            elif head == "Docs":
                entry["docs"] = value
            continue
        if section:
            buf[section].append(raw)
    entry["options"] = parse_options(buf["Options"])
    entry["optionsAlt"] = parse_options(buf["OptionsAlt"])
    return entry


def main():
    src, out, keys = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    plugins = [parse(p) for p in sorted(src.glob("dns_*.sh"))]
    plugins.sort(key=lambda p: p["name"].lower())
    out.write_text(json.dumps(plugins, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    lines = sorted({f"{p['id']} {o['key']}" for p in plugins for o in p["options"] + p["optionsAlt"]})
    keys.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(plugins)} DNS plugins -> {out}")


if __name__ == "__main__":
    main()
