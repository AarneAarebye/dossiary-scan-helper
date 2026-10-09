"""Browser pairing for the reference helper (fake mode: the code is always 000000)."""

import secrets
import threading

from .fakes import ScanError

FAKE_PAIRING_CODE = "000000"
MAX_CLIENT_LENGTH = 200
REFUSED_MESSAGE = ("That pairing code isn't valid. In the scan helper, choose “Pair a browser…” "
                   "and enter the new code.")

_tokens = set()
_tokens_lock = threading.Lock()


def validate_pair_body(body):
    """Return the code from a POST /pair body, or raise ScanError(400)."""
    if not isinstance(body, dict):
        raise ScanError(400, "The request body must be a JSON object.")
    code = body.get("code")
    if not isinstance(code, str):
        raise ScanError(400, "The request needs a pairing code.")
    client = body.get("client")
    if "client" in body and not isinstance(client, str):
        raise ScanError(400, "“client” must be a string.")
    if isinstance(client, str) and len(client) > MAX_CLIENT_LENGTH:
        raise ScanError(400, f"“client” may have at most {MAX_CLIENT_LENGTH} characters.")
    return code


def pair(code):
    """Issue a new token for the right code; raise ScanError(403) otherwise."""
    if code != FAKE_PAIRING_CODE:
        raise ScanError(403, REFUSED_MESSAGE)
    token = secrets.token_urlsafe(24)
    with _tokens_lock:
        _tokens.add(token)
    return token


def bearer_token(header):
    """The token from an "Authorization: Bearer <token>" value, or None."""
    if header is None or not header.startswith("Bearer "):
        return None
    return header[len("Bearer "):] or None


def token_valid(token):
    if token is None:
        return False
    with _tokens_lock:
        return token in _tokens
