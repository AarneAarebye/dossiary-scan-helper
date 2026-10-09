"""HTTP side of the reference helper: routes, origin check, pairing, one scan at a time."""

import base64
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from . import __version__
from .fakes import FAKE_SCANNERS, ScanError, simulate, validate
from .pairing import bearer_token, pair, token_valid, validate_pair_body
from .pdf import make_pdf

HELPER_NAME = "dossiary-scan-helper-reference"
_scan_lock = threading.Lock()


_ALLOWED_ORIGIN = re.compile(r"http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?")
MAX_BODY = 1_000_000

# Each endpoint and the one method it takes (besides OPTIONS).
ENDPOINTS = {"/health": "GET", "/scanners": "GET", "/scan": "POST", "/pair": "POST"}
NEEDS_TOKEN = ("/scanners", "/scan")


def origin_allowed(origin):
    """No Origin, "null", or plain-http localhost / 127.0.0.1 on a port from 1 to 65535."""
    if origin is None or origin == "null":
        return True
    match = _ALLOWED_ORIGIN.fullmatch(origin)
    return match is not None and (match.group(2) is None or 1 <= int(match.group(2)[1:]) <= 65535)


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

    def _send_json(self, status, payload, cors=True, extra_headers=()):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers:
            self.send_header(name, value)
        if cors:
            self._cors_headers()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _paired(self):
        return token_valid(bearer_token(self.headers.get("Authorization")))

    def _read_json_body(self):
        """The parsed JSON body; raises ScanError(400) for a bad length or bad JSON."""
        length = self.headers.get("Content-Length")
        if length is None:
            raw = b""
        else:
            if not re.fullmatch(r"[0-9]+", length.strip()):
                raise ScanError(400, "The request has an invalid Content-Length.")
            if int(length) > MAX_BODY:
                raise ScanError(400, "The request body is too large.")
            raw = self.rfile.read(int(length)) if int(length) else b""
        try:
            return json.loads(raw.decode("utf-8") or "null")
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise ScanError(400, "The request body isn't valid JSON.") from None

    # --- methods ------------------------------------------------------------

    def do_OPTIONS(self):
        if not self._origin_ok():
            return
        self.send_response(204)
        self._cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Access-Control-Max-Age", "600")
        if self.headers.get("Access-Control-Request-Private-Network") == "true":
            self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _dispatch(self):
        # Order: origin (403), endpoint (404), method (405), token (401), then the endpoint itself.
        if not self._origin_ok():
            return
        path = urlsplit(self.path).path
        method = ENDPOINTS.get(path)
        if method is None:
            self._send_json(404, _error_body("Unknown endpoint."))
            return
        if self.command != method:
            self._send_json(405, _error_body(f"Use {method} for this endpoint."),
                            extra_headers=[("Allow", f"{method}, OPTIONS")])
            return
        if path in NEEDS_TOKEN and not self._paired():
            self._send_json(401, _error_body(
                "This browser isn't paired with the scan helper. Pair it in Dossiary's scanner settings."))
            return
        try:
            if path == "/health":
                self._send_json(200, {"ok": True, "helper": HELPER_NAME, "version": __version__,
                                      "protocol": 2, "paired": self._paired()})
            elif path == "/scanners":
                self._send_json(200, {"scanners": [s.describe() for s in FAKE_SCANNERS]})
            elif path == "/pair":
                token = pair(validate_pair_body(self._read_json_body()))
                self._send_json(200, {"ok": True, "token": token})
            else:
                self._scan()
        except ScanError as err:
            self._send_json(err.status, _error_body(err.message))

    def _scan(self):
        scanner, settings = validate(self._read_json_body())
        if not _scan_lock.acquire(blocking=False):
            raise ScanError(409, "Another scan is still running. Try again when it has finished.")
        try:
            documents, partial, message = simulate(scanner, settings)
        finally:
            _scan_lock.release()
        stamp = time.strftime("%Y%m%d_%H%M%S")
        files = []
        for index, pages in enumerate(documents, start=1):
            name = f"scan_{stamp}.pdf" if len(documents) == 1 else f"scan_{stamp}_{index}.pdf"
            files.append({"name": name, "pages": len(pages),
                          "data": base64.b64encode(make_pdf(pages)).decode("ascii")})
        self._send_json(200, {"ok": not partial, "partial": partial, "message": message, "files": files})

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _dispatch


def make_server(host, port):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server
