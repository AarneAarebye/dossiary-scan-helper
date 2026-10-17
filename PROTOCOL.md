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
| `/ocr/<job>` | `GET` | required |

`OPTIONS` on any path, known or not, is a CORS preflight (see Origins).
Any other method on a known endpoint (including `HEAD`, `PUT`, `DELETE`,
`PATCH`) → **405** with an `Allow` header listing the endpoint's method and
`OPTIONS`: `Allow: GET, OPTIONS` for `/health`, `/scanners` and `/ocr/<job>`,
`Allow: POST, OPTIONS` for `/scan` and `/pair`. Any method other than
`OPTIONS` on an unknown path → **404**. `/ocr` and `/ocr/` without a job id are
unknown paths (404).

A helper checks every request in this order and answers with the first
failure:

1. The `Origin` isn't allowed → **403** (see Origins).
2. Unknown path → **404**; known path, wrong method → **405**.
3. `/scanners`, `/scan` and `/ocr/<job>` only: no valid token → **401** (see Pairing).
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
| `ocr` | object, optional | Present only when the helper can make a searchable PDF of this scanner's pages (see Background OCR). `languages`: the OCR languages it offers, as Tesseract-style codes (`deu`, `eng`, `fra`, `spa`, `chi_sim`, `chi_tra`). |

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
  "extras": { "splitOnBlank": false },
  "ocr": true, "ocrLanguages": ["deu", "eng"] }
