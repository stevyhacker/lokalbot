#!/usr/bin/env python3
"""Local preview server for web/.

Serves extensionless HTML routes like Vercel's cleanUrls and refuses to let the
browser cache anything. The stock server sends no cache headers at all, which
lets browsers apply heuristic caching and silently serve a stale styles.css
against freshly edited markup — the page then renders with old CSS and looks
broken in ways the source doesn't explain.

Usage: Scripts/serve-web.py [port] [--directory path]   (default 8791, web/)
"""
import argparse
import functools
import http.server
import pathlib
import sys

parser = argparse.ArgumentParser(description="Preview the static site without caching.")
parser.add_argument("port", nargs="?", type=int, default=8791)
parser.add_argument("--directory", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / "web")
args = parser.parse_args()
PORT = args.port
ROOT = args.directory.resolve()


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        resolved = pathlib.Path(super().translate_path(path))
        # Match Vercel's cleanUrls behavior for guides and legal pages.
        if not resolved.exists() and not resolved.suffix:
            clean_page = resolved.with_suffix(".html")
            if clean_page.is_file():
                return str(clean_page)
        return str(resolved)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    handler = functools.partial(NoCacheHandler, directory=str(ROOT))
    with Server(("127.0.0.1", PORT), handler) as httpd:
        print(f"serving {ROOT} at http://localhost:{PORT} (no-store)")
        httpd.serve_forever()
