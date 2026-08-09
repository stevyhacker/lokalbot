#!/usr/bin/env python3
"""Local preview server for web/.

Identical to `python3 -m http.server` except that it refuses to let the
browser cache anything. The stock server sends no cache headers at all, which
lets browsers apply heuristic caching and silently serve a stale styles.css
against freshly edited markup — the page then renders with old CSS and looks
broken in ways the source doesn't explain.

Usage: Scripts/serve-web.py [port]   (default 8791)
"""
import functools
import http.server
import pathlib
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
ROOT = pathlib.Path(__file__).resolve().parent.parent / "web"


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


class Server(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    handler = functools.partial(NoCacheHandler, directory=str(ROOT))
    with Server(("127.0.0.1", PORT), handler) as httpd:
        print(f"serving {ROOT} at http://localhost:{PORT} (no-store)")
        httpd.serve_forever()
