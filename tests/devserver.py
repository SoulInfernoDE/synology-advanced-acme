#!/usr/bin/env python3
"""Development server for the web UI: serves the built ui/ folder and runs
api.cgi like DSM does. Authentication is replaced by tests/fake_authenticate.cgi
through the AACME_* environment set up by tests/dev-env.sh. Not for production."""
import os
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UI = os.environ["AACME_TARGET"] + "/ui"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=UI, **kw)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        if self.path.split("?")[0] != "/api.cgi":
            self.send_error(404)
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        env = dict(os.environ)
        env.update({
            "REQUEST_METHOD": "POST",
            "CONTENT_LENGTH": str(n),
            "HTTP_X_AACME": self.headers.get("X-AACME", ""),
            "HTTP_X_SYNO_TOKEN": self.headers.get("X-SYNO-TOKEN", ""),
            "QUERY_STRING": "",
        })
        out = subprocess.run([UI + "/api.cgi"], input=body, env=env, capture_output=True).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.decode().split("\r\n"):
            k, _, v = line.partition(":")
            if k.lower() == "status":
                status = int(v.strip().split()[0])
            elif k:
                headers.append((k, v.strip()))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
