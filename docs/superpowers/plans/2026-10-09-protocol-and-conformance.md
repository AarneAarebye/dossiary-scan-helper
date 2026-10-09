# Protocol and Conformance Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `dossiary-scan-helper` repo's foundation: the written bridge protocol v2, a Python conformance suite that checks any helper over HTTP, and a stdlib-only Python reference helper with fake scanners that passes it.

**Architecture:** `PROTOCOL.md` is the single source of truth. `reference/scanbridge_ref/` is a tiny `http.server` app whose fake scanners follow the protocol's "fake scanner mode" exactly, so the same conformance suite (`conformance/`, stdlib `unittest` + `urllib`) can later run unchanged against the macOS and Windows helpers in their `--fake-scanners` mode. GitHub Actions runs the unit tests and the suite against the reference helper.

**Tech Stack:** Python 3.11+ standard library only (`http.server`, `urllib`, `unittest`, `json`, `threading`). GitHub Actions.

**Design spec:** `~/Projects/Paperless/Dossiary/docs/superpowers/specs/2026-10-09-system-scanner-helper-design.md`, section 1 (protocol) and section 3 (repo layout, testing).

## Global Constraints

- Python 3.11 or newer, standard library only — no `pip install` anywhere in `reference/` or `conformance/`.
- The reference helper listens on `127.0.0.1`, default port `8766`.
- Protocol field names are exactly: `ok`, `helper`, `version`, `protocol`, `scanners`, `id`, `name`, `sources`, `duplex`, `colorModes`, `resolutions`, `extras`, `scanner`, `source`, `colorMode`, `resolution`, `format`, `partial`, `message`, `files`, `pages`, `data`.
- Known extras are exactly `splitOnBlank` and `skipBlankPages`.
- Error status codes: 400 malformed request, 403 origin not allowed, 404 unknown scanner or endpoint, 405 wrong method, 409 busy, 422 unsupported setting, 503 scanner offline or access denied. Every error body is `{"ok": false, "partial": false, "message": "<non-empty>"}`.
- CORS allows only: no `Origin` header, `Origin: null`, and `http://localhost:<port>` / `http://127.0.0.1:<port>` (any port, or none). Anything else gets 403.
- License MIT, copyright "2026 Aarne Aarebye".
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo
  ```

## File Structure

```
dossiary-scan-helper/
├── README.md                         what this is, how to run the reference helper and the suite
├── LICENSE                           MIT
├── .gitignore
├── PROTOCOL.md                       the bridge protocol v2 (normative)
├── reference/
│   ├── scanbridge_ref/
│   │   ├── __init__.py               __version__
│   │   ├── __main__.py               CLI: python -m scanbridge_ref --port 8766
│   │   ├── pdf.py                    make_pdf(page_texts) -> bytes
│   │   ├── fakes.py                  fake scanners, request validation, scan simulation
│   │   └── server.py                 HTTP routes, CORS, busy lock
│   └── tests/
│       ├── test_pdf.py
│       └── test_fakes.py
├── conformance/
│   ├── client.py                     tiny HTTP client for the suite
│   └── test_conformance.py           the suite (env SCAN_HELPER_URL)
└── .github/workflows/conformance.yml
```

The repo folder already exists with `git init` done and this plan in it (`docs/superpowers/plans/`).

---

### Task 1: Repo basics and PROTOCOL.md

**Files:**
- Create: `README.md`, `LICENSE`, `.gitignore`, `PROTOCOL.md`

**Interfaces:**
- Produces: the normative protocol text every later task implements and tests — especially the "Fake scanner mode" table and the "Request validation" order.

- [ ] **Step 1: Write `LICENSE`**

```
MIT License

Copyright (c) 2026 Aarne Aarebye

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write `.gitignore`**

```
__pycache__/
*.pyc
.DS_Store
*.log
```

- [ ] **Step 3: Write `PROTOCOL.md`**

````markdown
# Dossiary scan bridge protocol, version 2

