"""HTTP side of the reference helper: routes, origin check, one scan at a time."""

import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import __version__
from .fakes import FAKE_SCANNERS, ScanError, simulate, validate
from .pdf import make_pdf

HELPER_NAME = "dossiary-scan-helper-reference"
_scan_lock = threading.Lock()


def origin_allowed(origin):
    """No Origin, "null", or plain-http localhost / 127.0.0.1 on any port."""
    if origin is None or origin == "null":
        return True
    parts = urlsplit(origin)
    return parts.scheme == "http" and parts.hostname in ("localhost", "127.0.0.1") and not parts.path.strip("/")


def _error_body(message):
    return {"ok": False, "partial": False, "message": message}


class Handler(BaseHTTPRequestHandler):
    server_version = "scanbridge-ref/" + __version__

    def log_message(self, fmt, *args):  # quiet by default; errors still reach stderr
        pass

    # --- plumbing -----------------------------------------------------------

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        if origin_allowed(origin):
            return True
        self._send_json(403, _error_body("This origin may not use the scan helper."), cors=False)
        return False

    def _cors_headers(self):
        origin = self.headers.get("Origin")
        if origin is not None:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def _send_json(self, status, payload, cors=True):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if cors:
            self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    # --- methods ------------------------------------------------------------

    def do_OPTIONS(self):
        if not self._origin_ok():
            return
        self.send_response(204)
        self._cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        if self.headers.get("Access-Control-Request-Private-Network") == "true":
            self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self._origin_ok():
            return
        path = urlsplit(self.path).path
        if path == "/health":
            self._send_json(200, {"ok": True, "helper": HELPER_NAME, "version": __version__, "protocol": 2})
        elif path == "/scanners":
            self._send_json(200, {"scanners": [s.describe() for s in FAKE_SCANNERS]})
        elif path == "/scan":
            self._send_json(405, _error_body("Use POST to start a scan."))
        else:
            self._send_json(404, _error_body("Unknown endpoint."))

    def do_POST(self):
        if not self._origin_ok():
            return
        path = urlsplit(self.path).path
        if path in ("/health", "/scanners"):
            self._send_json(405, _error_body("Use GET for this endpoint."))
            return
        if path != "/scan":
            self._send_json(404, _error_body("Unknown endpoint."))
            return
        try:
            body = json.loads(self._read_body().decode("utf-8") or "null")
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, _error_body("The request body isn't valid JSON."))
            return
        try:
            scanner, settings = validate(body)
            if not _scan_lock.acquire(blocking=False):
                raise ScanError(409, "Another scan is still running. Try again when it has finished.")
            try:
                documents, partial, message = simulate(scanner, settings)
            finally:
                _scan_lock.release()
        except ScanError as err:
            self._send_json(err.status, _error_body(err.message))
            return
        stamp = time.strftime("%Y%m%d_%H%M%S")
        files = []
        for index, pages in enumerate(documents, start=1):
            name = f"scan_{stamp}.pdf" if len(documents) == 1 else f"scan_{stamp}_{index}.pdf"
            files.append({"name": name, "pages": len(pages),
                          "data": base64.b64encode(make_pdf(pages)).decode("ascii")})
        self._send_json(200, {"ok": not partial, "partial": partial, "message": message, "files": files})


def make_server(host, port):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server
