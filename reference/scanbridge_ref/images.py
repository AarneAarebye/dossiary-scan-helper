"""Tiny valid images for the fake photo scanner. Standard library only."""

import base64
import struct
import zlib

EXTENSIONS = {"jpeg": "jpg", "png": "png"}

# An 8 x 8 gray baseline JPEG (332 bytes), made once with Pillow and checked to decode.
_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEBLAEsAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL"
    "/wAALCAAIAAgBAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBka"
    "EII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/APSK/9k="
)


def make_jpeg() -> bytes:
    return _JPEG


def _chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def make_png(size: int = 8, gray: int = 200) -> bytes:
    """A size x size 8-bit gray PNG."""
    rows = b"".join(b"\x00" + bytes([gray]) * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(rows))
            + _chunk(b"IEND", b""))


def make_image(fmt: str) -> bytes:
    if fmt == "jpeg":
        return make_jpeg()
    if fmt == "png":
        return make_png()
    raise ValueError(f"unknown image format: {fmt!r}")
