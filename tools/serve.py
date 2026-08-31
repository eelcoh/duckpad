"""Static server for development.

The only reason this exists instead of `python -m http.server` is caching.
The default server sends Last-Modified and nothing else, so a browser is free
to reuse a stale elm.js after a rebuild — which looks exactly like the new
code not working, and costs more time to diagnose than it ever saves.
"""

import functools
import http.server
import sys


class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Vendored libraries are exempt: they only change when `mise run
        # vendor` runs, and re-fetching 38 MB of WebAssembly on every reload
        # would make the thing this server exists to speed up slower.
        if self.path.startswith("/vendor/"):
            self.send_header("Cache-Control", "public, max-age=3600")
        else:
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # One line per request is noise; only report what failed.
        if not args or not str(args[1]).startswith("2"):
            super().log_message(fmt, *args)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    directory = sys.argv[2] if len(sys.argv) > 2 else "public"
    handler = functools.partial(NoCache, directory=directory)
    print(f"serving {directory} on http://localhost:{port} (caching disabled)")
    http.server.ThreadingHTTPServer(("", port), handler).serve_forever()
