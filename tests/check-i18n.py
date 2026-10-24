#!/usr/bin/env python3
"""Check that every translation key used by the web UI exists in the English
base catalog, and that the other catalogs contain no unknown keys."""
import json
import re
import sys
from pathlib import Path

UI = Path(__file__).resolve().parent.parent / "src" / "ui"
js = (UI / "app.js").read_text(encoding="utf-8")
en = json.loads((UI / "i18n" / "en.json").read_text(encoding="utf-8"))

used = set(re.findall(r'\bt\("([a-z0-9_.]+)"', js))
used |= set(re.findall(r'"((?:hint|link)\.[a-z0-9_]+)"', js))
used |= set(re.findall(r'richText\("([a-z0-9_.]+)"', js))
used |= set(re.findall(r'"(help\.link_[a-z0-9_]+)"', js))
used = {k for k in used if not k.endswith(".")}

# Keys built at runtime from fixed lists.
providers = ["ionos", "letsencrypt", "zerossl", "custom"]
used |= {f"provider.{p}.{f}" for p in providers for f in ("name", "desc")}
used |= {f"tab.{x}" for x in ("certs", "new", "settings", "expert", "help")}
used |= {f"wiz.step.{x}" for x in ("connect", "provider", "account", "dns", "domains", "dsm", "summary")}
used |= {f"job.step.{x}" for x in ("register", "issue", "deploy", "renew", "acme_update")}
used |= {f"jobtype.{x}" for x in ("register", "issue", "renew", "deploy", "expert", "cron", "acme_update")}
used |= {f"help.{x}.{y}" for x in ("how", "ionos180", "updates", "dsm_gui", "security", "dsm_account", "dsm_task", "default", "uninstall", "dns01") for y in ("q", "a")}

# Error codes the backend can return.
backend = ""
for f in list((UI.parent / "lib").glob("*.sh")) + [UI / "api.cgi"]:
    backend += f.read_text(encoding="utf-8")
# fail/deny used as commands, not the words in comments.
codes = set(re.findall(r'(?:^|\|\||&&|;|\)|then|else)\s*(?:fail|deny) ([a-z_]+)', backend, re.M))
codes |= set(re.findall(r'"error":"([a-z_]+)"', backend))
codes |= set(re.findall(r'dsm_svc_fail (dsm_svc_[a-z_]+)', backend))
codes |= set(re.findall(r'"error":"(dsm_task_[a-z_]+)"', backend))
codes |= {"dsm_task_jq_missing"}
codes.discard("dsm_task_")
# Steps in the history (activity_log EVENT ...).
used |= {f"activity.{e}" for e in re.findall(r'activity_log ([a-z_]+)', backend)}
codes |= {"network", "bad_response", "dsm_list_105"}
codes |= {f"dsm_auth_{c}" for c in ("unreachable", "nosid", "400", "401", "402", "403", "404", "406", "407", "408", "409", "410")}
codes.discard("dsm_auth_")
codes.discard("dsm_list_")
used |= {f"err.{c}" for c in codes}

errors = []
missing = sorted(k for k in used if k not in en)
if missing:
    errors.append("missing in en.json: " + ", ".join(missing))

for cat in sorted((UI / "i18n").glob("*.json")):
    if cat.name == "en.json":
        continue
    data = json.loads(cat.read_text(encoding="utf-8"))
    unknown = sorted(k for k in data if k not in en)
    if unknown:
        errors.append(f"unknown keys in {cat.name}: " + ", ".join(unknown))
    untranslated = sorted(k for k in en if k not in data and not k.startswith("link."))
    if untranslated:
        errors.append(f"untranslated in {cat.name}: " + ", ".join(untranslated))
    for k, v in data.items():
        if set(re.findall(r"\{(\w+)\}", v)) != set(re.findall(r"\{(\w+)\}", en.get(k, ""))):
            errors.append(f"placeholder mismatch in {cat.name}: {k}")

# Languages offered by the app must match the catalogs on disk.
langs = set(re.findall(r'^\s+"?([a-zA-Z-]+)"?: "[^"]+",?$', js[js.index("const LANGS"):js.index("};", js.index("const LANGS"))], re.M))
files = {c.stem for c in (UI / "i18n").glob("*.json")}
if langs != files:
    errors.append(f"LANGS in app.js {sorted(langs)} != catalogs {sorted(files)}")
dsm_map = js[js.index("const DSM_LANGS"):js.index("};", js.index("const DSM_LANGS"))]
for dsm, lang in re.findall(r'(\w+): "([a-zA-Z-]+)"', dsm_map):
    if lang not in files:
        errors.append(f"DSM language {dsm} maps to missing catalog {lang}")
    if not (UI / "texts" / dsm / "strings").is_file():
        errors.append(f"DSM language {dsm} has no texts/{dsm}/strings")

# DSM strings (main menu, notifications) and Package Center descriptions.
def dsm_keys(path):
    section, keys = None, set()
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\[(\w+)\]$", line)
        if m:
            section = m.group(1)
        elif "=" in line:
            keys.add(f"{section}:{line.split('=', 1)[0]}")
    return keys
base_keys = dsm_keys(UI / "texts" / "enu" / "strings")
desc_dir = UI.parent.parent / "package" / "descriptions"
for d in sorted((UI / "texts").iterdir()):
    k = dsm_keys(d / "strings")
    if k != base_keys:
        errors.append(f"texts/{d.name}/strings keys differ: {sorted(k ^ base_keys)}")
    if not (desc_dir / f"{d.name}.txt").is_file():
        errors.append(f"package/descriptions/{d.name}.txt missing")
    wiz = UI.parent.parent / "package" / "WIZARD_UIFILES" / ("uninstall_uifile" if d.name == "enu" else f"uninstall_uifile_{d.name}")
    try:
        steps = json.loads(wiz.read_text(encoding="utf-8"))
        keys = [sub["key"] for step in steps for item in step["items"] for sub in item.get("subitems", [])]
        if keys != ["wizard_delete_data"]:
            errors.append(f"{wiz.name}: unexpected keys {keys}")
    except (OSError, ValueError, KeyError) as e:
        errors.append(f"{wiz.name}: {e}")
config = (UI / "config").read_text(encoding="utf-8")
for key in base_keys:
    if key.startswith("notify:") and f'"{key}"' not in config:
        errors.append(f"{key} missing in preloadTexts of ui/config")

unused = sorted(k for k in en if k not in used)
if unused:
    print("note: unused keys in en.json: " + ", ".join(unused))

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"i18n OK: {len(used)} keys used, {len(en)} in en.json, {len(files)} catalogs, {len(list((UI / 'texts').iterdir()))} DSM languages")
