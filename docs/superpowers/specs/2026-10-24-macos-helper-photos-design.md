# The macOS helper and photo scans: image formats and scan areas

Date: 2026-10-24
Repo: dossiary-scan-helper (this one). The scanix500 repo and the Pi server need no change
(the 8800F is flatbed-only and never lists `full`).

Sub-project 2b of the CanoScan 8800F photo work. 2a (scanix500 0.9.0 and the protocol
additions: `formats`, `areas`, `format`, `area`, the size limit, the optional `fake:photo`) is
merged; the design is
`/Users/aarneaarebye/Projects/iX500/docs/superpowers/specs/2026-10-24-photos-protocol-and-8800f-design.md`.
Dossiary's own controls are a later project (2c).

## Goal

The Swift macOS helper implements the photo part of protocol version 2, so that:

- the scanners of a paired scanix500-server (the Pi's 8800F) show their `formats` and `areas` in
  `GET /scanners` and can be scanned to JPEG or PNG over a chosen area, through the helper;
- the Mac's own local scanners (Image Capture) offer JPEG, PNG and scan areas too, from their
  flatbed;
- the helper's fake mode serves `fake:photo`, so the conformance photo tests run against it.

PDF stays the default everywhere, and nothing changes for a client that doesn't send `format` or
`area`.

## Decisions (made while designing, with the reasons)

- **Local scanners get images and areas too** (not just the Pi's): the user asked for it, and a
  local flatbed is the natural place to scan a photo.
- **Images only from the flatbed.** `formats` is per scanner, not per source, so a device with a
  flatbed and a feeder (the Canon MF650C) lists images; the feeder source refuses them. One image
  file per page from a feeder (and what `splitOnBlank` would mean for images) would be a much
  larger protocol change for something PDF already covers.
- **A new area id `full`** for local scanners. Today a local flatbed scans its whole glass, whose
  size varies (Letter, A4, other). The protocol says the first area is the default, so something
  must stand for the whole glass, or PDF scans on local scanners would shrink to A4 or A5. `full`
  means the scanner's own whole scan area. Rejected: no areas for local scanners (photos always
  full glass), and defaulting to the largest standard area that fits (silently changes PDF scans on
  Letter glass).
- **The same 100-megapixel limit everywhere,** so the rules are uniform. For `full` the helper
  uses the glass size it knows from the scanner.
- **No new UI text.** Messages to Dossiary stay English; no localization changes.

## Part A: protocol additions (PROTOCOL.md, reference helper, conformance)

1. **Area id `full`** in the "Formats and areas" table: "the scanner's own whole scan area, size not
   fixed (helpers that scan the whole glass of whatever size they find)". A scanner that lists it
   lists it first (it is then the default). The size limit uses its real size; the scanner list
   entry doesn't give that size. The reference helper's scanners never list it.
2. **Images need the flatbed:** `format` `"jpeg"` or `"png"` with `source: "feeder"` is **422**,
   "Images can only be scanned from the flatbed.", checked in "Request validation" step 5 right after
   the `format` and `area` checks. The reference helper implements it and has a unit test (with an
   ad-hoc scanner that has both a feeder and image formats). The conformance suite can't test it,
   because no fake scanner has both, and one more fake scanner for a single rule isn't worth it;
   this is stated in the plan.

## Part B: the macOS helper (Swift, `macos/Sources/HelperCore/`)

- **Model (`Model.swift`).** `ScannerInfo` gets `formats: [String]` (default `["pdf"]`) and
  `areas: [String]` (default none), written to the JSON entry only when they differ from the defaults
  and read back when parsing a remote entry (so a server's scanners keep them), plus an internal
  `fullAreaMM: (width: Double, height: Double)?` for local flatbeds (not serialized). `ScanSettings`
  gets `format` (default `"pdf"`) and `area` (optional).
- **Areas table.** A small `Areas` type with the five fixed ids, their millimetre sizes, labels for
  messages, and `pixelCount(areaID, dpi, fullArea)` using `round(width_mm / 25.4 * dpi) *
  round(height_mm / 25.4 * dpi)`; `MAX_PIXELS` is 100,000,000 (inclusive: exactly that is allowed).
- **Validator (`ScanRequestValidator.swift`).** Every rule of the protocol: wrong types 400 first
  (`area` is already checked as text), then 422 for a format the scanner doesn't offer, an area it
  doesn't list (or `area` for a scanner without areas: the rule added last week becomes
  "not in its list"), jpeg with bw, an image from the feeder, `ocr` with an image, and a scan over the
  limit, with the same English messages as the reference helper and scanix500 (for example "A4 at
  1200 dpi is too large (139 megapixels; the limit is 100): choose a smaller area or a lower
  resolution."; for `full`, "The whole glass at <n> dpi is too large (<m> megapixels; the limit is
  100): choose a smaller area or a lower resolution."). When the helper doesn't know an area's size (a
  remote scanner listing `full`), it skips its own limit check and the server's answer decides. The settings carry `format` and `area`
  (defaulting to the first listed area, if any).
- **Capability mapping (`CapabilityMapping.swift`).** A scanner with a flatbed unit lists `formats
  ["pdf","jpeg","png"]` and `areas ["full"] + [the standard ids whose size fits the flatbed's
  physical size]`, and keeps the flatbed's physical size in millimetres as `fullAreaMM`. A scanner
  with only a feeder lists neither. `UnitCapabilities` gets the unit's physical size (inches from
  Image Capture) so the mapping stays a pure function that tests can feed.
