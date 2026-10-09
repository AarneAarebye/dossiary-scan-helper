# Dossiary scan bridge protocol, version 2

A scan helper is a small app on the person's computer that drives a
scanner and answers HTTP requests from [Dossiary](https://github.com/AarneAarebye/Dossiary),
a browser app that can't reach scanners itself. This document is the
contract every helper implements: the macOS and Windows helpers that will
live in this repo, the reference helper in it, and
[scanix500](https://github.com/AarneAarebye/iX500).

All response bodies are JSON (`Content-Type: application/json; charset=utf-8`).

## Listening

- Bind to `127.0.0.1` only, never to all interfaces.
- Default ports: `8766` for dossiary-scan-helper, `8765` for scanix500.

## Requests

- Request bodies are JSON. Helpers must not require a request
  `Content-Type`: a body is read as JSON whatever that header says.
- A `POST` body is `Content-Length` bytes long. A missing `Content-Length`
  means an empty body. A negative or non-numeric `Content-Length`, or a
  body over 1,000,000 bytes, → **400**.
- An integer is a JSON number without a fraction or exponent (`300`, not
  `300.0` or `3e2`).
- Query strings are ignored on version 2 endpoints (`GET /health?x=1` is
  `GET /health`). The one exception is a helper that also serves version 1,
  see the end of this document.

## Endpoints and methods

| Endpoint | Method | Token |
|---|---|---|
| `/health` | `GET` | not needed |
| `/pair` | `POST` | not needed |
| `/scanners` | `GET` | required |
| `/scan` | `POST` | required |

`OPTIONS` on any path, known or not, is a CORS preflight (see Origins).
Any other method on a known endpoint (including `HEAD`, `PUT`, `DELETE`,
`PATCH`) → **405** with an `Allow` header listing the endpoint's method and
`OPTIONS`: `Allow: GET, OPTIONS` for `/health` and `/scanners`,
`Allow: POST, OPTIONS` for `/scan` and `/pair`. Any method other than
`OPTIONS` on an unknown path → **404**.

A helper checks every request in this order and answers with the first
failure:

1. The `Origin` isn't allowed → **403** (see Origins).
2. Unknown path → **404**; known path, wrong method → **405**.
3. `/scanners` and `/scan` only: no valid token → **401** (see Pairing).
4. The endpoint's own checks (for `/scan`, "Request validation" below).

## `GET /health`

```json
{ "ok": true, "helper": "dossiary-scan-helper-macos", "version": "1.0.0", "protocol": 2, "paired": false }
```

`helper` names the implementation, `version` is its own version, and
`protocol` is `2`. `paired` is `true` when the request carried a valid
token (see Pairing), `false` otherwise; `/health` itself needs no token.
A response without `protocol` comes from a version 1 helper (see the end
of this document).

## Pairing

Each browser pairs with a helper once and from then on sends the token it
got with every `GET /scanners` and `POST /scan`:

    Authorization: Bearer <token>

A missing `Authorization` header, one that isn't `Bearer <token>`, or a
token the helper didn't issue (or has forgotten) → **401**.

### `POST /pair`

```json
{ "code": "123456", "client": "Chrome on a MacBook" }
```

`code` (string, required) is the pairing code the helper shows. `client`
(string, optional, at most 200 characters) describes the browser for the
helper's own display.

- The right code → **200** `{"ok": true, "token": "<token>"}`. The token is
  random with at least 128 bits of entropy, made of URL-safe characters
  (letters, digits, `-`, `_`), and at least 22 characters long. Every
  successful pairing issues a new token; earlier tokens stay valid.
- The body is not a JSON object, `code` is missing or not a string, or
  `client` is present but not a string or longer than 200 characters
  → **400**.
- A wrong code, an expired code, a code whose attempts are used up, or no
  pairing window open → **403**, with a message telling the person to
  choose "Pair a browser…" in the helper and try the new code.

`/pair` needs no token. Since this 403 answers an allowed origin, it
carries the CORS headers like every other such response, so Dossiary can
show the message.

### Real scanners

"Pair a browser…" in the helper's menu opens a pairing window showing a
fresh 6-digit code, valid for 2 minutes and 5 attempts. After the 5th
wrong attempt, or when the 2 minutes are up, the window closes and any
code is refused until the person opens a new one. Tokens persist across
restarts of the helper until "Forget paired browsers" in its menu revokes
all of them.

### Fake scanner mode

The pairing code is always `000000`. It's accepted any number of times
and never expires; any other code → **403**. Fake scanner mode exists for
testing only (see "Fake scanner mode" below); a helper used with real
documents runs with real scanners.

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
| `splitOnBlank` | A blank sheet separates documents. The result has one PDF per document; the blank sheets are dropped. When scanning both sides, a sheet counts as blank only if both sides are blank. |
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

After the origin and endpoint checks, a helper checks a scan request in
this order and answers with the first failure:

0. No valid token → **401**.
1. The body is not a JSON object (including a bad `Content-Length` or a
   body over 1,000,000 bytes, see Requests) → **400**.
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

If the scan then starts but fails before any usable page came back (empty
feeder, a jam before the first page, a device error, cancelled at the
device) → **500**.

### Response

```json
{ "ok": true, "partial": false, "message": "3 pages scanned.",
  "files": [ { "name": "scan_20261009_143200.pdf", "pages": 3, "data": "<base64>" } ] }
```

- `files`: one PDF with every page; with `splitOnBlank`, one PDF per
  document, in scan order.
- `pages`: the number of pages in that PDF.
- `data`: the PDF, base64-encoded (standard alphabet, with padding).
- `name`: a plain file name: no `/` or `\`, not starting with `.`,
  ending in `.pdf`, unique within the response.
- `partial: true` (with `ok: false`) means something went wrong but
  usable pages came back, for example a paper jam after the second
  sheet. `files` then holds those pages and `message` says what happened.

A scan result, including `partial: true`, is answered with **200**; only
the codes under Errors are non-200.

## Errors

| Code | Meaning |
|---|---|
| 400 | malformed request |
| 401 | no valid pairing token (`/scanners`, `/scan`) |
| 403 | origin not allowed, or pairing code refused (`/pair`) |
| 404 | unknown scanner, or unknown endpoint |
| 405 | wrong method for the endpoint |
| 409 | a scan is already running |
| 422 | a setting the scanner doesn't offer |
| 500 | the scan failed and no usable page came back |
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
- `http://localhost` and `http://127.0.0.1` with a port must use a port
  from 1 to 65535 (`http://localhost:0` is refused).
- Any other `Origin` gets **403** for every method, preflight included.
  That 403 carries no CORS headers.

For an allowed `Origin`, every response — success or error, any status —
carries `Access-Control-Allow-Origin: <that origin>` and `Vary: Origin`.

`OPTIONS` (preflight) on any path, known or not, answers **204** with
`Access-Control-Allow-Methods: GET, POST, OPTIONS`,
`Access-Control-Allow-Headers: Content-Type, Authorization` and
`Access-Control-Max-Age: 600`. If the request has
`Access-Control-Request-Private-Network: true`, the answer also carries
`Access-Control-Allow-Private-Network: true`.

`GET /health` and `GET /scanners` keep answering while a scan runs; only
a second `POST /scan` gets 409.

## Security considerations

The origin check alone can't keep other websites away from the scanner:
`Origin: null` can't identify Dossiary, because any website can send it,
from a sandboxed iframe or a `data:` URL. With the origin check alone, a
malicious page could start a scan and read the result. Each browser
therefore pairs with a helper once (see Pairing) and then sends a token
that other websites don't have. The origin check stays as a first line of
defence, and helpers listen on `127.0.0.1` only.

## Fake scanner mode

Every helper has a fake scanner mode (`--fake-scanners` for the native
helpers; the reference helper has nothing else). It exists for testing
only. It replaces the real scanners with exactly these seven, so one
conformance suite can test every helper without hardware, and fixes the
pairing code at `000000` (see Pairing). Pages carry the text shown; `""`
is a blank page.

| id | name | sources | duplex | colorModes | resolutions | extras |
|---|---|---|---|---|---|---|
| `fake:flatbed` | Fake Flatbed | flatbed | false | color, gray, bw | 150, 300, 600 | — |
| `fake:feeder` | Fake Feeder | feeder, flatbed | true | color, gray, bw | 150, 300, 600 | — |
| `fake:splitter` | Fake Splitter | feeder | false | color, gray, bw | 150, 300, 600 | splitOnBlank, skipBlankPages |
| `fake:jam` | Fake Jamming Feeder | feeder | false | color, gray, bw | 150, 300, 600 | — |
| `fake:slow` | Fake Slow Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |
| `fake:offline` | Fake Offline Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |
| `fake:empty` | Fake Empty Feeder | feeder | false | color, gray, bw | 150, 300, 600 | — |

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
- **`fake:empty`**: every valid scan request answers **500** with the
  message `No paper in the feeder.`

In fake scanner mode, messages are always English and exact, even in a
helper that localizes the messages for real scanners:

- A successful scan: `"<n> pages scanned."` (`"1 page scanned."` for one
  page), where `n` counts all pages in all files.
- `fake:jam`: a message containing `jam`.
- `fake:empty`: `No paper in the feeder.`
- A refused pairing code: a message containing `Pair a browser`.

## Version 1 (scanix500 before protocol 2)

Version 1 is kept only for older Dossiary releases. It has
`GET /health` without `protocol`, and
`POST /scan?skip_blank_filter=…&skip_ocr=…&split_on_blank=…`
(`true`/`false`) with no body. It answers with the same response shape,
without `pages`. Version 1 has no pairing. A helper serving both versions
tells them apart by the presence of query parameters on `POST /scan`.
Dossiary keeps speaking version 1 to helpers that don't report
`protocol: 2`; new helpers implement version 2 only.