A scan helper is a small app on the person's computer that drives a
scanner and answers HTTP requests from [Dossiary](https://github.com/AarneAarebye/Dossiary),
a browser app that can't reach scanners itself. This document is the
contract every helper implements: the macOS and Windows helpers in this
repo, the reference helper, and [scanix500](https://github.com/AarneAarebye/iX500).

All bodies are JSON (`Content-Type: application/json; charset=utf-8`).

## Listening

- Bind to `127.0.0.1` only, never to all interfaces.
- Default ports: `8766` for dossiary-scan-helper, `8765` for scanix500.

## `GET /health`

```json
{ "ok": true, "helper": "dossiary-scan-helper-macos", "version": "1.0.0", "protocol": 2 }
```

`helper` names the implementation, `version` is its own version, and
`protocol` is `2`. A response without `protocol` comes from a version 1
helper (see the end of this document).

## `GET /scanners`

```json
{ "scanners": [
  { "id": "ic:HP-ENVY-6000", "name": "HP ENVY 6000 (network)",
    "sources": ["flatbed", "feeder"], "duplex": true,
    "colorModes": ["color", "gray", "bw"], "resolutions": [150, 200, 300, 600],
    "extras": [] } ] }
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Stable for this scanner and helper across restarts. |
| `name` | string | For display. |
| `sources` | array of `"flatbed"` / `"feeder"` | At least one. The first is the default. |
| `duplex` | boolean | The feeder can scan both sides. |
| `colorModes` | array of `"color"` / `"gray"` / `"bw"` | At least one. The first is the default. |
| `resolutions` | array of integers (dpi), ascending | At least one. The first is the default. |
| `extras` | array of strings | Extra abilities, see below. |

An empty `scanners` array is a valid answer: the helper runs, but found
no scanner.

### Extras

| Extra | Meaning |
|---|---|
| `splitOnBlank` | A blank page separates documents. The result has one PDF per document; the blank pages are dropped. |
| `skipBlankPages` | Blank pages are dropped from the result. |

Clients ignore extras they don't know.

## `POST /scan`

```json
{ "scanner": "ic:HP-ENVY-6000", "source": "feeder", "duplex": true,
  "colorMode": "color", "resolution": 300, "format": "pdf",
  "extras": { "splitOnBlank": false } }
```

Only `scanner` is required. Missing fields use the scanner's defaults:
the first `source`, `colorMode` and `resolution`, `duplex` false,
`format` `"pdf"`, every extra off.

The request blocks until the scan has finished. Clients must not set a
timeout: a large feeder batch can take minutes.

### Request validation

A helper checks in this order and answers with the first failure:

1. The body is not a JSON object → **400**.
2. `scanner` is missing or not a string → **400**.
3. `scanner` is not a known id → **404**.
4. A field has the wrong JSON type (`source`, `colorMode`, `format` not
   strings; `resolution` not an integer; `duplex` not a boolean; `extras`
   not an object whose values are all booleans) → **400**.
5. A value the scanner doesn't offer → **422**: `source` not in
   `sources`; `colorMode` not in `colorModes`; `resolution` not in
   `resolutions`; `format` other than `"pdf"`; `duplex: true` when the
   scanner has `duplex: false` or the source isn't `"feeder"`; an extra
   set to `true` that isn't in the scanner's `extras`. (An unknown extra
   set to `false` is accepted.)
6. Another scan is running on this helper → **409**.
7. The scanner can't be reached, or the system denied access → **503**.

### Response

```json
{ "ok": true, "partial": false, "message": "3 pages scanned.",
  "files": [ { "name": "scan_20261009_143200.pdf", "pages": 3, "data": "<base64>" } ] }
```

- `files`: one PDF with every page; with `splitOnBlank`, one PDF per
  document, in scan order.
- `pages`: the number of pages in that PDF.
- `data`: the PDF, base64-encoded (standard alphabet, with padding).
- `name`: ends in `.pdf`; names in one response are unique.
- `partial: true` (with `ok: false`) means something went wrong but
  usable pages came back, for example a paper jam after the second
  sheet. `files` then holds those pages and `message` says what happened.

## Errors

| Code | Meaning |
|---|---|
| 400 | malformed request |
| 403 | origin not allowed |
| 404 | unknown scanner, or unknown endpoint |
| 405 | wrong method for the endpoint |
| 409 | a scan is already running |
| 422 | a setting the scanner doesn't offer |
| 503 | scanner offline, or the system denied access |

Every error body is `{"ok": false, "partial": false, "message": "..."}`
with a non-empty message written for a person: Dossiary shows it on its
status line.

## Origins (CORS)

Dossiary runs from a `file://` page (origin `null`) or from a localhost
web server. A helper must not let other websites drive the scanner:

- A request with no `Origin` header is allowed (curl, the conformance
  suite).
- `Origin: null` is allowed.
- `http://localhost` and `http://127.0.0.1`, with or without a port, are
  allowed.
- Any other `Origin` gets **403** for every method, preflight included.

For an allowed `Origin`, every response carries
`Access-Control-Allow-Origin: <that origin>` and `Vary: Origin`.

`OPTIONS` (preflight) on any endpoint answers **204** with
`Access-Control-Allow-Methods: GET, POST, OPTIONS`,
`Access-Control-Allow-Headers: Content-Type` and
`Access-Control-Max-Age: 600`. If the request has
`Access-Control-Request-Private-Network: true`, the answer also carries
`Access-Control-Allow-Private-Network: true`.

## Fake scanner mode

Every helper has a fake scanner mode (`--fake-scanners` for the native
helpers; the reference helper has nothing else). It replaces the real
scanners with exactly these six, so one conformance suite can test every
helper without hardware. Pages carry the text shown; `""` is a blank page.

| id | name | sources | duplex | colorModes | resolutions | extras |
|---|---|---|---|---|---|---|
| `fake:flatbed` | Fake Flatbed | flatbed | false | color, gray, bw | 150, 300, 600 | — |
| `fake:feeder` | Fake Feeder | feeder, flatbed | true | color, gray, bw | 150, 300, 600 | — |
| `fake:splitter` | Fake Splitter | feeder | false | color, gray, bw | 150, 300, 600 | splitOnBlank, skipBlankPages |
| `fake:jam` | Fake Jamming Feeder | feeder | false | color, gray, bw | 150, 300, 600 | — |
| `fake:slow` | Fake Slow Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |
| `fake:offline` | Fake Offline Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |

What a scan returns:

- **Flatbed source** (any scanner): one page, `Flatbed page 1`.
- **`fake:feeder`, feeder source**: three sheets, `Sheet 1`, `Sheet 2`,
  `Sheet 3`. With `duplex`, each front is followed by its back
  (`Sheet 1 back`, …): six pages.
- **`fake:splitter`**: four sheets, `Doc A page 1`, `Doc A page 2`, `""`,
  `Doc B page 1`.
  - No extras: one PDF, 4 pages.
  - `skipBlankPages`: one PDF, 3 pages.
  - `splitOnBlank` (with or without `skipBlankPages`): two PDFs, 2 and 1
    pages.
- **`fake:jam`**: three sheets, but jams after the second: `ok: false`,
  `partial: true`, one PDF with 2 pages, and a message mentioning the jam.
- **`fake:slow`**: like a flatbed scan, but takes 2 seconds, so a second
  request can arrive while it runs (→ 409).
- **`fake:offline`**: every valid scan request answers **503**.

The `message` of a successful scan is `"<n> pages scanned."` (`"1 page
scanned."` for one page), where `n` counts all pages in all files.

## Version 1 (scanix500 before protocol 2)

Version 1 has `GET /health` without `protocol`, and a scan request with
query parameters `skip_blank_filter`, `skip_ocr` and `split_on_blank`
(`true`/`false`). It answers with the same response shape, without
`pages`. Dossiary keeps speaking version 1 to helpers that don't report
`protocol: 2`; new helpers implement version 2 only.
````

- [ ] **Step 4: Write `README.md`**

````markdown
# dossiary-scan-helper

Lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any
scanner your Mac or Windows PC already supports. Dossiary runs in the
browser, which can't reach a scanner, so this small helper does the
scanning and hands the result to Dossiary over a local connection.

> **Status:** early development. This repo currently holds the protocol,
> the conformance test suite and a reference helper with fake scanners.
> The macOS and Windows helpers come next.

## What's here

| Path | What it is |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | The bridge protocol every helper implements. |
| `reference/` | A minimal Python helper with fake scanners, for developing Dossiary and testing the suite. Standard library only. |
| `conformance/` | Tests any running helper over HTTP against `PROTOCOL.md`. |

## Run the reference helper

Needs Python 3.11 or newer, nothing else:

    cd reference
    python3 -m scanbridge_ref --port 8766

It listens on `127.0.0.1:8766` and offers six fake scanners (see
"Fake scanner mode" in `PROTOCOL.md`).

## Run the conformance suite

With a helper running (the reference helper, or a native helper started
with `--fake-scanners`):

    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v

The reference helper's own unit tests:

    cd reference && python3 -m unittest discover -s tests -v

## License

MIT
````

- [ ] **Step 5: Check the protocol's examples are valid JSON**

Run:
```bash
cd ~/Projects/Paperless/dossiary-scan-helper && python3 - <<'EOF'
import json, re
text = open('PROTOCOL.md').read()
blocks = re.findall(r"```json\n(.*?)```", text, re.S)
for b in blocks:
    json.loads(b)
print(len(blocks), "JSON examples parse")
EOF
```
Expected: `4 JSON examples parse` (health, scanners, scan request, scan response).

- [ ] **Step 6: Commit**

```bash
git add LICENSE .gitignore PROTOCOL.md README.md docs/superpowers/plans/2026-10-09-protocol-and-conformance.md
git commit -m "Protocol v2 document, README, license

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo"
```

---

### Task 2: Reference helper core — PDF writer and fake scanners

**Files:**
- Create: `reference/scanbridge_ref/__init__.py`, `reference/scanbridge_ref/pdf.py`, `reference/scanbridge_ref/fakes.py`
- Test: `reference/tests/test_pdf.py`, `reference/tests/test_fakes.py`

**Interfaces:**
- Produces:
  - `scanbridge_ref.__version__: str` = `"0.1.0"`
  - `pdf.make_pdf(page_texts: list[str]) -> bytes` — a valid PDF, one A4 page per text (`""` = blank page); raises `ValueError` for an empty list.
  - `fakes.ScanError(Exception)` with attributes `status: int`, `message: str`.
  - `fakes.FakeScanner` (frozen dataclass) with `id`, `name`, `sources`, `duplex`, `color_modes`, `resolutions`, `extras` (tuples), `sheets: tuple[str, ...]`, `delay: float`, `offline: bool`, `jam_after: int | None`, and `describe() -> dict` (the `/scanners` entry, protocol field names).
  - `fakes.FAKE_SCANNERS: tuple[FakeScanner, ...]` — the six scanners, in the protocol's table order.
  - `fakes.validate(body: object) -> tuple[FakeScanner, dict]` — runs protocol validation steps 1–5; returns the scanner and normalized settings `{"source", "duplex", "colorMode", "resolution", "format", "extras": {name: bool}}`; raises `ScanError(400|404|422, message)`.
  - `fakes.simulate(scanner: FakeScanner, settings: dict) -> tuple[list[list[str]], bool, str]` — returns `(documents, partial, message)` where each document is a list of page texts; raises `ScanError(503, ...)` for an offline scanner; sleeps `scanner.delay`.

- [ ] **Step 1: Write the failing tests**

`reference/tests/test_pdf.py`:
```python
import re
import unittest

from scanbridge_ref.pdf import make_pdf


class MakePdfTests(unittest.TestCase):
    def test_header_and_trailer(self):
        pdf = make_pdf(["Hello"])
        self.assertTrue(pdf.startswith(b"%PDF-1.4\n"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))

    def test_one_page_object_per_text(self):
        pdf = make_pdf(["One", "Two", ""])
        pages = re.findall(rb"/Type /Page(?!s)", pdf)
        self.assertEqual(len(pages), 3)
        self.assertIn(b"/Count 3", pdf)

    def test_text_is_in_the_content(self):
        pdf = make_pdf(["Sheet 1 (front)"])
        self.assertIn(rb"(Sheet 1 \(front\)) Tj", pdf)

    def test_xref_offsets_point_at_objects(self):
        pdf = make_pdf(["A", "B"])
        startxref = int(re.search(rb"startxref\n(\d+)", pdf).group(1))
        self.assertTrue(pdf[startxref:].startswith(b"xref\n"))
        offsets = [int(m) for m in re.findall(rb"^(\d{10}) 00000 n $", pdf, re.M)]
        for number, offset in enumerate(offsets, start=1):
            self.assertTrue(pdf[offset:].startswith(f"{number} 0 obj\n".encode()), number)

    def test_empty_list_is_refused(self):
        with self.assertRaises(ValueError):
            make_pdf([])


if __name__ == "__main__":
    unittest.main()
```

`reference/tests/test_fakes.py`:
```python
import time
import unittest

from scanbridge_ref import fakes
from scanbridge_ref.fakes import FAKE_SCANNERS, ScanError, simulate, validate


def by_id(scanner_id):
    return next(s for s in FAKE_SCANNERS if s.id == scanner_id)


class DescribeTests(unittest.TestCase):
    def test_six_scanners_in_protocol_order(self):
        self.assertEqual([s.id for s in FAKE_SCANNERS],
                         ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam", "fake:slow", "fake:offline"])

    def test_describe_uses_protocol_field_names(self):
        self.assertEqual(by_id("fake:splitter").describe(), {
            "id": "fake:splitter", "name": "Fake Splitter", "sources": ["feeder"], "duplex": False,
            "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600],
            "extras": ["splitOnBlank", "skipBlankPages"],
        })
        self.assertEqual(by_id("fake:feeder").describe()["sources"], ["feeder", "flatbed"])
        self.assertTrue(by_id("fake:feeder").describe()["duplex"])


class ValidateTests(unittest.TestCase):
    def assertStatus(self, body, status):
        with self.assertRaises(ScanError) as ctx:
            validate(body)
        self.assertEqual(ctx.exception.status, status)
        self.assertTrue(ctx.exception.message)

    def test_defaults(self):
        scanner, settings = validate({"scanner": "fake:feeder"})
        self.assertEqual(scanner.id, "fake:feeder")
        self.assertEqual(settings, {"source": "feeder", "duplex": False, "colorMode": "color",
                                    "resolution": 150, "format": "pdf", "extras": {}})

    def test_400s(self):
        self.assertStatus([1, 2], 400)
        self.assertStatus({}, 400)
        self.assertStatus({"scanner": 5}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": "300"}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": True}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "duplex": "yes"}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "source": 1}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "extras": []}, 400)
        self.assertStatus({"scanner": "fake:splitter", "extras": {"splitOnBlank": "yes"}}, 400)

    def test_404_unknown_scanner(self):
        self.assertStatus({"scanner": "fake:nope"}, 404)

    def test_422s(self):
        self.assertStatus({"scanner": "fake:flatbed", "source": "feeder"}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "colorMode": "sepia"}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": 1200}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "format": "tiff"}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "duplex": True}, 422)
        self.assertStatus({"scanner": "fake:feeder", "source": "flatbed", "duplex": True}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "extras": {"splitOnBlank": True}}, 422)

    def test_unknown_extra_set_false_is_accepted(self):
        _, settings = validate({"scanner": "fake:flatbed", "extras": {"splitOnBlank": False}})
        self.assertEqual(settings["extras"], {"splitOnBlank": False})

    def test_400_comes_before_404(self):
        # Order matters: a missing scanner is 400 even if other fields are odd.
        self.assertStatus({"resolution": "x"}, 400)


class SimulateTests(unittest.TestCase):
    def run_scan(self, body):
        scanner, settings = validate(body)
        return simulate(scanner, settings)

    def test_flatbed(self):
        docs, partial, message = self.run_scan({"scanner": "fake:flatbed"})
        self.assertEqual(docs, [["Flatbed page 1"]])
        self.assertFalse(partial)
        self.assertEqual(message, "1 page scanned.")

    def test_feeder_simplex_and_duplex(self):
        docs, _, message = self.run_scan({"scanner": "fake:feeder"})
        self.assertEqual(docs, [["Sheet 1", "Sheet 2", "Sheet 3"]])
        self.assertEqual(message, "3 pages scanned.")
        docs, _, _ = self.run_scan({"scanner": "fake:feeder", "duplex": True})
        self.assertEqual(docs, [["Sheet 1", "Sheet 1 back", "Sheet 2", "Sheet 2 back", "Sheet 3", "Sheet 3 back"]])

    def test_feeder_scanner_on_flatbed(self):
        docs, _, _ = self.run_scan({"scanner": "fake:feeder", "source": "flatbed"})
        self.assertEqual(docs, [["Flatbed page 1"]])

    def test_splitter(self):
        self.assertEqual(self.run_scan({"scanner": "fake:splitter"})[0],
                         [["Doc A page 1", "Doc A page 2", "", "Doc B page 1"]])
        self.assertEqual(self.run_scan({"scanner": "fake:splitter", "extras": {"skipBlankPages": True}})[0],
                         [["Doc A page 1", "Doc A page 2", "Doc B page 1"]])
        split = [["Doc A page 1", "Doc A page 2"], ["Doc B page 1"]]
        self.assertEqual(self.run_scan({"scanner": "fake:splitter", "extras": {"splitOnBlank": True}})[0], split)
        self.assertEqual(self.run_scan({"scanner": "fake:splitter",
                                        "extras": {"splitOnBlank": True, "skipBlankPages": True}})[0], split)

    def test_jam_is_partial(self):
        docs, partial, message = self.run_scan({"scanner": "fake:jam"})
        self.assertEqual(docs, [["Sheet 1", "Sheet 2"]])
        self.assertTrue(partial)
        self.assertIn("jam", message.lower())

    def test_offline_is_503(self):
        scanner, settings = validate({"scanner": "fake:offline"})
        with self.assertRaises(ScanError) as ctx:
            simulate(scanner, settings)
        self.assertEqual(ctx.exception.status, 503)

    def test_slow_takes_its_delay(self):
        scanner, settings = validate({"scanner": "fake:slow"})
        self.assertGreaterEqual(scanner.delay, 2.0)
        fast = fakes.FakeScanner(**{**scanner.__dict__, "delay": 0.2})
        start = time.monotonic()
        simulate(fast, settings)
        self.assertGreaterEqual(time.monotonic() - start, 0.2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd reference && python3 -m unittest discover -s tests -v`
Expected: errors — `ModuleNotFoundError: No module named 'scanbridge_ref'`.

- [ ] **Step 3: Implement**

`reference/scanbridge_ref/__init__.py`:
```python
"""Reference scan helper for the Dossiary scan bridge protocol v2 (fake scanners only)."""

__version__ = "0.1.0"
```

`reference/scanbridge_ref/pdf.py`:
```python
"""A minimal PDF writer: one A4 page per text line, Helvetica. Standard library only."""


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def make_pdf(page_texts: list[str]) -> bytes:
    """Build a PDF with one page per entry of page_texts ("" gives a blank page)."""
    if not page_texts:
        raise ValueError("a PDF needs at least one page")
    count = len(page_texts)
    # Object numbers: 1 catalog, 2 page tree, 3 font, then a page and its content per text.
    page_numbers = [4 + 2 * i for i in range(count)]
    bodies = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        ("<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(f"{n} 0 R" for n in page_numbers), count)).encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for page_number, text in zip(page_numbers, page_texts):
        bodies.append((
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {page_number + 1} 0 R >>"
        ).encode())
        stream = f"BT /F1 36 Tf 72 720 Td ({_escape(text)}) Tj ET".encode("latin-1")
        bodies.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(bodies, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref_at = len(out)
    out += f"xref\n0 {len(bodies) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(bodies) + 1} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n".encode()
    return bytes(out)
```

`reference/scanbridge_ref/fakes.py`:
```python
"""The protocol's fake scanners, request validation, and scan simulation."""

import time
from dataclasses import dataclass

COLOR_MODES = ("color", "gray", "bw")
RESOLUTIONS = (150, 300, 600)


class ScanError(Exception):
    """A protocol error: HTTP status plus a message for a person."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass(frozen=True)
class FakeScanner:
    id: str
    name: str
    sources: tuple
    duplex: bool
    color_modes: tuple
    resolutions: tuple
    extras: tuple
    sheets: tuple
    delay: float = 0.0
    offline: bool = False
    jam_after: int | None = None

    def describe(self) -> dict:
        return {
            "id": self.id, "name": self.name, "sources": list(self.sources), "duplex": self.duplex,
            "colorModes": list(self.color_modes), "resolutions": list(self.resolutions),
            "extras": list(self.extras),
        }


def _scanner(id, name, sources, duplex=False, extras=(), sheets=(), **kw):
    return FakeScanner(id=id, name=name, sources=sources, duplex=duplex, color_modes=COLOR_MODES,
                       resolutions=RESOLUTIONS, extras=extras, sheets=sheets, **kw)


FAKE_SCANNERS = (
    _scanner("fake:flatbed", "Fake Flatbed", ("flatbed",)),
    _scanner("fake:feeder", "Fake Feeder", ("feeder", "flatbed"), duplex=True,
             sheets=("Sheet 1", "Sheet 2", "Sheet 3")),
    _scanner("fake:splitter", "Fake Splitter", ("feeder",), extras=("splitOnBlank", "skipBlankPages"),
             sheets=("Doc A page 1", "Doc A page 2", "", "Doc B page 1")),
    _scanner("fake:jam", "Fake Jamming Feeder", ("feeder",), sheets=("Sheet 1", "Sheet 2", "Sheet 3"),
             jam_after=2),
    _scanner("fake:slow", "Fake Slow Scanner", ("flatbed",), delay=2.0),
    _scanner("fake:offline", "Fake Offline Scanner", ("flatbed",), offline=True),
)


def validate(body):
    """Protocol validation steps 1-5. Returns (scanner, normalized settings)."""
    if not isinstance(body, dict):
        raise ScanError(400, "The request body must be a JSON object.")
    scanner_id = body.get("scanner")
    if not isinstance(scanner_id, str):
        raise ScanError(400, "The request needs a scanner id.")
    scanner = next((s for s in FAKE_SCANNERS if s.id == scanner_id), None)
    if scanner is None:
        raise ScanError(404, f"No scanner with id “{scanner_id}”.")

    for key in ("source", "colorMode", "format"):
        if key in body and not isinstance(body[key], str):
            raise ScanError(400, f"“{key}” must be a string.")
    if "resolution" in body and (not isinstance(body["resolution"], int) or isinstance(body["resolution"], bool)):
        raise ScanError(400, "“resolution” must be a whole number.")
    if "duplex" in body and not isinstance(body["duplex"], bool):
        raise ScanError(400, "“duplex” must be true or false.")
    extras = body.get("extras", {})
    if not isinstance(extras, dict) or not all(isinstance(v, bool) for v in extras.values()):
        raise ScanError(400, "“extras” must map names to true or false.")

    source = body.get("source", scanner.sources[0])
    if source not in scanner.sources:
        raise ScanError(422, f"{scanner.name} has no {source} source.")
    color_mode = body.get("colorMode", scanner.color_modes[0])
    if color_mode not in scanner.color_modes:
        raise ScanError(422, f"{scanner.name} can't scan in {color_mode}.")
    resolution = body.get("resolution", scanner.resolutions[0])
    if resolution not in scanner.resolutions:
        raise ScanError(422, f"{scanner.name} can't scan at {resolution} dpi.")
    fmt = body.get("format", "pdf")
    if fmt != "pdf":
        raise ScanError(422, f"Format “{fmt}” isn't supported; use pdf.")
    duplex = body.get("duplex", False)
    if duplex and not (scanner.duplex and source == "feeder"):
        raise ScanError(422, f"{scanner.name} can't scan both sides from the {source}.")
    for name, on in extras.items():
        if on and name not in scanner.extras:
            raise ScanError(422, f"{scanner.name} doesn't offer “{name}”.")

    return scanner, {"source": source, "duplex": duplex, "colorMode": color_mode,
                     "resolution": resolution, "format": fmt, "extras": dict(extras)}


def _pages_message(count: int) -> str:
    return "1 page scanned." if count == 1 else f"{count} pages scanned."


def simulate(scanner, settings):
    """Run a fake scan. Returns (documents, partial, message)."""
    if scanner.offline:
        raise ScanError(503, f"{scanner.name} isn't reachable. Check that it's switched on and connected.")
    if scanner.delay:
        time.sleep(scanner.delay)

    if settings["source"] == "flatbed":
        pages = ["Flatbed page 1"]
    else:
        sheets = scanner.sheets if scanner.jam_after is None else scanner.sheets[:scanner.jam_after]
        pages = []
        for sheet in sheets:
            pages.append(sheet)
            if settings["duplex"]:
                pages.append(f"{sheet} back" if sheet else "")

    extras = settings["extras"]
    if extras.get("splitOnBlank"):
        documents, current = [], []
        for page in pages:
            if page == "":
                if current:
                    documents.append(current)
                current = []
            else:
                current.append(page)
        if current:
            documents.append(current)
    else:
        if extras.get("skipBlankPages"):
            pages = [p for p in pages if p != ""]
        documents = [pages]

    total = sum(len(d) for d in documents)
    if scanner.jam_after is not None and settings["source"] == "feeder":
        return documents, True, f"Paper jam after {scanner.jam_after} sheets. The pages before it were kept."
    return documents, False, _pages_message(total)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd reference && python3 -m unittest discover -s tests -v`
Expected: all tests `ok`, `OK` at the end.

- [ ] **Step 5: Commit**

```bash
git add reference/scanbridge_ref reference/tests
git commit -m "Reference helper: PDF writer and the protocol's fake scanners

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo"
```

---

### Task 3: Conformance suite

**Files:**
- Create: `conformance/client.py`, `conformance/test_conformance.py`

**Interfaces:**
- Consumes: only `PROTOCOL.md` (the suite talks HTTP; it must not import `scanbridge_ref`).
- Produces: `python3 -m unittest discover -s conformance -v` with env `SCAN_HELPER_URL` (default `http://127.0.0.1:8766`). Task 4 makes it pass against the reference helper; the native helpers run it later.

- [ ] **Step 1: Write the client**

`conformance/client.py`:
```python
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
```

- [ ] **Step 2: Write the suite**

`conformance/test_conformance.py`:
```python
"""Conformance suite for the Dossiary scan bridge protocol v2.

Run against a helper in fake scanner mode:
    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v
"""

import base64
import re
import threading
import time
import unittest

from client import BASE_URL, request

FAKE_IDS = ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam", "fake:slow", "fake:offline"]


def setUpModule():
    try:
        resp = request("GET", "/health", timeout=5)
    except OSError as err:
        raise RuntimeError(f"No helper answering at {BASE_URL} ({err}). Start one, or set SCAN_HELPER_URL.")
    if resp.status != 200:
        raise RuntimeError(f"{BASE_URL}/health answered {resp.status}")


def scan(body, **kw):
    return request("POST", "/scan", body=body, **kw)


class HealthTests(unittest.TestCase):
    def test_health(self):
        resp = request("GET", "/health")
        self.assertEqual(resp.status, 200)
        data = resp.json()
        self.assertIs(data["ok"], True)
        self.assertEqual(data["protocol"], 2)
        self.assertIsInstance(data["helper"], str)
        self.assertTrue(data["helper"])
        self.assertIsInstance(data["version"], str)
        self.assertTrue(data["version"])
        self.assertTrue(resp.headers.get("Content-Type", "").startswith("application/json"))


class ScannersTests(unittest.TestCase):
    def test_lists_the_six_fake_scanners_with_all_fields(self):
        resp = request("GET", "/scanners")
        self.assertEqual(resp.status, 200)
        scanners = resp.json()["scanners"]
        self.assertEqual(sorted(s["id"] for s in scanners), sorted(FAKE_IDS))
        for s in scanners:
            self.assertIsInstance(s["name"], str)
            self.assertTrue(set(s["sources"]) <= {"flatbed", "feeder"} and s["sources"])
            self.assertIsInstance(s["duplex"], bool)
            self.assertTrue(set(s["colorModes"]) <= {"color", "gray", "bw"} and s["colorModes"])
            self.assertTrue(all(isinstance(r, int) for r in s["resolutions"]) and s["resolutions"])
            self.assertEqual(s["resolutions"], sorted(s["resolutions"]))
            self.assertIsInstance(s["extras"], list)

    def test_fake_scanner_details(self):
        scanners = {s["id"]: s for s in request("GET", "/scanners").json()["scanners"]}
        self.assertEqual(scanners["fake:feeder"]["sources"], ["feeder", "flatbed"])
        self.assertIs(scanners["fake:feeder"]["duplex"], True)
        self.assertIs(scanners["fake:flatbed"]["duplex"], False)
        self.assertEqual(sorted(scanners["fake:splitter"]["extras"]), ["skipBlankPages", "splitOnBlank"])
        self.assertEqual(scanners["fake:flatbed"]["extras"], [])


class ScanTests(unittest.TestCase):
    def assertPdfFiles(self, resp, page_counts):
        data = resp.json()
        self.assertEqual([f["pages"] for f in data["files"]], page_counts)
        names = [f["name"] for f in data["files"]]
        self.assertEqual(len(set(names)), len(names))
        for f in data["files"]:
            self.assertTrue(f["name"].endswith(".pdf"))
            pdf = base64.b64decode(f["data"], validate=True)
            self.assertTrue(pdf.startswith(b"%PDF-"))
            self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
            counted = len(re.findall(rb"/Type\s*/Page(?!s)", pdf))
            if counted:  # writers that compress page objects can't be counted this way
                self.assertEqual(counted, f["pages"])
        return data

    def test_flatbed_minimal_request(self):
        resp = scan({"scanner": "fake:flatbed"})
        self.assertEqual(resp.status, 200)
        data = self.assertPdfFiles(resp, [1])
        self.assertIs(data["ok"], True)
        self.assertIs(data["partial"], False)
        self.assertEqual(data["message"], "1 page scanned.")

    def test_full_request(self):
        resp = scan({"scanner": "fake:feeder", "source": "feeder", "duplex": False, "colorMode": "gray",
                     "resolution": 300, "format": "pdf", "extras": {}})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.assertPdfFiles(resp, [3])["message"], "3 pages scanned.")

    def test_duplex(self):
        resp = scan({"scanner": "fake:feeder", "duplex": True})
        self.assertEqual(resp.status, 200)
        self.assertPdfFiles(resp, [6])

    def test_feeder_scanner_flatbed_source(self):
        resp = scan({"scanner": "fake:feeder", "source": "flatbed"})
        self.assertEqual(resp.status, 200)
        self.assertPdfFiles(resp, [1])

    def test_splitter_extras(self):
        self.assertPdfFiles(scan({"scanner": "fake:splitter"}), [4])
        self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"skipBlankPages": True}}), [3])
        self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"splitOnBlank": True}}), [2, 1])
        self.assertPdfFiles(scan({"scanner": "fake:splitter",
                                  "extras": {"splitOnBlank": True, "skipBlankPages": True}}), [2, 1])

    def test_unknown_extra_set_false_is_accepted(self):
        resp = scan({"scanner": "fake:flatbed", "extras": {"splitOnBlank": False}})
        self.assertEqual(resp.status, 200)

    def test_jam_is_partial(self):
        resp = scan({"scanner": "fake:jam"})
        self.assertEqual(resp.status, 200)
        data = self.assertPdfFiles(resp, [2])
        self.assertIs(data["ok"], False)
        self.assertIs(data["partial"], True)
        self.assertIn("jam", data["message"].lower())


class ErrorTests(unittest.TestCase):
    def assertError(self, resp, status):
        self.assertEqual(resp.status, status, resp.body[:200])
        data = resp.json()
        self.assertIs(data["ok"], False)
        self.assertIs(data["partial"], False)
        self.assertIsInstance(data["message"], str)
        self.assertTrue(data["message"].strip())

    def test_400_malformed(self):
        self.assertError(request("POST", "/scan", raw_body=b"{not json",
                                 headers={"Content-Type": "application/json"}), 400)
        self.assertError(scan([1, 2]), 400)
        self.assertError(scan({}), 400)
        self.assertError(scan({"scanner": 7}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": "300"}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "duplex": "yes"}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "extras": ["splitOnBlank"]}), 400)

    def test_404(self):
        self.assertError(scan({"scanner": "fake:does-not-exist"}), 404)
        self.assertError(request("GET", "/no-such-endpoint"), 404)

    def test_405_wrong_method(self):
        self.assertError(request("GET", "/scan"), 405)
        self.assertError(request("POST", "/health", body={}), 405)

    def test_422_unsupported_settings(self):
        self.assertError(scan({"scanner": "fake:flatbed", "source": "feeder"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "colorMode": "sepia"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": 1200}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "format": "tiff"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "duplex": True}), 422)
        self.assertError(scan({"scanner": "fake:feeder", "source": "flatbed", "duplex": True}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "extras": {"splitOnBlank": True}}), 422)

    def test_503_offline(self):
        self.assertError(scan({"scanner": "fake:offline"}), 503)

    def test_409_while_another_scan_runs(self):
        results = {}
        slow = threading.Thread(target=lambda: results.setdefault("slow", scan({"scanner": "fake:slow"})))
        slow.start()
        time.sleep(0.5)
        self.assertError(scan({"scanner": "fake:flatbed"}), 409)
        slow.join(timeout=30)
        self.assertEqual(results["slow"].status, 200)
        # Once the slow scan is done, the helper accepts scans again.
        self.assertEqual(scan({"scanner": "fake:flatbed"}).status, 200)


class OriginTests(unittest.TestCase):
    def test_no_origin_is_allowed(self):
        self.assertEqual(request("GET", "/health").status, 200)

    def test_allowed_origins_are_echoed(self):
        for origin in ["null", "http://localhost", "http://localhost:5173", "http://127.0.0.1:8833"]:
            resp = request("GET", "/health", headers={"Origin": origin})
            self.assertEqual(resp.status, 200, origin)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), origin)
            self.assertIn("Origin", resp.headers.get("Vary", ""))

    def test_other_origins_get_403(self):
        for origin in ["https://evil.example", "http://localhost.evil.example", "https://localhost:5173",
                       "http://192.168.1.5:8766"]:
            resp = request("GET", "/health", headers={"Origin": origin})
            self.assertEqual(resp.status, 403, origin)
            self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"))
        resp = scan({"scanner": "fake:flatbed"}, headers={"Origin": "https://evil.example"})
        self.assertEqual(resp.status, 403)

    def test_preflight(self):
        resp = request("OPTIONS", "/scan", headers={
            "Origin": "null", "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
            "Access-Control-Request-Private-Network": "true"})
        self.assertEqual(resp.status, 204)
        self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), "null")
        self.assertIn("POST", resp.headers.get("Access-Control-Allow-Methods", ""))
        self.assertIn("content-type", resp.headers.get("Access-Control-Allow-Headers", "").lower())
        self.assertEqual(resp.headers.get("Access-Control-Allow-Private-Network"), "true")

    def test_preflight_from_other_origin_is_403(self):
        resp = request("OPTIONS", "/scan", headers={"Origin": "https://evil.example",
                                                    "Access-Control-Request-Method": "POST"})
        self.assertEqual(resp.status, 403)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the suite to verify it fails**

No helper is running yet.
Run: `cd ~/Projects/Paperless/dossiary-scan-helper && SCAN_HELPER_URL=http://127.0.0.1:8799 python3 -m unittest discover -s conformance -v`
Expected: the run errors in `setUpModule` with `RuntimeError: No helper answering at http://127.0.0.1:8799`.

- [ ] **Step 4: Commit**

```bash
git add conformance
git commit -m "Conformance suite for protocol v2

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo"
```

---

### Task 4: Reference helper HTTP server

**Files:**
- Create: `reference/scanbridge_ref/server.py`, `reference/scanbridge_ref/__main__.py`
- Test: `reference/tests/test_server.py` (plus the conformance suite from Task 3)

**Interfaces:**
- Consumes: `make_pdf`, `FAKE_SCANNERS`, `validate`, `simulate`, `ScanError`, `__version__` from Task 2.
- Produces: `python3 -m scanbridge_ref [--host 127.0.0.1] [--port 8766]` serving the protocol; `server.make_server(host: str, port: int) -> ThreadingHTTPServer` and `server.origin_allowed(origin: str | None) -> bool`.

- [ ] **Step 1: Confirm the helper can't start yet**

Run: `cd reference && python3 -m scanbridge_ref --port 8766`
Expected: an error that `scanbridge_ref.__main__` doesn't exist.

- [ ] **Step 2: Implement the server**

`reference/scanbridge_ref/server.py`:
```python
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
```

`reference/scanbridge_ref/__main__.py`:
```python
"""python -m scanbridge_ref [--host 127.0.0.1] [--port 8766]"""

import argparse

from . import __version__
from .server import make_server


def main():
    parser = argparse.ArgumentParser(prog="scanbridge_ref",
                                     description="Reference Dossiary scan helper with fake scanners.")
    parser.add_argument("--host", default="127.0.0.1",
                        help="address to listen on (default 127.0.0.1; keep it local)")
    parser.add_argument("--port", type=int, default=8766, help="port (default 8766)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args()
    server = make_server(args.host, args.port)
    print(f"Reference scan helper on http://{args.host}:{args.port} (fake scanners). Ctrl+C stops it.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Add unit tests for the origin check**

Create `reference/tests/test_server.py`:
```python
import unittest

from scanbridge_ref.server import origin_allowed


class OriginAllowedTests(unittest.TestCase):
    def test_allowed(self):
        for origin in [None, "null", "http://localhost", "http://localhost:5173", "http://127.0.0.1:8833"]:
            self.assertTrue(origin_allowed(origin), origin)

    def test_refused(self):
        for origin in ["https://evil.example", "http://localhost.evil.example", "https://localhost",
                       "http://192.168.1.5:8766", "http://localhost/path", "file://"]:
            self.assertFalse(origin_allowed(origin), origin)


if __name__ == "__main__":
    unittest.main()
```

Run: `cd reference && python3 -m unittest discover -s tests -v`
Expected: all tests `ok`.

- [ ] **Step 4: Run the conformance suite against the reference helper**

Run in one shell:
```bash
cd ~/Projects/Paperless/dossiary-scan-helper/reference && python3 -m scanbridge_ref --port 8766 &
sleep 1
cd .. && SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v
kill %1
```
Expected: every test `ok` and `OK` at the end (about 20 tests, ~3 s because of the slow scanner).

- [ ] **Step 5: Commit**

```bash
git add reference/scanbridge_ref/server.py reference/scanbridge_ref/__main__.py reference/tests/test_server.py
git commit -m "Reference helper HTTP server passing the conformance suite

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo"
```

---

### Task 5: CI, then the GitHub repo

**Files:**
- Create: `.github/workflows/conformance.yml`

**Interfaces:**
- Consumes: the commands from Tasks 2–4.

- [ ] **Step 1: Write the workflow**

`.github/workflows/conformance.yml`:
```yaml
name: conformance

on:
  push:
  pull_request:

jobs:
  reference-helper:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Reference helper unit tests
        working-directory: reference
        run: python -m unittest discover -s tests -v
      - name: Start the reference helper
        working-directory: reference
        shell: bash
        run: |
          python -m scanbridge_ref --port 8766 > ../helper.log 2>&1 &
          for i in $(seq 1 50); do
            python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8766/health', timeout=1)" && exit 0
            sleep 0.2
          done
          echo "helper did not start"; cat ../helper.log; exit 1
      - name: Conformance suite
        shell: bash
        env:
          SCAN_HELPER_URL: http://127.0.0.1:8766
        run: python -m unittest discover -s conformance -v
```

(Running on all three systems is cheap and proves the reference helper and suite work wherever the native helpers will later run them.)

- [ ] **Step 2: Validate the YAML locally**

Run: `python3 -c "import sys; t=open('.github/workflows/conformance.yml').read(); assert 'conformance' in t and t.count('\t')==0; print('ok')"`
Expected: `ok` (no tab characters, file present).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/conformance.yml
git commit -m "CI: unit tests and conformance suite against the reference helper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo"
```

- [ ] **Step 4: Create the public GitHub repo and push (controller only, owner approved)**

This step is done by the controlling session, not a subagent:
```bash
cd ~/Projects/Paperless/dossiary-scan-helper
gh repo create AarneAarebye/dossiary-scan-helper --public --source . --push \
  --description "Scan from Dossiary with any scanner your Mac or Windows PC supports"
gh run watch --exit-status $(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
```
Expected: the repo exists, `main` is pushed, and the `conformance` workflow passes on all three systems.