- **Local scan (`ImageCaptureBackend.swift`).** For a flatbed scan the scan area is set from
  `settings.area` (millimetres to inches; `full` is the physical size as now). For an image format the
  device's document type follows the format (`jpeg`, `png`; black & white is PNG, as now) and the
  scanned file's bytes are returned as the result, one file, with no PDF building and no OCR. If the
  returned bytes aren't the requested type (some network/eSCL drivers ignore it) they are re-encoded
  with ImageIO, which also sets the dpi if the file has none. A new result kind carries images next to
  the page lists (`ScanDocuments`).
- **Remote scanners (`RemoteScanners.swift`).** Listing keeps `formats` and `areas` (ids unchanged);
  `scan` adds `format` (when not pdf) and `area` (when set) to the forwarded body. The server's answer,
  image files included, already passes through unchanged.
- **Response (`ScanResponse.swift`/`Router.swift`).** An image file has `pages: 1`, a name ending
  `.jpg` or `.png` (unique within the response), the base64 data, no `ocrJob`; the message is
  `"1 image scanned."`.
- **Fake mode (`FakeScanners.swift`, `FakeBackend.swift`).** `fake:photo`, last in the list, exactly as
  the protocol's fake table says (flatbed, formats pdf/jpeg/png, areas a4/10x15, resolutions 150, 300,
  600, 1200); its scan returns a tiny valid JPEG or PNG.
- **Version.** `HelperVersion.string` becomes `0.5.0`. Signing, notarizing and releasing stay with the
  user and their keychain (see macos/README.md "Release"); this project doesn't release.

## Testing

Automated (Swift unit tests, `macos/scripts/test.sh`, no mocking of Image Capture):
- the validator: every 422 and 400, the order of checks, the inclusive size limit, `full` taking its
  size from the scanner, an image from the feeder, an area for a scanner without areas;
- the capability mapping: flatbed + feeder, flatbed only, feeder only; Letter-size and A4-size glass
  (which standard areas fit; `full` first); a feeder-only scanner lists neither;
- the remote scanners: the listing keeps `formats` and `areas`; the forwarded scan body carries `format`
  and `area` (fake transport);
- the image response shape and `fake:photo`.

Conformance (`macos/scripts/run-conformance.sh`, always with `PORT=8799` or another free port: 8766 is
the user's real helper): against the macOS helper's fake mode all 58 tests run with none skipped
(`PhotoTests` included); against the reference helper as before; the reference helper's unit tests
include the new image-needs-flatbed rule.

Manual, on real hardware (not mocked):
- the Canon MF650C (local, flatbed and feeder): flatbed JPEG and PNG at `full`, `10x15` and `a5`, with
  the pixel sizes checked; the area's origin at the glass's corner mark; a black & white PNG; PDF scans
  unchanged from the flatbed and from the feeder; an image request from the feeder refused with the
  message above;
- through the helper to the Pi: a build run on a free port (never the user's real helper on 8766)
  lists the Pi's 8800F with its `formats` and `areas`, and a `10x15` JPEG scan comes back.

## Risks

1. **Image Capture's units and origin.** `scanArea` and `physicalSize` are in inches; the origin of the
   area on a local scanner is unverified until the hardware check.
2. **Image Capture may ignore the requested file type or area,** especially on network (eSCL) scanners;
   the re-encode step covers the type, and a scan whose pixel size doesn't match the requested area is
   reported in the hardware check, not hidden.
3. **dpi metadata** may be missing in the files Image Capture writes; the re-encode step sets it.
4. A device whose flatbed reports no physical size lists only `full`.

## Order of work

One branch in this repo: Part A first (PROTOCOL.md, reference helper and its unit tests, conformance),
then Part B. The macOS helper is the last consumer of the protocol text, so nothing else waits for it.

## Out of scope

Dossiary's Format and Paper size controls (project 2c); images from feeders; custom areas in
millimetres; TIFF; landscape placement; film; releasing the signed app.
