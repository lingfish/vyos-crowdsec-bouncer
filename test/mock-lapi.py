#!/usr/bin/env python3
"""Minimal mock of the CrowdSec LAPI /v1/decisions endpoint for testing
vyos-bouncer.sh. Honors the `scope` query param and returns a fixed decision
set. Set MOCK_FAIL=1 to simulate a LAPI outage (HTTP 500)."""
import http.server
import json
import os
import sys
import urllib.parse

FAIL = os.environ.get("MOCK_FAIL", "0") == "1"

DECISIONS = [
    {"scope": "Ip", "value": "203.0.113.7", "simulated": False, "type": "ban"},
    {"scope": "Ip", "value": "203.0.113.8", "simulated": False, "type": "ban"},
    {"scope": "Ip", "value": "2001:db8::1", "simulated": False, "type": "ban"},
    {"scope": "Range", "value": "198.51.100.0/24", "simulated": False, "type": "ban"},
    {"scope": "Range", "value": "2001:db8:abcd::/48", "simulated": False, "type": "ban"},
    {"scope": "Ip", "value": "192.0.2.66", "simulated": True, "type": "ban"},
]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if FAIL:
            body = json.dumps({"message": "unavailable"}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        scope = params.get("scope", [None])[0]
        result = DECISIONS if scope is None else [d for d in DECISIONS if d["scope"] == scope]
        # Mirror real LAPI: Go marshals an empty decision slice as JSON `null`.
        body = json.dumps(result if result else None).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_LAPI_PORT", "8080"))
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print(f"mock lapi listening on 127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)