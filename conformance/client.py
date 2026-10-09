"""A tiny HTTP client for the conformance suite (standard library only)."""

import http.client
import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlsplit

BASE_URL = os.environ.get("SCAN_HELPER_URL", "http://127.0.0.1:8766").rstrip("/")

# Set by the suite's setUpModule after pairing with the fake-mode code.
TOKEN = None
USE_TOKEN = object()  # default for `auth`: send "Bearer <TOKEN>" once paired


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body.decode("utf-8"))


def _auth_value(auth):
    if auth is USE_TOKEN:
        return f"Bearer {TOKEN}" if TOKEN else None
    return auth


def request(method, path, body=None, headers=None, raw_body=None, timeout=60, auth=USE_TOKEN):
    """Send a request; return a Response for every status (no exception on 4xx/5xx).

    `auth` is the Authorization header: by default "Bearer <TOKEN>", None for no header,
    or any string to send as is.
    """
    data = raw_body
    all_headers = dict(headers or {})
    auth_value = _auth_value(auth)
    if auth_value is not None:
        all_headers.setdefault("Authorization", auth_value)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        all_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(BASE_URL + path, data=data, headers=all_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return Response(resp.status, resp.headers, resp.read())
    except urllib.error.HTTPError as err:
        with err:
            return Response(err.code, err.headers, err.read())


def raw_request(method, path, header_lines, body=b"", timeout=60, auth=USE_TOKEN):
    """Send exactly the given header lines (plus Host, Connection and Authorization).

    urllib always adds Content-Type and computes Content-Length itself; this sends
    requests it can't, such as `Content-Length: abc` or a POST without Content-Type.
    """
    url = urlsplit(BASE_URL)
    lines = [f"{method} {path} HTTP/1.1", f"Host: {url.netloc}", "Connection: close"]
    auth_value = _auth_value(auth)
    if auth_value is not None:
        lines.append(f"Authorization: {auth_value}")
    lines.extend(header_lines)
    payload = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body
    conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=timeout)
    try:
        conn.connect()
        conn.sock.sendall(payload)
        resp = http.client.HTTPResponse(conn.sock, method=method)
        resp.begin()
        return Response(resp.status, resp.headers, resp.read())
    finally:
        conn.close()
