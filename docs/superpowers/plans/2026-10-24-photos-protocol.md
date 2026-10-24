# Photos protocol additions Implementation Plan (PROTOCOL.md, reference helper, conformance suite)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PROTOCOL.md` gains optional image formats (`formats`, `format`), scan areas (`areas`, `area`) and a size limit; the reference helper and the conformance suite implement and test them through an optional `fake:photo` scanner; the macOS helper is untouched and stays conformant.

**Architecture:** The protocol text changes first (source of truth), then the reference helper (standard library only: tiny hand-made PNG, a fixed tiny JPEG), then the conformance tests, which skip when a helper doesn't list `fake:photo` (the same pattern as `fake:ocr`). Spec: `/Users/aarneaarebye/Projects/iX500/docs/superpowers/specs/2026-10-24-photos-protocol-and-8800f-design.md` (the iX500 repo; read "Part 1a"). The sibling plan in that repo (`docs/superpowers/plans/2026-10-24-photos-ix500.md`) implements the scanix500 side; the two plans don't depend on each other's code.

**Tech Stack:** Python 3.11+ standard library only (reference helper, conformance suite), `unittest`.

## Global Constraints

- **Protocol version stays 2; every addition is optional.** A scanner without `formats` offers only `["pdf"]`; a request without `format` is a PDF; a scanner without `areas` decides itself. A client that doesn't know the new fields keeps working.
- **New 422 refusals** (wrong JSON types stay **400** and come first, per "Request validation"): `format` not in the scanner's `formats`; `area` not in the scanner's `areas`, or `area` for a scanner without `areas`; `ocr: true` with an image format; `colorMode: "bw"` with `format: "jpeg"`; a scan over the helper's size limit (the reference helper's limit is 100,000,000 pixels, inclusive: exactly that many is allowed).
- **Area ids** (width x height mm, upright, top-left at the glass's corner mark): `a4` 210 x 297, `a5` 148 x 210, `a6` 105 x 148, `10x15` 100 x 150, `13x18` 130 x 180. Pixel count = `round(width_mm / 25.4 * dpi) * round(height_mm / 25.4 * dpi)`.
- **Response files for images:** `pages: 1`, `name` ending in `.jpg` (jpeg) or `.png`, base64 `data`, no `ocrJob`; message `"1 image scanned."`.
- **`fake:photo`** (optional, like `fake:ocr`): "Fake Photo Scanner", flatbed, no duplex, color/gray/bw, resolutions 150, 300, 600, 1200, no extras, `formats ["pdf","jpeg","png"]`, `areas ["a4","10x15"]`, no `ocr`; a PDF scan is one page `Flatbed page 1` as for any flatbed.
- **The macOS helper (`macos/`) is not changed:** it doesn't list `fake:photo`, so the new conformance tests skip there. Its `swift test` and `macos/scripts/run-conformance.sh` must still pass.
- Reference helper and conformance suite: standard library only, Python 3.11+. Commands: `cd reference && python3 -m unittest discover -s tests -v`; with the reference helper running (`cd reference && python3 -m scanbridge_ref --port 8766`), `SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v`.
- Work on a feature branch off `main` in this repo; never commit to `main` directly. End commit messages with the attribution lines from the session's system reminder.

---

### Task 1: PROTOCOL.md

**Files:**
- Modify: `PROTOCOL.md`

This task is documentation; apply each edit exactly (find the "Old" text, replace it with the "New" text), then run the check at the end.

- [ ] **Step 1: The scanner entry table**

Old:
```
| `extras` | array of strings | Extra abilities, see below. |
| `ocr` | object, optional |
```
New:
```
| `extras` | array of strings | Extra abilities, see below. |
| `formats` | array of `"pdf"` / `"jpeg"` / `"png"`, optional | What a scan can come back as. Absent means `["pdf"]`. Always includes `"pdf"`, the default of a request without `format`. See Formats and areas. |
| `areas` | array of area ids, optional | The scan areas the scanner offers; the first is the default. Absent: the scanner decides (feeders). See Formats and areas. |
| `ocr` | object, optional |
```

- [ ] **Step 2: A new section after "Extras"**

Find the line `Clients ignore extras they don't know.` and insert this directly after it (with a blank line before and after):

```markdown
### Formats and areas

`formats` says what a scan can come back as: `"pdf"` (every scanner offers it,
and it is what a request without `format` gets), `"jpeg"` and `"png"`. An image
scan returns one image file per scan (see Response) and is never OCR'd. A scanner
without `formats` offers only `["pdf"]`.

`areas` lists, by id, the parts of the glass a flatbed can scan. An area is
sized in millimetres, upright, with its top-left corner at the glass's corner
mark:

| Area id | Width x height (mm) |
|---|---|
| `a4` | 210 x 297 |
| `a5` | 148 x 210 |
| `a6` | 105 x 148 |
| `10x15` | 100 x 150 |
| `13x18` | 130 x 180 |

A scanner lists only the ids it offers. A scanner without `areas` (a feeder)
decides itself, and a request that names an `area` for it is refused.

A helper may refuse a scan that is too large for it. The limit is the helper's
own, not a field: its message says what to change. scanix500 and the reference
helper refuse more than 100,000,000 pixels (the area's width and height at the
resolution, each rounded to whole pixels), for example "A4 at 1200 dpi is too
large (139 megapixels; the limit is 100): choose a smaller area or a lower
resolution."
```

- [ ] **Step 3: The request defaults**

Old:
```
the first `source`, `colorMode` and `resolution`, `duplex` false,
`format` `"pdf"`, every extra off.
```
New:
```
the first `source`, `colorMode` and `resolution`, `duplex` false,
`format` `"pdf"`, the first `area` (for a scanner that lists areas),
every extra off.
```

- [ ] **Step 4: Request validation, steps 4 and 5**

Old (step 4's first line):
```
4. A field has the wrong JSON type (`source`, `colorMode`, `format` not
   strings;
```
New:
```
4. A field has the wrong JSON type (`source`, `colorMode`, `format`, `area`
   not strings;
```

Replace the whole of item 5 (from `5. A value the scanner doesn't offer → **422**:` through `only with `ocr: true`).`) with:

```
5. A value the scanner doesn't offer → **422**: `source` not in
   `sources`; `colorMode` not in `colorModes`; `resolution` not in
   `resolutions`; `format` not in the scanner's `formats` (a scanner
   without `formats` offers only `"pdf"`); `area` not in the scanner's
   `areas`, or an `area` for a scanner without `areas`; `colorMode:
   "bw"` with `format: "jpeg"`; `duplex: true` when the scanner has
   `duplex: false` or the source isn't `"feeder"`; an extra set to
   `true` that isn't in the scanner's `extras`. (An unknown extra set to
   `false` is accepted.) `ocr: true` with an image format, or for a
   scanner without `ocr`; an `ocrLanguages` entry not in the scanner's
   `ocr.languages` (checked only with `ocr: true`). A scan over the
   helper's size limit (see Formats and areas).
```

- [ ] **Step 5: The response**

Replace these four bullets under `### Response`:

```
- `files`: one PDF with every page; with `splitOnBlank`, one PDF per
  document, in scan order.
- `pages`: the number of pages in that PDF.
- `data`: the PDF, base64-encoded (standard alphabet, with padding).
- `name`: a plain file name: no `/` or `\`, not starting with `.`,
  ending in `.pdf`, unique within the response.
```

with:

```
- `files`: one PDF with every page; with `splitOnBlank`, one PDF per
  document, in scan order. With `format` `"jpeg"` or `"png"`: one image
  file for the scan.
- `pages`: the number of pages in that PDF; `1` for an image.
- `data`: the file, base64-encoded (standard alphabet, with padding).
- `name`: a plain file name: no `/` or `\`, not starting with `.`,
  ending in `.pdf`, `.jpg` (for `"jpeg"`) or `.png`, unique within the
  response.
```

(The `ocrJob` bullet stays; an image has none, because `ocr: true` is refused with an image format.)

- [ ] **Step 6: Fake scanner mode**

Old:
```
only. It replaces the real scanners with exactly these seven, plus
`fake:ocr` when the helper does background OCR, so one
conformance suite
```
New:
```
only. It replaces the real scanners with exactly these seven, plus
`fake:ocr` when the helper does background OCR and `fake:photo` when it
offers image formats, so one
conformance suite
```

In the table, directly after the `fake:ocr` row add:

```
| `fake:photo` | Fake Photo Scanner | flatbed | false | color, gray, bw | 150, 300, 600, 1200 | — |
```

Old (the two lines after the table):
```
`fake:ocr` also offers `ocr: {"languages": ["deu", "eng"]}`. It's optional for
now: a helper may list only the first seven.
```
New:
```
`fake:ocr` also offers `ocr: {"languages": ["deu", "eng"]}`. It's optional for
now: a helper may list only the first seven.

`fake:photo` also offers `formats: ["pdf", "jpeg", "png"]` and `areas: ["a4",
"10x15"]`. It's optional: a helper that doesn't offer image formats doesn't
list it.
```

In "What a scan returns", after the `fake:ocr` bullet (it ends with "…as the reference helper writes it) and the plain file's bytes don't.") add:

```
- **`fake:photo`**: without `format`, like any flatbed (one PDF, one page).
  With `format` `"jpeg"` or `"png"`: one small valid image file (a JPEG
  starts with `FF D8 FF`, a PNG with its 8-byte signature), `pages: 1`, a
  name ending in `.jpg` or `.png`, no `ocrJob`. Every refusal in "Request
  validation" applies, and **`a4` at 1200 dpi is refused (422)**, being
  over the size limit; `10x15` at 1200 dpi is allowed.
```

In the message list at the end of "Fake scanner mode", after the "A successful scan" item add:

```
- A successful image scan: `"1 image scanned."`.
```

- [ ] **Step 7: Check the edits**

Run: `grep -c "Formats and areas" PROTOCOL.md; grep -n "fake:photo" PROTOCOL.md | wc -l; grep -n "format\` other than" PROTOCOL.md`
Expected: `Formats and areas` appears at least 4 times (two table rows, the validation item, the section title), `fake:photo` at least 4 times (intro, table row, its description and its scan bullet), and the last grep prints nothing (the old "`format` other than `"pdf"`" text is gone).

- [ ] **Step 8: Commit**

```bash
git add PROTOCOL.md
git commit -m "PROTOCOL.md: image formats, scan areas, size limit, optional fake:photo"
```

---

### Task 2: The reference helper's tiny images

**Files:**
- Create: `reference/scanbridge_ref/images.py`
- Create: `reference/tests/test_images.py`

**Interfaces:**
- Produces: `make_jpeg() -> bytes`, `make_png() -> bytes`, `make_image(fmt: str) -> bytes` (`"jpeg"` or `"png"`), `EXTENSIONS = {"jpeg": "jpg", "png": "png"}`.

- [ ] **Step 1: Write the failing test**

Create `reference/tests/test_images.py`:

```python
import struct
import unittest
import zlib

from scanbridge_ref.images import EXTENSIONS, make_image, make_jpeg, make_png


class ImageTests(unittest.TestCase):
    def test_the_jpeg_is_a_complete_jpeg(self):
        data = make_jpeg()
        self.assertTrue(data.startswith(b"\xff\xd8\xff"))
        self.assertTrue(data.endswith(b"\xff\xd9"))

    def test_the_png_is_a_complete_png_with_valid_chunks(self):
        data = make_png()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertTrue(data.endswith(b"IEND\xaeB`\x82"))
        position, names = 8, []
        while position < len(data):
            length, name = struct.unpack(">I4s", data[position:position + 8])
            body = data[position + 8:position + 8 + length]
            (crc,) = struct.unpack(">I", data[position + 8 + length:position + 12 + length])
            self.assertEqual(crc, zlib.crc32(name + body) & 0xFFFFFFFF, name)
            names.append(name)
            position += 12 + length
        self.assertEqual(names, [b"IHDR", b"IDAT", b"IEND"])
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual((width, height), (8, 8))

    def test_make_image_picks_by_format_and_refuses_others(self):
        self.assertEqual(make_image("jpeg"), make_jpeg())
        self.assertEqual(make_image("png"), make_png())
        with self.assertRaises(ValueError):
            make_image("tiff")

    def test_extensions(self):
        self.assertEqual(EXTENSIONS, {"jpeg": "jpg", "png": "png"})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd reference && python3 -m unittest tests.test_images -v`
Expected: `ModuleNotFoundError: No module named 'scanbridge_ref.images'`.

- [ ] **Step 3: Implement**

Create `reference/scanbridge_ref/images.py`:

```python
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
```

**Careful:** the base64 string above is split into four pieces for readability; it must decode to exactly 332 bytes starting `FF D8 FF E0`. After saving, run `cd reference && python3 -c "from scanbridge_ref.images import make_jpeg; d = make_jpeg(); print(len(d), d[:4].hex(), d[-2:].hex())"`; expected `332 ffd8ffe0 ffd9`. If it differs, the base64 was altered when splitting: re-join the four pieces into one string with no whitespace.

- [ ] **Step 4: Run the tests**

Run: `cd reference && python3 -m unittest tests.test_images -v`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add reference/scanbridge_ref/images.py reference/tests/test_images.py
git commit -m "Reference helper: tiny valid JPEG and PNG for the fake photo scanner"
```

---

### Task 3: The reference helper's fake photo scanner, validation and scan

**Files:**
- Modify: `reference/scanbridge_ref/fakes.py`
- Modify: `reference/scanbridge_ref/server.py`
- Test: `reference/tests/test_fakes.py`, `reference/tests/test_server.py`

**Interfaces:**
- Consumes: `make_image`, `EXTENSIONS` (Task 2).
- Produces: `FakeScanner.formats` / `.areas`; `describe()` lists them only when they differ from the PDF-only default; `fake:photo` last in `FAKE_SCANNERS`; `AREAS`, `MAX_PIXELS`, `pixel_count(area, dpi)`; `validate` returns settings with `"area"` and refuses per the Global Constraints; `simulate` answers an image request with one page and `"1 image scanned."`; the server returns one image file for it.

- [ ] **Step 1: Write the failing tests**

In `reference/tests/test_fakes.py`: change the imports to `from scanbridge_ref.fakes import FAKE_SCANNERS, MAX_PIXELS, ScanError, pixel_count, simulate, validate`; in `ValidateTests.test_defaults` add `"area": None` to the expected settings dict (after `"format": "pdf"`); and append:

```python
class PhotoTests(unittest.TestCase):
    def assertStatus(self, body, status):
        with self.assertRaises(ScanError) as ctx:
            validate(body)
        self.assertEqual(ctx.exception.status, status)
        self.assertTrue(ctx.exception.message)
        return ctx.exception.message

    def test_describe_lists_formats_and_areas_only_for_the_photo_scanner(self):
        self.assertEqual(by_id("fake:photo").describe(), {
            "id": "fake:photo", "name": "Fake Photo Scanner", "sources": ["flatbed"], "duplex": False,
            "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600, 1200], "extras": [],
            "formats": ["pdf", "jpeg", "png"], "areas": ["a4", "10x15"],
        })
        for scanner in FAKE_SCANNERS:
            if scanner.id != "fake:photo":
                self.assertNotIn("formats", scanner.describe())
                self.assertNotIn("areas", scanner.describe())

    def test_the_photo_scanner_comes_after_the_other_eight(self):
        self.assertEqual([s.id for s in FAKE_SCANNERS][7:], ["fake:ocr", "fake:photo"])

    def test_defaults_are_pdf_and_the_first_area(self):
        _, settings = validate({"scanner": "fake:photo"})
        self.assertEqual((settings["format"], settings["area"]), ("pdf", "a4"))

    def test_an_image_request_is_accepted(self):
        _, settings = validate({"scanner": "fake:photo", "format": "jpeg", "area": "10x15", "resolution": 1200})
        self.assertEqual((settings["format"], settings["area"], settings["resolution"]), ("jpeg", "10x15", 1200))
        validate({"scanner": "fake:photo", "format": "png", "colorMode": "bw"})

    def test_refusals_are_422(self):
        for body in ({"format": "tiff"}, {"area": "a5"}, {"format": "jpeg", "colorMode": "bw"},
                     {"format": "jpeg", "ocr": True}, {"format": "png", "ocr": True},
                     {"area": "a4", "resolution": 1200}, {"format": "png", "area": "a4", "resolution": 1200}):
            self.assertStatus({"scanner": "fake:photo", **body}, 422)

    def test_scanners_without_the_fields_refuse_them(self):
        self.assertStatus({"scanner": "fake:flatbed", "format": "jpeg"}, 422)
        self.assertStatus({"scanner": "fake:flatbed", "area": "a4"}, 422)

    def test_a_wrong_area_type_is_400_before_any_422(self):
        self.assertStatus({"scanner": "fake:photo", "area": 5, "format": "jpeg", "colorMode": "bw"}, 400)

    def test_the_size_limit_message_says_what_to_change(self):
        message = self.assertStatus({"scanner": "fake:photo", "area": "a4", "resolution": 1200}, 422)
        self.assertEqual(message, "A4 at 1200 dpi is too large (139 megapixels; the limit is 100): "
                                  "choose a smaller area or a lower resolution.")

    def test_pixel_count_and_the_limit(self):
        self.assertEqual(pixel_count("a4", 1200), 9921 * 14031)
        self.assertEqual(pixel_count("10x15", 1200), 4724 * 7087)
        self.assertEqual(MAX_PIXELS, 100_000_000)
        self.assertLess(pixel_count("10x15", 1200), MAX_PIXELS)

    def test_an_image_scan_is_one_page_and_an_images_message(self):
        scanner, settings = validate({"scanner": "fake:photo", "format": "jpeg", "area": "10x15"})
        self.assertEqual(simulate(scanner, settings), ([["Flatbed page 1"]], False, "1 image scanned."))
```

Append to `reference/tests/test_server.py`, inside `OcrEndpointTests` (it already has `call`, a paired token and a running server; keep its class), these methods:

```python
    def test_a_jpeg_scan_returns_one_image_file(self):
        status, body = self.call("POST", "/scan", {"scanner": "fake:photo", "format": "jpeg", "area": "10x15"})
        self.assertEqual(status, 200)
        self.assertEqual(body["message"], "1 image scanned.")
        (f,) = body["files"]
        self.assertTrue(f["name"].endswith(".jpg"))
        self.assertEqual((f["pages"], "ocrJob" in f), (1, False))
        import base64
        self.assertTrue(base64.b64decode(f["data"]).startswith(b"\xff\xd8\xff"))

    def test_a_png_scan_and_the_default_pdf(self):
        import base64
        status, body = self.call("POST", "/scan", {"scanner": "fake:photo", "format": "png"})
        self.assertEqual(status, 200)
        self.assertTrue(body["files"][0]["name"].endswith(".png"))
        self.assertTrue(base64.b64decode(body["files"][0]["data"]).startswith(b"\x89PNG"))
        status, body = self.call("POST", "/scan", {"scanner": "fake:photo"})
        self.assertTrue(body["files"][0]["name"].endswith(".pdf"))

    def test_an_image_refusal_is_a_422_with_a_message(self):
        status, body = self.call("POST", "/scan", {"scanner": "fake:photo", "area": "a4", "resolution": 1200})
        self.assertEqual(status, 422)
        self.assertIn("too large", body["message"])
```

(The method placement: they use `self.call`, so they belong in the class that defines it. If the file's server test class has been renamed, put them in whichever class defines `call` and pairs in `setUp`.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd reference && python3 -m unittest discover -s tests -v 2>&1 | tail -15`
Expected: FAIL/ERROR in the new tests (`ImportError: cannot import name 'MAX_PIXELS'`, no `fake:photo`).

- [ ] **Step 3: Implement `fakes.py`**

At the top, after `RESOLUTIONS = (150, 300, 600)` add:

```python
# Scan areas (PROTOCOL.md "Formats and areas"): id -> (width mm, height mm, label), and the
# reference helper's size limit in pixels (inclusive).
AREAS = {"a4": (210, 297, "A4"), "a5": (148, 210, "A5"), "a6": (105, 148, "A6"),
         "10x15": (100, 150, "10 x 15 cm"), "13x18": (130, 180, "13 x 18 cm")}
MAX_PIXELS = 100_000_000


def pixel_count(area, dpi):
    width_mm, height_mm, _ = AREAS[area]
    return round(width_mm / 25.4 * dpi) * round(height_mm / 25.4 * dpi)
```

In the `FakeScanner` dataclass add two fields after `ocr_languages: tuple = ()`:

```python
    formats: tuple = ("pdf",)
    areas: tuple = ()
```

In `describe`, before `if self.ocr_languages:` add:

```python
        if self.formats != ("pdf",):
            entry["formats"] = list(self.formats)
        if self.areas:
            entry["areas"] = list(self.areas)
```

Change `_scanner` to accept a resolutions override:

```python
def _scanner(id, name, sources, duplex=False, extras=(), sheets=(), resolutions=RESOLUTIONS, **kw):
    return FakeScanner(id=id, name=name, sources=sources, duplex=duplex, color_modes=COLOR_MODES,
                       resolutions=resolutions, extras=extras, sheets=sheets, **kw)
```

and add the new scanner as the last entry of `FAKE_SCANNERS`:

```python
    _scanner("fake:photo", "Fake Photo Scanner", ("flatbed",), resolutions=(150, 300, 600, 1200),
             formats=("pdf", "jpeg", "png"), areas=("a4", "10x15")),
```

In `validate`: change `for key in ("source", "colorMode", "format"):` to `for key in ("source", "colorMode", "format", "area"):`; replace

```python
    fmt = body.get("format", "pdf")
    if fmt != "pdf":
        raise ScanError(422, f"Format “{fmt}” isn't supported; use pdf.")
```

with

```python
    fmt = body.get("format", "pdf")
    if fmt not in scanner.formats:
        raise ScanError(422, f"{scanner.name} can't make {fmt} files; it offers {', '.join(scanner.formats)}.")
    if "area" in body and not scanner.areas:
        raise ScanError(422, f"{scanner.name} has no scan areas.")
    area = body.get("area", scanner.areas[0] if scanner.areas else None)
    if area is not None and area not in scanner.areas:
        raise ScanError(422, f"{scanner.name} doesn't offer the area “{area}”.")
    if fmt == "jpeg" and color_mode == "bw":
        raise ScanError(422, "JPEG can't be black and white; use PNG or PDF.")
```

after `ocr = body.get("ocr", False)` insert:

```python
    if ocr and fmt != "pdf":
        raise ScanError(422, "A searchable PDF can't be made from an image; scan to PDF instead.")
```

before the final `return scanner, {...}` insert:

```python
    if area is not None:
        pixels = pixel_count(area, resolution)
        if pixels > MAX_PIXELS:
            raise ScanError(422, f"{AREAS[area][2]} at {resolution} dpi is too large ({pixels / 1e6:.0f} megapixels; "
                                 f"the limit is {MAX_PIXELS // 1_000_000}): choose a smaller area or a lower resolution.")
```

and add `"area": area,` to the returned settings dict (next to `"format": fmt`). In `simulate`, right after the `if scanner.empty:` block add:

```python
    if settings["format"] != "pdf":
        return [["Flatbed page 1"]], False, "1 image scanned."
```

- [ ] **Step 4: Implement `server.py`**

Add `from .images import EXTENSIONS, make_image` with the other relative imports. In `_scan`, right after `stamp = time.strftime("%Y%m%d_%H%M%S")` insert:

```python
        if settings["format"] != "pdf":
            name = f"scan_{stamp}.{EXTENSIONS[settings['format']]}"
            data = base64.b64encode(make_image(settings["format"])).decode("ascii")
            self._send_json(200, {"ok": True, "partial": False, "message": message,
                                  "files": [{"name": name, "pages": 1, "data": data}]})
            return
```

- [ ] **Step 5: Run the tests**

Run: `cd reference && python3 -m unittest discover -s tests -v 2>&1 | tail -6`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add reference/scanbridge_ref/fakes.py reference/scanbridge_ref/server.py reference/tests
git commit -m "Reference helper: the fake photo scanner, image and area validation, image scans"
```

---

### Task 4: Conformance tests

**Files:**
- Modify: `conformance/test_conformance.py`

**Interfaces:**
- Consumes: the reference helper from Task 3 (the suite runs against it).

- [ ] **Step 1: Write the tests**

In `conformance/test_conformance.py`:

1. After the `OPTIONAL_FAKES` dict's `"fake:ocr"` entry add a second entry:

```python
    "fake:photo": {"name": "Fake Photo Scanner", "sources": ["flatbed"], "duplex": False, "extras": [],
                   "resolutions": [150, 300, 600, 1200],
                   "formats": ["pdf", "jpeg", "png"], "areas": ["a4", "10x15"]},
```

2. In `ScannersTests.test_fake_scanner_table`, let an entry's own fields override the standard ones: change `self.assertEqual(actual, {"id": scanner_id, **expected, **_STANDARD, "extras": sorted(expected["extras"])}, scanner_id)` to `self.assertEqual(actual, {"id": scanner_id, **_STANDARD, **expected, "extras": sorted(expected["extras"])}, scanner_id)`.

3. In `ScannersTests.test_lists_the_seven_fake_scanners_with_all_fields`, inside the `for s in scanners:` loop, after the `if "ocr" in s:` block add:

```python
            if "formats" in s:
                self.assertIn("pdf", s["formats"])
                self.assertTrue(set(s["formats"]) <= {"pdf", "jpeg", "png"})
            if "areas" in s:
                self.assertTrue(s["areas"] and all(isinstance(a, str) for a in s["areas"]))
```

4. After the `OcrTests` class (end of the file, before `if __name__ == "__main__":` if present) add:

```python
class PhotoTests(unittest.TestCase):
    """Image formats and scan areas (PROTOCOL.md, "Formats and areas"). Runs only against a
    helper listing fake:photo."""

    @classmethod
    def setUpClass(cls):
        if "fake:photo" not in listed_ids():
            raise unittest.SkipTest("helper doesn't list fake:photo (image formats are optional)")

    def image_scan(self, fmt, **extra):
        return scan({"scanner": "fake:photo", "format": fmt, **extra})

    def assertImage(self, resp, suffix, signature):
        self.assertEqual(resp.status, 200, resp.body[:200])
        data = resp.json()
        self.assertIs(data["ok"], True)
        self.assertEqual(data["message"], "1 image scanned.")
        (f,) = data["files"]
        self.assertEqual(f["pages"], 1)
        self.assertTrue(f["name"].endswith(suffix), f["name"])
        self.assertNotIn("/", f["name"])
        self.assertNotIn("ocrJob", f)
        raw = base64.b64decode(f["data"], validate=True)
        self.assertTrue(raw.startswith(signature), raw[:8])
        return raw

    def test_jpeg(self):
        raw = self.assertImage(self.image_scan("jpeg", area="10x15", resolution=600), ".jpg", b"\xff\xd8\xff")
        self.assertTrue(raw.rstrip(b"\x00").endswith(b"\xff\xd9"))

    def test_png(self):
        raw = self.assertImage(self.image_scan("png", colorMode="bw"), ".png", b"\x89PNG\r\n\x1a\n")
        self.assertTrue(raw.endswith(b"IEND\xaeB`\x82"))

    def test_the_default_format_is_pdf_and_the_default_area_is_the_first(self):
        resp = scan({"scanner": "fake:photo"})
        self.assertEqual(resp.status, 200, resp.body[:200])
        f = resp.json()["files"][0]
        self.assertTrue(f["name"].endswith(".pdf"))
        self.assertTrue(base64.b64decode(f["data"]).startswith(b"%PDF-"))

    def test_the_largest_allowed_scan(self):
        self.assertEqual(self.image_scan("jpeg", area="10x15", resolution=1200).status, 200)

    def test_refusals_are_422_with_a_message(self):
        for body in ({"format": "tiff"}, {"area": "a5"}, {"format": "jpeg", "colorMode": "bw"},
                     {"format": "jpeg", "ocr": True}, {"format": "png", "ocr": True},
                     {"area": "a4", "resolution": 1200}, {"format": "png", "area": "a4", "resolution": 1200}):
            resp = scan({"scanner": "fake:photo", **body})
            self.assertEqual(resp.status, 422, body)
            assert_error(self, resp, 422)

    def test_a_scanner_without_formats_or_areas_refuses_them(self):
        assert_error(self, scan({"scanner": "fake:flatbed", "format": "jpeg"}), 422)
        assert_error(self, scan({"scanner": "fake:flatbed", "area": "a4"}), 422)

    def test_a_wrong_type_is_400_before_any_422(self):
        assert_error(self, scan({"scanner": "fake:photo", "area": 5, "format": "jpeg", "colorMode": "bw"}), 400)
```

(`assert_error(case, resp, status)` already exists near the top of the file: it checks the status and the error body. If its signature differs, adapt the calls to it; do not change it.)

- [ ] **Step 2: Run the suite against the reference helper**

In one terminal: `cd reference && python3 -m scanbridge_ref --port 8766`. In another, from the repo root: `SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v 2>&1 | tail -15`.
Expected: every test passes, the new `PhotoTests` among them (none skipped); the total is the previous count plus 8. Stop the reference helper.

- [ ] **Step 3: Check that a helper without `fake:photo` still passes**

Run the same suite against the reference helper with `fake:photo` removed: temporarily comment out the `fake:photo` entry in `reference/scanbridge_ref/fakes.py`, restart the helper, run the suite. Expected: `PhotoTests` reports `skipped`, everything else passes. Restore the entry (`git checkout reference/scanbridge_ref/fakes.py` if you changed nothing else there).

- [ ] **Step 4: Commit**

```bash
git add conformance/test_conformance.py
git commit -m "Conformance: image formats, areas and the size limit (skipped without fake:photo)"
```

---

### Task 5: The macOS helper stays conformant

**Files:** none (verification, and a documentation line).

- [ ] **Step 1: Run the macOS helper's own tests and the suite against its fake mode**

Run: `cd macos && scripts/test.sh` then `scripts/run-conformance.sh`.
Expected: the unit tests pass; the conformance run passes with `PhotoTests` skipped (the macOS helper doesn't list `fake:photo`). If either script can't run in this environment (it needs macOS 14+ and the Swift command line tools), say so and do not mark the step done.

- [ ] **Step 2: Note the follow-up in the docs**

In `README.md` (or `AGENTS.md`, wherever the protocol's optional pieces are listed, next to `fake:ocr`), add one sentence: "`fake:photo` (image formats and scan areas) is optional; the macOS helper doesn't offer it yet." If neither file lists `fake:ocr`, skip this step and say so.

- [ ] **Step 3: Run everything once more and commit**

Run: `cd reference && python3 -m unittest discover -s tests` (all pass). Then, if Step 2 changed a file:

```bash
git add README.md AGENTS.md
git commit -m "Docs: fake:photo is optional; the macOS helper doesn't offer it yet"
```
