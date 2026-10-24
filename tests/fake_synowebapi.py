#!/usr/bin/env python3
"""Stand-in for DSM's /usr/syno/bin/synowebapi in the end-to-end test:
"--exec api=X method=Y version=N key=json_value..." is forwarded to the mock
DSM (FAKE_SYNO_URL). Not for production use."""
import json
import os
import sys
import urllib.request

args = sys.argv[1:]
if not args or args[0] != "--exec":
    sys.exit(2)
fields, params = {}, {}
for a in args[1:]:
    k, _, v = a.partition("=")
    if k in ("api", "method", "version"):
        fields[k] = v
        continue
    try:
        params[k] = json.loads(v)
    except ValueError:
        params[k] = v
print("[Line 295] Exec WebAPI: api=%s" % fields.get("api"), file=sys.stderr)
req = urllib.request.Request(os.environ["FAKE_SYNO_URL"], json.dumps(dict(fields, params=params)).encode(),
                             headers={"Content-Type": "application/json"})
print(json.dumps(json.loads(urllib.request.urlopen(req).read()), indent=3))
