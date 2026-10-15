# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
"""Stand-in for a model API, used by run_gateway_tests.sh.

Every request is appended to the log file given on the command line as one
JSON line (method, path, headers, body) so the test can check exactly what
the gateway sent upstream. /stream answers with server-sent events, sent in
separate writes with pauses, to prove the gateway streams instead of buffering.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": "POST", "path": self.path,
                                "headers": {k.lower(): v for k, v in self.headers.items()},
                                "body": body}) + "\n")
        if self.path.endswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                data = f"event: tick\ndata: {{\"n\": {i}}}\n\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()
                time.sleep(0.3)
            self.wfile.write(b"0\r\n\r\n")
            return
        out = json.dumps({"ok": True, "echo_path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.send_header("X-Upstream", "fake")
        self.end_headers()
        self.wfile.write(out)

    do_PUT = do_POST


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