```

Only `scanner` is required. Missing fields use the scanner's defaults:
the first `source`, `colorMode` and `resolution`, `duplex` false,
`format` `"pdf"`, every extra off.
`ocr` (default false) asks for a searchable PDF in the background;
`ocrLanguages` picks its languages, most likely first (a helper may use the
order as priority). Missing or `[]` means the helper's choice; a repeated
code counts once.

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
   not an object whose values are all booleans; `ocr` not a boolean;
   `ocrLanguages` not an array of strings) → **400**.
5. A value the scanner doesn't offer → **422**: `source` not in
   `sources`; `colorMode` not in `colorModes`; `resolution` not in
   `resolutions`; `format` other than `"pdf"`; `duplex: true` when the
   scanner has `duplex: false` or the source isn't `"feeder"`; an extra
   set to `true` that isn't in the scanner's `extras`. (An unknown extra
   set to `false` is accepted.) `ocr: true` for a scanner without `ocr`;
   an `ocrLanguages` entry not in the scanner's `ocr.languages` (checked
   only with `ocr: true`).
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
- `ocrJob`: present on every file when the request had `ocr: true`,
  including a `partial: true` scan; a scan answering with an error has no
  jobs. The file is then the plain scan, and `GET /ocr/<job>` delivers its
  searchable version (see Background OCR). Each file has its own job (with
  `splitOnBlank`, one per document). A job id is random, at least 128 bits,
  made of URL-safe characters (letters, digits, `-`, `_`) and at least 22
  characters long, like a pairing token.

A scan result, including `partial: true`, is answered with **200**; only
the codes under Errors are non-200.

## Background OCR

A scan with `ocr: true` answers as soon as the plain PDFs exist; the helper
then makes each file searchable in the background, one job at a time. The
client fetches the result:

### `GET /ocr/<job>`

Needs the token, like `/scan`.

| Answer | Meaning |
|---|---|
| **202** `{"ok": true, "state": "queued", "position": 2}` | Not done yet. `state` is `queued` or `running`; `position` counts the jobs ahead of it (0 while it runs). |
| **200** `{"ok": true, "files": [{"name": "…", "pages": 3, "data": "<base64>"}]}` | The searchable PDF, with the same `name` and `pages` as the plain file. `files` always holds exactly one entry. |
| **404** | Unknown job, already fetched, or expired. |
| **500** | OCR failed; the usual error body says why. This is final: the job is gone (a later fetch answers 404), and the client may fall back to its own OCR. |

- Fetching a **200** deletes the result: a second fetch answers 404.
- A page whose text can't be recognized is left without text; the job
  still answers 200. 500 means no searchable PDF could be made at all.
- Jobs and results expire 7 days after their scan. Until then a helper
  keeps them across its own restarts (on disk): unfinished jobs resume in
  their original order, and `position` counts only the current queue.
- CORS and preflight work as for every other endpoint.
- A new scan may start while OCR jobs run; only a second simultaneous scan
  gets 409.
- Clients poll every few seconds, without a timeout of their own beyond
  the 7 days.

## Network scan servers (scanix500-server)

A helper may also list scanners of a **scanix500-server** on the local
network (a Raspberry Pi with an iX500). Dossiary never talks to the server:
the helper lists its scanners as `remote:<server>:<id>`, named
"<scanner> (<server name>)", forwards `POST /scan` and returns the answer
with each `ocrJob` renamed `remote.<server>.<job>`, and forwards
`GET /ocr/remote.<server>.<job>`. An unreachable server answers OCR polls
with 503, so Dossiary keeps polling and eventually falls back to its own OCR.

The server listens over **HTTPS** (port 8767 by default) with a self-signed
certificate; the helper pins its SHA-256 fingerprint when pairing and refuses
any other certificate. It is found with Bonjour (`_dossiary-scan._tcp`). It
refuses any request with an `Origin` header (no web pages), and its
`GET /health` adds `"remote": true`, `"fingerprint"` (64 hex digits) and
`"name"`. Besides `POST /pair` (with a code from `sudo scanix500-server
pair`, valid 5 minutes) it offers **button pairing**: `POST /pair/button`
`{"client": "<name>"}` → `202 {"request": "<id>"}`; then
`GET /pair/button/<id>` → `202` while waiting, `200 {"token"}` once the
iX500's Scan button is pressed, `408` after 2 minutes, `409` when two
computers asked at once (both refused), `429` after 10 requests in a minute.

## Errors

| Code | Meaning |
|---|---|
| 400 | malformed request |
| 401 | no valid pairing token (`/scanners`, `/scan`, `/ocr/<job>`) |
| 403 | origin not allowed, or pairing code refused (`/pair`) |
| 404 | unknown scanner, unknown endpoint, or unknown or fetched OCR job |
| 405 | wrong method for the endpoint |
| 409 | a scan is already running |
| 422 | a setting the scanner doesn't offer |
| 500 | the scan failed and no usable page came back, or a background OCR job failed (`/ocr/<job>`) |
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

`GET /health`, `GET /scanners` and `GET /ocr/<job>` keep answering while a
scan runs; only a second `POST /scan` gets 409.

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
only. It replaces the real scanners with exactly these seven, plus
`fake:ocr` when the helper does background OCR, so one
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
| `fake:ocr` | Fake OCR Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |

`fake:ocr` also offers `ocr: {"languages": ["deu", "eng"]}`. It's optional for
now: a helper may list only the first seven.

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
- **`fake:ocr`**: without `ocr: true`, like any flatbed. With `ocr: true`:
  one page *without* the text `Flatbed page 1`, and an `ocrJob` that answers
  202 for 2 seconds after the scan, then 200 with one page whose content has
  `Flatbed page 1`. Both PDFs must be written so that a plain byte search
  works: the result's bytes contain the literal text `Flatbed page 1` (for
  example in an uncompressed content stream, as the reference helper
  writes it) and the plain file's bytes don't.

In fake scanner mode, messages are always English and exact, even in a
helper that localizes the messages for real scanners:

- A successful scan: `"<n> pages scanned."` (`"1 page scanned."` for one
  page), where `n` counts all pages in all files.
- `fake:jam`: a message containing `jam`.
- `fake:empty`: `No paper in the feeder.`
- A refused pairing code: a message containing `Pair a browser`.

## Version 1 (scanix500 before protocol 2)

Version 1 is scanix500's own older protocol, kept for Dossiary releases
that don't speak version 2. New helpers implement version 2 only, and
Dossiary keeps speaking version 1 to a helper that doesn't report
`protocol: 2`. It differs from version 2 in its wire format, not just in
the missing endpoints:

- `GET /health` → `{"service": "scanix500-bridge", "paired": <bool>}`,
  with no `ok`, `helper`, `version` or `protocol`. Before scanix500 0.3.0
  there was no `paired` field (and no pairing at all).
- `POST /scan?skip_blank_filter=…&skip_ocr=…&split_on_blank=…`, each
  required and exactly `true` or `false`, with no body. The response is
  `{"ok", "partial", "message", "output_paths", "files"}`, where each file
  is `{"filename": "...", "content_base64": "..."}` (not `name`/`data`)
  and has no `pages`. `output_paths` lists where the helper kept its own
  copy.
- Errors are `{"error": "<message>"}`: 400 for missing or invalid
  parameters, 404 for an unknown path, 409 while a scan is running.
- Pairing, since scanix500 0.3.0: `POST /pair` as in version 2 (refusals
  are `{"error"}` with 403, malformed bodies 400), and `POST /scan`
  answers 401 without a valid `Authorization: Bearer <token>`. CORS
  follows the Security section: the allowed origins are echoed and any
  other `Origin` gets 403. Before 0.3.0 the bridge answered every origin
  with `Access-Control-Allow-Origin: *` and had no token, so any website
  could start a scan and read the document.

A helper serving both versions tells them apart by the presence of query
parameters on `POST /scan`.
