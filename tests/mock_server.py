#!/usr/bin/env python3
"""Mock of the DSM Web API (login, 2FA, certificate list/import, user
management) and of the IONOS DNS zone list, for the end-to-end test. Not for
production use."""
import json
import os
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERS = {"certbot": {"password": "s3cret pass&=", "otp": None},
         "otpuser": {"password": "pw", "otp": "123456"},
         "viewer": {"password": "pw", "otp": None, "admin": False}}
# Users created through SYNO.Core.User need 2-step verification when the
# test switches this on (DSM policy "enforce 2-step verification").
SETTINGS = {"otp_enforced": False, "password_must_change": False}
# Field order matters: DSM lists "desc" before "id", and the synology_dsm hook
# parses the response with a regular expression that relies on it.
STATE = {"certs": [{"desc": "", "id": "def01", "is_default": True, "renewable": False,
                    "subject": {"common_name": "synology"}, "valid_till": "Jan  1 00:00:00 2030 GMT",
                    "services": [{"display_name": "DSM Desktop Service"}]}],
         "imports": [], "sessions": {}, "logins": [], "tasks": []}
IONOS_KEY = "pfx123.secret456"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, obj, code=200):
        # DSM answers with compact JSON; the synology_dsm hook relies on that.
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def params(self):
        q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query, keep_blank_values=True))
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        ctype = self.headers.get("Content-Type", "")
        if raw and "multipart/form-data" in ctype:
            boundary = ctype.split("boundary=")[1].encode()
            for part in raw.split(b"--" + boundary):
                if b"Content-Disposition" not in part:
                    continue
                head, _, val = part.partition(b"\r\n\r\n")
                name = head.split(b'name="')[1].split(b'"')[0].decode()
                q[name] = val.rstrip(b"\r\n").decode(errors="replace")
        elif raw:
            q.update(dict(urllib.parse.parse_qsl(raw.decode(), keep_blank_values=True)))
        return q

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def route(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/_state":
            users = {n: {"admin": u.get("admin", True), "desc": u.get("desc", ""), "pwlen": len(u["password"])}
                     for n, u in USERS.items()}
            return self.send(dict({k: v for k, v in STATE.items() if k != "sessions"}, users=users))
        if path == "/_syno":
            return self.syno_exec()
        if path == "/_set":
            q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
            for key in ("otp_enforced", "password_must_change"):
                if key in q:
                    SETTINGS[key] = q[key] == "1"
            if "adduser" in q:
                USERS[q["adduser"]] = {"password": "x", "otp": None, "admin": False, "desc": q.get("desc", "")}
            if "deluser" in q:
                USERS.pop(q["deluser"], None)
            return self.send({"success": True})
        if path == "/dns/v1/zones":
            if self.headers.get("X-API-Key") != IONOS_KEY:
                return self.send({"message": "unauthorized"}, 401)
            return self.send([{"name": "example.test", "id": "z1", "type": "NATIVE"},
                              {"name": "other.test", "id": "z2", "type": "NATIVE"}])
        p = self.params()
        if path == "/webapi/query.cgi":
            return self.send({"data": {"SYNO.API.Auth": {"maxVersion": 7, "minVersion": 1, "path": "entry.cgi"}},
                              "success": True})
        if path != "/webapi/entry.cgi":
            return self.send({"error": "not found"}, 404)
        api, method = p.get("api"), p.get("method")
        if api == "SYNO.API.Auth" and method == "login":
            u = USERS.get(p.get("account"))
            STATE["logins"].append({k: p.get(k) for k in ("account", "otp_code", "device_id", "device_name")})
            if not u or u["password"] != p.get("passwd"):
                return self.send({"error": {"code": 400}, "success": False})
            if u.get("otp_setup_required"):
                return self.send({"error": {"code": 406}, "success": False})
            if u.get("must_change"):
                return self.send({"error": {"code": 410}, "success": False})
            out = {"sid": "sid-" + p["account"], "synotoken": "tok"}
            if u["otp"]:
                if p.get("device_id") == "dev-1":
                    pass
                elif p.get("otp_code") == u["otp"]:
                    out["device_id"] = "dev-1"
                elif p.get("otp_code"):
                    return self.send({"error": {"code": 404}, "success": False})
                else:
                    return self.send({"error": {"code": 403}, "success": False})
            STATE["sessions"][out["sid"]] = p["account"]
            return self.send({"data": out, "success": True})
        if api == "SYNO.API.Auth" and method == "reset":
            u = USERS.get(p.get("account"))
            if not u or u["password"] != p.get("passwd") or not p.get("new_passwd"):
                return self.send({"error": {"code": 400}, "success": False})
            u["password"] = p["new_passwd"]
            u["must_change"] = False
            return self.send({"data": {"tid": "t1"}, "success": True})
        if api == "SYNO.API.Auth" and method == "logout":
            return self.send({"success": True})
        user = STATE["sessions"].get(p.get("_sid"))
        if not user:
            return self.send({"error": {"code": 119}, "success": False})
        if USERS[user].get("admin") is False:
            return self.send({"error": {"code": 105}, "success": False})
        # Like DSM: no user management in sessions from the loopback address.
        # The test reaches the "LAN address" as 127.0.0.2.
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if (api in ("SYNO.Core.User.Group", "SYNO.Core.TaskScheduler.Root", "SYNO.Core.User.PasswordConfirm")
                or api == "SYNO.Core.User" and method != "get") and host in ("localhost", "127.0.0.1"):
            return self.send({"error": {"code": 105}, "success": False})
        if api == "SYNO.Core.User.PasswordConfirm" and method == "auth":
            if p.get("version") != "2" or json.loads(p.get("password", '""')) != USERS[user]["password"]:
                return self.send({"error": {"code": 400}, "success": False})
            return self.send({"data": {"SynoConfirmPWToken": "pwtok-" + user}, "success": True})
        if api.startswith("SYNO.Core.TaskScheduler"):
            return self.task_api(user, api, method, p)
        if api == "SYNO.Core.User":
            return self.user_api(user, method, p)
        if api == "SYNO.Core.User.Group" and method == "join":
            name = json.loads(p["name"])
            if "administrators" in json.loads(p.get("join_group", "[]")) and name in USERS:
                USERS[name]["admin"] = True
            return self.send({"data": {"task_id": "@administrators/groupbatch1"}, "success": True})
        if api == "SYNO.Core.User.Group" and method == "join_status":
            return self.send({"data": {"finish": True, "success": True}, "success": True})
        if api == "SYNO.Core.Certificate.CRT" and method == "list":
            return self.send({"data": {"certificates": STATE["certs"]}, "success": True})
        if api == "SYNO.Core.Certificate" and method == "import":
            cid = p.get("id") or "c%02d" % (len(STATE["certs"]) + 1)
            existing = [c for c in STATE["certs"] if c["id"] == cid]
            if existing:
                existing[0]["desc"] = p.get("desc", "")
            else:
                STATE["certs"].append({"desc": p.get("desc", ""), "id": cid, "is_default": False,
                                       "subject": {"common_name": "imported"}, "services": []})
            STATE["imports"].append({"id": cid, "desc": p.get("desc"), "as_default": p.get("as_default"),
                                     "has_key": "PRIVATE KEY" in p.get("key", ""),
                                     "has_cert": "BEGIN CERTIFICATE" in p.get("cert", "")})
            return self.send({"data": {"id": cid, "restart_httpd": False}, "success": True})
        return self.send({"error": {"code": 103}, "success": False})


    def user_api(self, user, method, p):
        if method == "get":
            name = json.loads(p["name"])
            if name not in USERS:
                return self.send({"error": {"code": 3106}, "success": False})
            return self.send({"data": {"users": [{"description": USERS[name].get("desc", ""), "name": name}]},
                              "success": True})
        if method == "create":
            name = json.loads(p["name"])
            if name in USERS:
                return self.send({"error": {"code": 3100}, "success": False})
            USERS[name] = {"password": json.loads(p["password"]), "otp": None, "admin": False,
                           "desc": json.loads(p.get("description", '""')),
                           "otp_setup_required": SETTINGS["otp_enforced"],
                           "must_change": SETTINGS["password_must_change"]}
            return self.send({"data": {"name": name, "uid": 1100}, "success": True})
        if method == "set":
            name = json.loads(p["name"])
            if name not in USERS:
                return self.send({"error": {"code": 3106}, "success": False})
            if "password" in p:
                USERS[name]["password"] = json.loads(p["password"])
                USERS[name]["must_change"] = SETTINGS["password_must_change"]
            return self.send({"data": {"name": name}, "success": True})
        if method == "delete":
            for name in json.loads(p["name"]):
                USERS.pop(name, None)
                for sid in [s for s, a in STATE["sessions"].items() if a == name]:
                    del STATE["sessions"][sid]
            # DSM reports an error for the caller's own session but deletes the user.
            return self.send({"data": {"errors": [3102] if name == user else []}, "success": True})
        return self.send({"error": {"code": 103}, "success": False})


    def task_api(self, user, api, method, p):
        tasks = STATE["tasks"]
        if api == "SYNO.Core.TaskScheduler" and method == "list":
            return self.send({"data": {"tasks": [{k: t[k] for k in ("id", "name", "owner", "real_owner")}
                                                 for t in tasks], "total": len(tasks)}, "success": True})
        if api == "SYNO.Core.TaskScheduler.Root" and method in ("create", "set"):
            # Root tasks need the password confirmation token.
            if json.loads(p.get("SynoConfirmPWToken", '""')) != "pwtok-" + user or p.get("version") != "4":
                return self.send({"error": {"code": 4800}, "success": False})
            task = {"name": json.loads(p["name"]), "owner": json.loads(p["owner"]), "real_owner": "root",
                    "script": json.loads(p["extra"])["script"], "schedule": json.loads(p["schedule"])}
            if method == "set":
                old = [t for t in tasks if t["id"] == int(p["id"])]
                if not old:
                    return self.send({"error": {"code": 4800}, "success": False})
                old[0].update(task)
                return self.send({"success": True})
            task["id"] = max([t["id"] for t in tasks] + [0]) + 1
            tasks.append(task)
            return self.send({"data": {"id": task["id"]}, "success": True})
        if api == "SYNO.Core.TaskScheduler" and method == "run":
            for item in json.loads(p["tasks"]):
                for t in tasks:
                    if t["id"] == item["id"]:
                        env = dict(os.environ, FAKE_SYNO_URL="http://127.0.0.1:%d/_syno" % self.server.server_port)
                        subprocess.Popen(["sh", "-c", t["script"]], env=env,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return self.send({"success": True})
        return self.send({"error": {"code": 103}, "success": False})

    def syno_exec(self):
        """Stand-in for "synowebapi --exec" (root, no session), used by
        tests/fake_synowebapi.py."""
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n))
        api, method, p = req["api"], req["method"], req["params"]
        if api == "SYNO.Core.Certificate.CRT" and method == "list":
            return self.send({"data": {"certificates": STATE["certs"]}, "success": True})
        if api == "SYNO.Core.Certificate" and method == "import":
            files = {k: open(p[k]).read() for k in ("key_tmp", "cert_tmp", "inter_cert_tmp") if k in p}
            cid = p.get("id") or "t%02d" % (len(STATE["certs"]) + 1)
            existing = [c for c in STATE["certs"] if c["id"] == cid]
            if existing:
                existing[0]["desc"] = p.get("desc", "")
            else:
                STATE["certs"].append({"desc": p.get("desc", ""), "id": cid, "is_default": False,
                                       "subject": {"common_name": "imported"}, "services": []})
            STATE["imports"].append({"id": cid, "desc": p.get("desc"), "via": "task",
                                     "has_key": "PRIVATE KEY" in files.get("key_tmp", ""),
                                     "has_cert": "BEGIN CERTIFICATE" in files.get("cert_tmp", ""),
                                     "has_chain": "inter_cert_tmp" in files})
            return self.send({"data": {"id": cid}, "httpd_restart": False, "success": True})
        if api == "SYNO.Core.TaskScheduler" and method == "list":
            return self.send({"data": {"tasks": [{k: t[k] for k in ("id", "name", "owner", "real_owner")}
                                                 for t in STATE["tasks"]]}, "success": True})
        if api == "SYNO.Core.TaskScheduler" and method == "delete":
            ids = [t["id"] for t in p["tasks"]]
            STATE["tasks"] = [t for t in STATE["tasks"] if t["id"] not in ids]
            return self.send({"success": True})
        return self.send({"error": {"code": 103}, "success": False})


if __name__ == "__main__":
    port = int(sys.argv[1])
    lan = ThreadingHTTPServer(("127.0.0.2", port), H)
    threading.Thread(target=lan.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
