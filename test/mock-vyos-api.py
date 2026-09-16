#!/usr/bin/env python3
"""Minimal mock of the VyOS HTTPS API for testing vyos-bouncer.sh.

Listens on plain HTTP (the script's curl handles both) and appends each
/configure request to MOCK_LOG as a JSON line: {"path","data","key"}.
"""
import http.server
import json
import os
import sys
import urllib.parse

LOG = os.environ.get("MOCK_LOG", "/tmp/mock-vyos-api.log")
HOST = os.environ.get("MOCK_HOST", "127.0.0.1")
PORT = int(os.environ.get("MOCK_PORT", "8443"))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        fields = urllib.parse.parse_qs(body)
        entry = {
            "path": self.path,
            "data": fields.get("data", [None])[0],
            "key": fields.get("key", [None])[0],
        }
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
        resp = json.dumps({"success": True, "data": None, "error": None}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = http.server.HTTPServer((HOST, PORT), Handler)
    print(f"mock vyos api listening on {HOST}:{PORT}, logging to {LOG}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)