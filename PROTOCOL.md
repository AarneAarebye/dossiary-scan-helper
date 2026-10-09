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
