"""A tiny HTTP client for the conformance suite (standard library only)."""

import json
import os
import urllib.error
import urllib.request

BASE_URL = os.environ.get("SCAN_HELPER_URL", "http://127.0.0.1:8766").rstrip("/")


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body.decode("utf-8"))


def request(method, path, body=None, headers=None, raw_body=None, timeout=60):
    """Send a request; return a Response for every status (no exception on 4xx/5xx)."""
    data = raw_body
    all_headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        all_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(BASE_URL + path, data=data, headers=all_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return Response(resp.status, resp.headers, resp.read())
    except urllib.error.HTTPError as err:
        return Response(err.code, err.headers, err.read())
