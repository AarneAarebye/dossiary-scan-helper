# The macOS helper and photo scans Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Swift macOS helper implements the photo part of protocol version 2: the Pi's 8800F shows its `formats`/`areas` and scans to JPEG/PNG through the helper, the Mac's own flatbeds offer JPEG, PNG and scan areas, and fake mode serves `fake:photo`, so the conformance photo tests run on macOS.

**Architecture:** Two small protocol additions first (area id `full`; images need the flatbed) in `PROTOCOL.md` and the reference helper. Then Swift: an `Areas` table and the model fields; the validator implements every rule; the capability mapping gives local flatbeds `formats` and `areas` (`full` first); an image result type and response; `fake:photo`; remote forwarding; and the Image Capture changes (area, file type, image result). The spec is `docs/superpowers/specs/2026-10-24-macos-helper-photos-design.md` (this repo); the iX500 side is already merged (scanix500 0.9.0).

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode (`swift-tools-version:6.0`), swift-testing (`@Test`, `#expect`), ImageIO/CoreGraphics, ImageCaptureCore; Python 3.11 standard library for the reference helper.

## Global Constraints

- **Protocol version stays 2; everything is optional.** A scanner without `formats` offers only `["pdf"]`; without `areas` it has none; a client that sends neither `format` nor `area` sees no change. The size limit is **100,000,000 pixels, inclusive**; pixel count = `round(width_mm / 25.4 * dpi) * round(height_mm / 25.4 * dpi)`.
- **Area ids** (width x height mm, upright, top-left at the glass's corner mark): `a4` 210 x 297, `a5` 148 x 210, `a6` 105 x 148, `10x15` 100 x 150, `13x18` 130 x 180, plus **`full`** = the scanner's own whole scan area (size not fixed), always first when a scanner lists it.
- **Request refusals (422), with these exact messages** (the same as scanix500 and the reference helper): format not offered: `"<name> can't make <fmt> files; it offers <a, b, c>."`; area for a scanner without areas: `"<name> has no scan areas."`; area not offered: `"<name> doesn't offer the area “<area>”."`; jpeg with bw: `"JPEG can't be black and white; use PNG or PDF."`; image from the feeder: `"Images can only be scanned from the flatbed."`; ocr with an image: `"A searchable PDF can't be made from an image; scan to PDF instead."`; over the limit: `"<label> at <dpi> dpi is too large (<n> megapixels; the limit is 100): choose a smaller area or a lower resolution."` with `<label>` `A4`, `A5`, `A6`, `10 x 15 cm`, `13 x 18 cm` or `The whole glass` (for `full`). Wrong JSON types stay 400 and are checked first. When the helper doesn't know an area's size (a remote scanner's `full`), it skips its own limit check.
- **Image response:** `pages: 1`, a name ending `.jpg` or `.png`, base64 `data`, no `ocrJob`; the message is `"1 image scanned."`. Images only from the flatbed; feeders stay PDF-only.
- **No new user-visible text in the app and no localization changes** (the localization tests fail on unknown keys); messages to Dossiary stay English.
- **Never use port 8766: it is the user's real Dossiary Scan Helper.** `macos/scripts/run-conformance.sh` defaults to 8766: always run it as `PORT=8799 scripts/run-conformance.sh`; start the reference helper on 8798. Stop everything you start and confirm nothing of yours is left listening.
- Hardware code (`ImageCaptureBackend`'s Image Capture calls) is verified manually on real scanners, not mocked; only its pure helpers are unit-tested.
- Commands: Swift unit tests `cd macos && scripts/test.sh` (baseline **128 tests**); reference tests `cd reference && python3 -m unittest discover -s tests` (baseline **56**); conformance against the macOS fake mode `cd macos && PORT=8799 scripts/run-conformance.sh` (baseline 52 tests, 1 skipped); against the reference helper: `cd reference && python3 -m scanbridge_ref --port 8798 &` then `SCAN_HELPER_URL=http://127.0.0.1:8798 python3 -m unittest discover -s conformance` (baseline 58).
- Work on a feature branch off `spec/macos-photos` (or `main` once it is merged); never commit to `main` directly. End commit messages with the attribution lines from the session's system reminder. Do not release, tag, sign or install anything.

---

### Task 1: PROTOCOL.md: the area id `full` and "images need the flatbed"

**Files:**
- Modify: `PROTOCOL.md`

Documentation; apply each edit, then run the check.

- [ ] **Step 1: The `full` area id.** In the "Formats and areas" section's area table, add this row directly after the `13x18` row:

```
| `full` | the scanner's own whole scan area, whatever its size |
```

and replace the paragraph that starts `A scanner lists only the ids it offers.` (it runs to `... a request that names an `area` for it is refused.`) with:

```
A scanner lists only the ids it offers. A scanner without `areas` (a feeder)
decides itself, and a request that names an `area` for it is refused.

`full` is for a scanner that scans whatever size of glass it has, such as a
local scanner a helper finds through the operating system. A scanner that lists
it lists it first, so it is the default: a request without `area` scans the
whole glass, as it always did. The scanner entry doesn't say how big `full` is;
the size limit below uses its real size. scanix500 never lists `full`.
```

- [ ] **Step 2: Images need the flatbed.** In the same section, directly after the sentence ending `... without `formats` offers only `["pdf"]`.` in the first paragraph, add:

```
Images only come from the flatbed: a scan from the feeder is always a PDF, so a
scanner that has both lists the image formats once, and the feeder source refuses
them.
```

In "Request validation", item 5, change the part `` `colorMode: "bw"` with `format: "jpeg"`; `` so that it reads:

```
`colorMode:
   "bw"` with `format: "jpeg"`; an image `format` (`"jpeg"` or `"png"`) with
   `source` `"feeder"`;
```

(keep the surrounding words and line breaks otherwise as they are).

- [ ] **Step 3: Check.** Run: `grep -c '`full`' PROTOCOL.md; grep -n 'with$' PROTOCOL.md | head -2; grep -n 'source` `"feeder"`' PROTOCOL.md`
Expected: `full` appears at least 3 times; the last grep finds the new text in item 5.

- [ ] **Step 4: Commit**

```bash
git add PROTOCOL.md
git commit -m "PROTOCOL.md: area id full for local scanners; images need the flatbed source"
```

---

### Task 2: The reference helper refuses images from the feeder

**Files:**
- Modify: `reference/scanbridge_ref/fakes.py`
- Test: `reference/tests/test_fakes.py`

**Interfaces:**
- Produces: `validate` answers **422** `"Images can only be scanned from the flatbed."` for `format` `"jpeg"`/`"png"` with `source` `"feeder"`, right after the `jpeg`/`bw` check.

- [ ] **Step 1: Write the failing test.** In `reference/tests/test_fakes.py` add `from unittest import mock` to the imports and append:

```python
class ImagesNeedTheFlatbedTests(unittest.TestCase):
    def test_an_image_from_the_feeder_is_422_and_the_flatbed_and_pdf_are_fine(self):
        both = fakes.FakeScanner(
            id="fake:both", name="Both", sources=("flatbed", "feeder"), duplex=False,
            color_modes=fakes.COLOR_MODES, resolutions=fakes.RESOLUTIONS, extras=(), sheets=("Sheet 1",),
            formats=("pdf", "jpeg", "png"))
        with mock.patch.object(fakes, "FAKE_SCANNERS", (both,)):
            for fmt in ("jpeg", "png"):
                with self.assertRaises(ScanError) as ctx:
                    validate({"scanner": "fake:both", "source": "feeder", "format": fmt})
                self.assertEqual((ctx.exception.status, ctx.exception.message),
                                 (422, "Images can only be scanned from the flatbed."))
            validate({"scanner": "fake:both", "source": "flatbed", "format": "jpeg"})
            validate({"scanner": "fake:both", "source": "feeder"})  # a PDF from the feeder is fine
```

(`fakes` and `ScanError`/`validate` are already imported at the top of that file.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd reference && python3 -m unittest tests.test_fakes.ImagesNeedTheFlatbedTests -v`
Expected: FAIL (`AssertionError: ScanError not raised`).

- [ ] **Step 3: Implement.** In `reference/scanbridge_ref/fakes.py`, directly after

```python
    if fmt == "jpeg" and color_mode == "bw":
        raise ScanError(422, "JPEG can't be black and white; use PNG or PDF.")
```

add:

```python
    if fmt != "pdf" and source == "feeder":
        raise ScanError(422, "Images can only be scanned from the flatbed.")
```

- [ ] **Step 4: Run all reference tests and the conformance suite**

Run: `cd reference && python3 -m unittest discover -s tests 2>&1 | tail -3` (expected: 57 tests OK). Then start the reference helper on port 8798 in the background (`cd reference && python3 -m scanbridge_ref --port 8798 &`, remember its PID), run `SCAN_HELPER_URL=http://127.0.0.1:8798 python3 -m unittest discover -s conformance 2>&1 | tail -3` from the repo root (expected: 58 tests OK, none skipped), and stop the helper. Never use port 8766.

- [ ] **Step 5: Commit**

```bash
git add reference/scanbridge_ref/fakes.py reference/tests/test_fakes.py
git commit -m "Reference helper: images only from the flatbed"
```

---

### Task 3: `Areas`, `SizeMM` and the model fields

**Files:**
- Create: `macos/Sources/HelperCore/Areas.swift`
- Modify: `macos/Sources/HelperCore/Model.swift`
- Create: `macos/Tests/HelperCoreTests/AreasTests.swift`

**Interfaces:**
- Produces:
  - `Areas.Area(id: String, widthMM: Double, heightMM: Double, label: String)`; `Areas.all: [Area]` (the five fixed ids, table order); `Areas.named(_ id: String) -> Area?`; `Areas.full = "full"`; `Areas.maxPixels = 100_000_000`; `Areas.pixelCount(widthMM:heightMM:dpi:) -> Int`; `Areas.isOverLimit(_ pixels: Int) -> Bool` (`pixels > maxPixels`); `Areas.fitting(widthMM:heightMM:) -> [String]` (standard ids that fit a glass, with 0.5 mm tolerance, table order)
  - `SizeMM(width: Double, height: Double)` (`Equatable, Sendable`)
  - `ScannerInfo.formats: [String]` (default `["pdf"]`), `.areas: [String]` (default `[]`), `.fullAreaMM: SizeMM?` (default nil, not serialized); `ScannerInfo.json` lists `formats`/`areas` only when they differ from the defaults; `ScannerInfo(json:)` reads them back
  - `ScanSettings.format: String` (default `"pdf"`) and `.area: String?` (default nil), the last two init parameters

- [ ] **Step 1: Write the failing tests.** Create `macos/Tests/HelperCoreTests/AreasTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

@Test func theFixedAreasMatchTheProtocol() {
    #expect(Areas.all.map(\.id) == ["a4", "a5", "a6", "10x15", "13x18"])
    #expect(Areas.named("a4")?.widthMM == 210 && Areas.named("a4")?.heightMM == 297)
    #expect(Areas.named("13x18")?.label == "13 x 18 cm" && Areas.named("10x15")?.label == "10 x 15 cm")
    #expect(Areas.named("full") == nil && Areas.named("letter") == nil)
    #expect(Areas.full == "full")
}

@Test func pixelCountRoundsEachSideToWholePixels() {
    #expect(Areas.pixelCount(widthMM: 210, heightMM: 297, dpi: 600) == 4961 * 7016)
    #expect(Areas.pixelCount(widthMM: 100, heightMM: 150, dpi: 1200) == 4724 * 7087)
    #expect(Areas.pixelCount(widthMM: 210, heightMM: 297, dpi: 1200) == 9921 * 14031)
}

@Test func theLimitIsInclusive() {
    #expect(Areas.maxPixels == 100_000_000)
    #expect(!Areas.isOverLimit(100_000_000))
    #expect(Areas.isOverLimit(100_000_001))
}

@Test func fittingAreasForGlassOfDifferentSizes() {
    #expect(Areas.fitting(widthMM: 215.9, heightMM: 297.2) == ["a4", "a5", "a6", "10x15", "13x18"])
    #expect(Areas.fitting(widthMM: 215.9, heightMM: 279.4) == ["a5", "a6", "10x15", "13x18"])  // Letter: A4 is too tall
    #expect(Areas.fitting(widthMM: 209.8, heightMM: 296.8).first == "a4")  // within 0.5 mm counts as fitting
    #expect(Areas.fitting(widthMM: 120, heightMM: 160) == ["a6", "10x15"])
    #expect(Areas.fitting(widthMM: 50, heightMM: 50).isEmpty)
}

@Test func scannerInfoJsonListsFormatsAndAreasOnlyWhenTheyDiffer() {
    let plain = ScannerInfo(id: "a", name: "A", sources: [.flatbed], duplex: false, colorModes: [.color],
                            resolutions: [300], extras: [])
    #expect(plain.formats == ["pdf"] && plain.areas.isEmpty && plain.fullAreaMM == nil)
    #expect(plain.json["formats"] == nil && plain.json["areas"] == nil)
    let photo = ScannerInfo(id: "b", name: "B", sources: [.flatbed], duplex: false, colorModes: [.color],
                            resolutions: [300], extras: [], formats: ["pdf", "jpeg", "png"],
                            areas: ["full", "10x15"], fullAreaMM: SizeMM(width: 216, height: 297))
    #expect(photo.json["formats"] as? [String] == ["pdf", "jpeg", "png"])
    #expect(photo.json["areas"] as? [String] == ["full", "10x15"])
    #expect(photo.json["fullAreaMM"] == nil)  // internal: never in the protocol entry
}

@Test func aRemoteEntryKeepsItsFormatsAndAreas() {
    let entry: [String: Any] = ["id": "sane:canoscan-8800f", "name": "Canon CanoScan 8800F", "sources": ["flatbed"],
                                "duplex": false, "colorModes": ["color", "gray", "bw"],
                                "resolutions": [150, 300, 600, 1200], "extras": [],
                                "formats": ["pdf", "jpeg", "png"], "areas": ["a4", "a5", "10x15"]]
    let info = ScannerInfo(json: entry)
    #expect(info?.formats == ["pdf", "jpeg", "png"] && info?.areas == ["a4", "a5", "10x15"])
    #expect(info?.fullAreaMM == nil)
    let old = ScannerInfo(json: ["id": "x", "name": "X", "sources": ["feeder"]])
    #expect(old?.formats == ["pdf"] && old?.areas.isEmpty == true)
}

@Test func scanSettingsDefaultToPdfAndNoArea() {
    let settings = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 300, extras: [:])
    #expect(settings.format == "pdf" && settings.area == nil)
    let photo = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 300, extras: [:],
                             format: "jpeg", area: "10x15")
    #expect(photo.format == "jpeg" && photo.area == "10x15")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter AreasTests 2>&1 | tail -8`
Expected: build error (`cannot find 'Areas' in scope`).

- [ ] **Step 3: Implement.** Create `macos/Sources/HelperCore/Areas.swift`:

```swift
import Foundation

/// A size in millimetres.
public struct SizeMM: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Scan areas (PROTOCOL.md "Formats and areas"): the five fixed ids, `full`, and the size limit.
public enum Areas {
    public struct Area: Equatable, Sendable {
        public let id: String
        public let widthMM: Double
        public let heightMM: Double
        /// How messages name it.
        public let label: String
    }

    /// The scanner's own whole scan area, whatever its size.
    public static let full = "full"
    /// The most pixels one scan may have (inclusive); the Pi has about 3.4 GB and a scan peaks near three
    /// times its raw size.
    public static let maxPixels = 100_000_000

    public static let all: [Area] = [
        Area(id: "a4", widthMM: 210, heightMM: 297, label: "A4"),
        Area(id: "a5", widthMM: 148, heightMM: 210, label: "A5"),
        Area(id: "a6", widthMM: 105, heightMM: 148, label: "A6"),
        Area(id: "10x15", widthMM: 100, heightMM: 150, label: "10 x 15 cm"),
        Area(id: "13x18", widthMM: 130, heightMM: 180, label: "13 x 18 cm"),
    ]

    public static func named(_ id: String) -> Area? { all.first { $0.id == id } }

    /// Pixels in a scan of this size: each side rounded to whole pixels.
    public static func pixelCount(widthMM: Double, heightMM: Double, dpi: Int) -> Int {
        Int((widthMM / 25.4 * Double(dpi)).rounded()) * Int((heightMM / 25.4 * Double(dpi)).rounded())
    }

    public static func isOverLimit(_ pixels: Int) -> Bool { pixels > maxPixels }

    /// The fixed ids that fit a glass of this size (within half a millimetre), in table order.
    public static func fitting(widthMM: Double, heightMM: Double) -> [String] {
        all.filter { $0.widthMM <= widthMM + 0.5 && $0.heightMM <= heightMM + 0.5 }.map(\.id)
    }
}
```

In `macos/Sources/HelperCore/Model.swift`: in `ScannerInfo` add three stored properties after `ocrLanguages`:

```swift
    /// What a scan can come back as; `["pdf"]` unless the scanner also makes images.
    public var formats: [String]
    /// The scan areas it offers, by id (`full` first for a scanner that scans whatever glass it has); none for a feeder.
    public var areas: [String]
    /// The size of `full` for a local flatbed: known to this helper, never sent in the protocol entry.
    public var fullAreaMM: SizeMM?
```

change the `init` to

```swift
    public init(id: String, name: String, sources: [Source], duplex: Bool, colorModes: [ColorMode],
                resolutions: [Int], extras: [String], ocrLanguages: [String] = [],
                formats: [String] = ["pdf"], areas: [String] = [], fullAreaMM: SizeMM? = nil) {
        self.id = id; self.name = name; self.sources = sources; self.duplex = duplex
        self.colorModes = colorModes; self.resolutions = resolutions; self.extras = extras
        self.ocrLanguages = ocrLanguages
        self.formats = formats; self.areas = areas; self.fullAreaMM = fullAreaMM
    }
```

in `json`, after the `ocr` line add:

```swift
        if formats != ["pdf"] { object["formats"] = formats }
        if !areas.isEmpty { object["areas"] = areas }
```

and in `init?(json:)` pass the two new values to `self.init(...)` after `ocrLanguages:`:

```swift
                  ocrLanguages: ocr?["languages"] as? [String] ?? [],
                  formats: json["formats"] as? [String] ?? ["pdf"],
                  areas: json["areas"] as? [String] ?? [])
```

In `ScanSettings` add two stored properties after `ocrLanguages` and extend the init:

```swift
    public var format: String
    /// The chosen scan area's id; nil for a scanner without areas.
    public var area: String?

    public init(source: Source, duplex: Bool, colorMode: ColorMode, resolution: Int, extras: [String: Bool],
                ocr: Bool = false, ocrLanguages: [String] = [], format: String = "pdf", area: String? = nil) {
        self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.extras = extras
        self.ocr = ocr; self.ocrLanguages = ocrLanguages
        self.format = format; self.area = area
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd macos && swift test --filter AreasTests 2>&1 | tail -6` then `scripts/test.sh 2>&1 | tail -3`
Expected: the new tests pass; the full suite passes (135 tests: 128 plus 7).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/Areas.swift macos/Sources/HelperCore/Model.swift macos/Tests/HelperCoreTests/AreasTests.swift
git commit -m "macOS helper: the Areas table, SizeMM, and formats/areas in the model"
```

---

### Task 4: The validator implements every photo rule

**Files:**
- Modify: `macos/Sources/HelperCore/ScanRequestValidator.swift`
- Test: `macos/Tests/HelperCoreTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `Areas`, `ScannerInfo.formats/areas/fullAreaMM`, `ScanSettings.format/area` (Task 3).
- Produces: `ScanRequestValidator.validate` returns settings with `format` and `area` (the first listed area when none is given, nil for a scanner without areas) and refuses per the Global Constraints.

- [ ] **Step 1: Write the failing tests.** Append to `macos/Tests/HelperCoreTests/ValidationTests.swift`:

```swift
private let photoScanner = ScannerInfo(
    id: "s:photo", name: "Photo Scanner", sources: [.flatbed, .feeder], duplex: false,
    colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600, 1200], extras: [],
    formats: ["pdf", "jpeg", "png"], areas: ["full", "a4", "10x15"], fullAreaMM: SizeMM(width: 216, height: 297))
private let photoOcrScanner = ScannerInfo(
    id: "s:photo-ocr", name: "Photo OCR Scanner", sources: [.flatbed], duplex: false, colorModes: [.color],
    resolutions: [300], extras: [], ocrLanguages: ["deu", "eng"], formats: ["pdf", "jpeg"], areas: ["a4"])
private let unknownGlass = ScannerInfo(
    id: "s:unknown", name: "Unknown Glass", sources: [.flatbed], duplex: false, colorModes: [.color],
    resolutions: [300, 1200], extras: [], formats: ["pdf", "jpeg"], areas: ["full"])

private func photo(_ body: [String: Any], scanners: [ScannerInfo]? = nil) throws -> ScanSettings {
    try ScanRequestValidator.validate(body, scanners: scanners ?? [photoScanner, photoOcrScanner, unknownGlass]).1
}

private func photoError(_ body: [String: Any]) -> ProtocolError? {
    do { _ = try photo(body); return nil } catch let error as ProtocolError { return error } catch { return nil }
}

@Test func aRequestWithoutFormatOrAreaGetsPdfAndTheFirstArea() throws {
    let settings = try photo(["scanner": "s:photo"])
    #expect(settings.format == "pdf" && settings.area == "full")
    let plain = try ScanRequestValidator.validate(["scanner": "fake:flatbed"], scanners: FakeScanners.infos).1
    #expect(plain.format == "pdf" && plain.area == nil)
}

@Test func anImageRequestIsAccepted() throws {
    let settings = try photo(["scanner": "s:photo", "format": "jpeg", "area": "10x15", "resolution": 1200])
    #expect(settings.format == "jpeg" && settings.area == "10x15" && settings.resolution == 1200)
    _ = try photo(["scanner": "s:photo", "format": "png", "colorMode": "bw", "area": "a4", "resolution": 600])
    _ = try photo(["scanner": "s:photo", "source": "feeder"])  // a PDF from the feeder is fine
}

@Test func unsupportedImageRequestsAre422WithTheirOwnMessages() {
    let cases: [([String: Any], String)] = [
        (["scanner": "s:photo", "format": "tiff"], "Photo Scanner can't make tiff files; it offers pdf, jpeg, png."),
        (["scanner": "s:photo", "area": "a5"], "Photo Scanner doesn't offer the area “a5”."),
        (["scanner": "s:photo", "format": "jpeg", "colorMode": "bw"], "JPEG can't be black and white; use PNG or PDF."),
        (["scanner": "s:photo", "format": "png", "source": "feeder"], "Images can only be scanned from the flatbed."),
        (["scanner": "s:photo", "format": "jpeg", "source": "feeder"], "Images can only be scanned from the flatbed."),
        (["scanner": "s:photo-ocr", "format": "jpeg", "ocr": true], "A searchable PDF can't be made from an image; scan to PDF instead."),
        (["scanner": "s:photo", "area": "a4", "resolution": 1200],
         "A4 at 1200 dpi is too large (139 megapixels; the limit is 100): choose a smaller area or a lower resolution."),
        (["scanner": "s:photo", "area": "full", "resolution": 1200],
         "The whole glass at 1200 dpi is too large (143 megapixels; the limit is 100): choose a smaller area or a lower resolution."),
        (["scanner": "fake:flatbed", "format": "jpeg"], "Fake Flatbed can't make jpeg files; it offers pdf."),
    ]
    for (body, message) in cases {
        let scanners = body["scanner"] as? String == "fake:flatbed" ? FakeScanners.infos : [photoScanner, photoOcrScanner]
        do {
            _ = try ScanRequestValidator.validate(body, scanners: scanners)
            Issue.record("accepted: \(body)")
        } catch let error as ProtocolError {
            #expect(error.status == 422 && error.message == message, "\(body): \(error.message)")
        } catch {
            Issue.record("unexpected error for \(body)")
        }
    }
}

@Test func anAreaWhoseSizeIsUnknownSkipsTheLimitCheck() throws {
    let settings = try photo(["scanner": "s:unknown", "format": "jpeg", "area": "full", "resolution": 1200])
    #expect(settings.area == "full")
}

@Test func theSizeLimitCountsTheScannersRealGlassForFull() throws {
    _ = try photo(["scanner": "s:photo", "area": "full", "resolution": 600])  // 36 megapixels: fine
}

@Test func wrongTypesAre400BeforeAnyPhoto422() {
    #expect(photoError(["scanner": "s:photo", "area": 5, "format": "jpeg", "colorMode": "bw"])?.status == 400)
    #expect(photoError(["scanner": "s:photo", "format": ["jpeg"], "area": "a5"])?.status == 400)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter ValidationTests 2>&1 | tail -12`
Expected: the new tests FAIL (the old validator refuses every non-pdf format and every area).

- [ ] **Step 3: Implement.** In `macos/Sources/HelperCore/ScanRequestValidator.swift`, replace the block

```swift
        let format = object["format"] as? String ?? "pdf"
        guard format == "pdf" else {
            throw ProtocolError(422, "Format “\(format)” isn't supported; use pdf.")
        }
        if object["area"] != nil {  // no scanner of this helper has scan areas
            throw ProtocolError(422, "\(scanner.name) has no scan areas.")
        }
```

with

```swift
        let format = object["format"] as? String ?? "pdf"
        guard scanner.formats.contains(format) else {
            throw ProtocolError(422, "\(scanner.name) can't make \(format) files; it offers \(scanner.formats.joined(separator: ", ")).")
        }
        if object["area"] != nil && scanner.areas.isEmpty {
            throw ProtocolError(422, "\(scanner.name) has no scan areas.")
        }
        let area = object["area"] as? String ?? scanner.areas.first
        if let area, !scanner.areas.contains(area) {
            throw ProtocolError(422, "\(scanner.name) doesn't offer the area “\(area)”.")
        }
        if format == "jpeg" && colorMode == .bw {
            throw ProtocolError(422, "JPEG can't be black and white; use PNG or PDF.")
        }
        if format != "pdf" && source == .feeder {
            throw ProtocolError(422, "Images can only be scanned from the flatbed.")
        }
```

Directly after the line `let ocr = JSONBody.bool(object["ocr"]) ?? false` insert:

```swift
        if ocr && format != "pdf" {
            throw ProtocolError(422, "A searchable PDF can't be made from an image; scan to PDF instead.")
        }
```

Immediately before the final `return (scanner, ScanSettings(...))` insert the size check:

```swift
        if let area {
            let size: SizeMM? = area == Areas.full
                ? scanner.fullAreaMM
                : Areas.named(area).map { SizeMM(width: $0.widthMM, height: $0.heightMM) }
            if let size {
                let pixels = Areas.pixelCount(widthMM: size.width, heightMM: size.height, dpi: resolution)
                if Areas.isOverLimit(pixels) {
                    let label = area == Areas.full ? "The whole glass" : (Areas.named(area)?.label ?? area)
                    let megapixels = Int((Double(pixels) / 1_000_000).rounded())
                    throw ProtocolError(422, "\(label) at \(resolution) dpi is too large (\(megapixels) megapixels; "
                        + "the limit is \(Areas.maxPixels / 1_000_000)): choose a smaller area or a lower resolution.")
                }
            }
        }
```

and change the returned settings to carry the new fields:

```swift
        return (scanner, ScanSettings(source: source, duplex: duplex, colorMode: colorMode,
                                      resolution: resolution, extras: extras,
                                      ocr: ocr, ocrLanguages: ocr ? ocrLanguages : [],
                                      format: format, area: area))
```

- [ ] **Step 4: Run the tests**

Run: `cd macos && scripts/test.sh 2>&1 | tail -4`
Expected: all pass (the earlier `areaMustBeText` / `anyAreaIs422` tests still pass: scanners without areas keep refusing `area`).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/ScanRequestValidator.swift macos/Tests/HelperCoreTests/ValidationTests.swift
git commit -m "macOS helper: the validator implements image formats, areas and the size limit"
```

---

### Task 5: Capability mapping: local flatbeds list images and areas, plus two pure helpers

**Files:**
- Modify: `macos/Sources/HelperCore/CapabilityMapping.swift`
- Test: `macos/Tests/HelperCoreTests/CapabilityMappingTests.swift`

**Interfaces:**
- Consumes: `Areas`, `SizeMM`, `ScannerInfo` fields (Task 3).
- Produces:
  - `UnitCapabilities.physicalSizeMM: SizeMM?` (new last init parameter, default nil)
  - `CapabilityMapping.scannerInfo(...)`: a scanner with a flatbed unit gets `formats ["pdf","jpeg","png"]`, `areas ["full"] + Areas.fitting(flatbed size)` (just `["full"]` when the size is unknown), `fullAreaMM` = the flatbed's size; a feeder-only scanner gets neither
  - `CapabilityMapping.documentType(format: String, colorMode: ColorMode) -> UTType`
  - `CapabilityMapping.scanAreaInches(area: String?, glass: (width: Double, height: Double)) -> (width: Double, height: Double)`

- [ ] **Step 1: Write the failing tests.** Append to `macos/Tests/HelperCoreTests/CapabilityMappingTests.swift` (add `import UniformTypeIdentifiers` at the top):

```swift
@Test func aFlatbedListsImagesAndTheAreasThatFit() throws {
    let a4Glass = SizeMM(width: 215.9, height: 297.2)
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p1", name: "HP", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [1, 8], resolutions: continuous,
                         preferredResolutions: [300], physicalSizeMM: a4Glass),
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [150, 300, 600],
                         preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf", "jpeg", "png"])
    #expect(info.areas == ["full", "a4", "a5", "a6", "10x15", "13x18"])
    #expect(info.fullAreaMM == a4Glass)
}

@Test func letterGlassHasNoA4() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p2", name: "US", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [300],
                         preferredResolutions: [], physicalSizeMM: SizeMM(width: 215.9, height: 279.4)),
    ]))
    #expect(info.areas == ["full", "a5", "a6", "10x15", "13x18"])
}

@Test func aFlatbedWithoutASizeListsOnlyFull() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p3", name: "Odd", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [300], preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf", "jpeg", "png"] && info.areas == ["full"] && info.fullAreaMM == nil)
}

@Test func aFeederOnlyScannerStaysPdfOnly() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:p4", name: "Sheet", units: [
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [300], preferredResolutions: []),
    ]))
    #expect(info.formats == ["pdf"] && info.areas.isEmpty && info.fullAreaMM == nil)
    #expect(info.json["formats"] == nil && info.json["areas"] == nil)
}

@Test func theFileTypeFollowsTheFormat() {
    #expect(CapabilityMapping.documentType(format: "jpeg", colorMode: .gray) == .jpeg)
    #expect(CapabilityMapping.documentType(format: "png", colorMode: .color) == .png)
    #expect(CapabilityMapping.documentType(format: "pdf", colorMode: .color) == .jpeg)  // pages for the PDF
    #expect(CapabilityMapping.documentType(format: "pdf", colorMode: .bw) == .png)      // JPEG can't hold 1-bit
}

@Test func theScanAreaInInches() {
    let glass = (width: 8.5, height: 11.69)
    #expect(CapabilityMapping.scanAreaInches(area: nil, glass: glass) == glass)
    #expect(CapabilityMapping.scanAreaInches(area: "full", glass: glass) == glass)
    let photo = CapabilityMapping.scanAreaInches(area: "10x15", glass: glass)
    #expect(abs(photo.width - 100 / 25.4) < 1e-9 && abs(photo.height - 150 / 25.4) < 1e-9)
    // An area bigger than the glass is clamped to it.
    let small = (width: 4.0, height: 5.0)
    #expect(CapabilityMapping.scanAreaInches(area: "a4", glass: small) == small)
    #expect(CapabilityMapping.scanAreaInches(area: "unknown", glass: glass) == glass)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter CapabilityMappingTests 2>&1 | tail -10`
Expected: build error (`extra argument 'physicalSizeMM'`).

- [ ] **Step 3: Implement.** In `macos/Sources/HelperCore/CapabilityMapping.swift`: add `import UniformTypeIdentifiers` below `import Foundation`; in `UnitCapabilities` add `public var physicalSizeMM: SizeMM?` and change its init to

```swift
    public init(source: Source, duplex: Bool, bitDepths: [Int], resolutions: [Int], preferredResolutions: [Int],
                physicalSizeMM: SizeMM? = nil) {
        self.source = source; self.duplex = duplex; self.bitDepths = bitDepths
        self.resolutions = resolutions; self.preferredResolutions = preferredResolutions
        self.physicalSizeMM = physicalSizeMM
    }
```

In `scannerInfo`, replace the final `return ScannerInfo(...)` with:

```swift
        let flatbed = units.first { $0.source == .flatbed }
        var formats = ["pdf"]
        var areas: [String] = []
        if let flatbed {
            formats = ["pdf", "jpeg", "png"]
            areas = [Areas.full]
            if let size = flatbed.physicalSizeMM {
                areas += Areas.fitting(widthMM: size.width, heightMM: size.height)
            }
        }
        return ScannerInfo(id: id, name: name, sources: ordered.map(\.source),
                           duplex: ordered.first { $0.source == .feeder }?.duplex ?? false,
                           colorModes: colorModes, resolutions: resolutions, extras: [],
                           formats: formats, areas: areas, fullAreaMM: flatbed?.physicalSizeMM)
```

and add these two functions inside `CapabilityMapping`:

```swift
    /// The file type Image Capture writes for a scan: the requested image format, or for a PDF scan JPEG
    /// pages (PNG for black & white, which JPEG can't hold).
    public static func documentType(format: String, colorMode: ColorMode) -> UTType {
        switch format {
        case "png": return .png
        case "jpeg": return .jpeg
        default: return colorMode == .bw ? .png : .jpeg
        }
    }

    /// The scan area in inches for a flatbed whose glass is `glass` inches: `full`, no area or an unknown id
    /// is the whole glass; a fixed area is clamped to the glass.
    public static func scanAreaInches(area: String?, glass: (width: Double, height: Double))
        -> (width: Double, height: Double) {
        guard let area, area != Areas.full, let named = Areas.named(area) else { return glass }
        return (min(named.widthMM / 25.4, glass.width), min(named.heightMM / 25.4, glass.height))
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd macos && scripts/test.sh 2>&1 | tail -4`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/CapabilityMapping.swift macos/Tests/HelperCoreTests/CapabilityMappingTests.swift
git commit -m "macOS helper: local flatbeds list images and areas; document type and scan area helpers"
```

---

### Task 6: The image result, the response and `ImageEncoding.normalized`

**Files:**
- Modify: `macos/Sources/HelperCore/ScannerBackend.swift` (`ScanDocuments`, new `ImageFile`)
- Modify: `macos/Sources/HelperCore/ScanResponse.swift`
- Modify: `macos/Sources/HelperCore/FakePages.swift` (`ImageEncoding`)
- Create: `macos/Tests/HelperCoreTests/ImageResultTests.swift`

**Interfaces:**
- Produces:
  - `ImageFile(data: Data, format: String)` (`Sendable`; `format` is `"jpeg"` or `"png"`); `ScanDocuments.image: ImageFile?` (new last init parameter, default nil)
  - `ScanResponse.imagesMessage(_ count: Int) -> String`; `ScanResponse.File.pageCount`; `ScanResponse.files(result, date:)` returns one file named `scan_<stamp>.jpg` or `.png` with `pageCount` 1 for an image result; `payload` uses `pageCount` and answers `"1 image scanned."`
  - `ImageEncoding.png(_ image: CGImage) -> Data`; `ImageEncoding.normalized(_ data: Data, as format: String, dpi: Int) throws -> Data`

- [ ] **Step 1: Write the failing tests.** Create `macos/Tests/HelperCoreTests/ImageResultTests.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HelperCore

private let stamp = Date(timeIntervalSince1970: 1_761_300_000)

@Test func anImageResultIsOneFileWithOnePageAndAnImagesMessage() throws {
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let result = ScanDocuments(documents: [], partialMessage: nil, image: ImageFile(data: bytes, format: "jpeg"))
    let payload = try ScanResponse.payload(result, date: stamp)
    #expect(payload["ok"] as? Bool == true && payload["partial"] as? Bool == false)
    #expect(payload["message"] as? String == "1 image scanned.")
    let files = try #require(payload["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files[0]["pages"] as? Int == 1)
    #expect((files[0]["name"] as? String)?.hasPrefix("scan_") == true && (files[0]["name"] as? String)?.hasSuffix(".jpg") == true)
    #expect(files[0]["data"] as? String == bytes.base64EncodedString())
    #expect(files[0]["ocrJob"] == nil)
}

@Test func aPngResultIsNamedPng() throws {
    let result = ScanDocuments(documents: [], partialMessage: nil, image: ImageFile(data: Data([0x89, 0x50]), format: "png"))
    let files = try #require(try ScanResponse.payload(result, date: stamp)["files"] as? [[String: Any]])
    #expect((files[0]["name"] as? String)?.hasSuffix(".png") == true)
}

@Test func pdfResultsKeepTheirPageCountMessage() throws {
    let pages = try ["One", "Two"].map(FakePages.render)
    let payload = try ScanResponse.payload(ScanDocuments(documents: [pages], partialMessage: nil), date: stamp)
    #expect(payload["message"] as? String == "2 pages scanned.")
    #expect((payload["files"] as? [[String: Any]])?.first?["pages"] as? Int == 2)
    #expect(ScanResponse.imagesMessage(1) == "1 image scanned." && ScanResponse.imagesMessage(3) == "3 images scanned.")
}

private func sample() -> CGImage {
    let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
    return context.makeImage()!
}

private func inspect(_ data: Data) -> (type: String?, dpi: Double?, width: Int?) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return (CGImageSourceGetType(source) as String?, properties?[kCGImagePropertyDPIWidth] as? Double,
            properties?[kCGImagePropertyPixelWidth] as? Int)
}

@Test func aJpegWithTheWrongDpiGetsTheRequestedOne() throws {
    let plain = try ImageEncoding.jpeg(sample())
    let fixed = try ImageEncoding.normalized(plain, as: "jpeg", dpi: 600)
    let info = inspect(fixed)
    #expect(info.type == UTType.jpeg.identifier && info.width == 20)
    #expect(abs((info.dpi ?? 0) - 600) < 1)
}

@Test func aFileOfTheWrongTypeIsReencoded() throws {
    let png = ImageEncoding.png(sample())
    #expect(inspect(png).type == UTType.png.identifier)
    let jpeg = try ImageEncoding.normalized(png, as: "jpeg", dpi: 300)
    #expect(inspect(jpeg).type == UTType.jpeg.identifier && inspect(jpeg).width == 20)
    let back = try ImageEncoding.normalized(jpeg, as: "png", dpi: 300)
    #expect(inspect(back).type == UTType.png.identifier)
}

@Test func aFileThatIsAlreadyRightIsReturnedUnchanged() throws {
    let once = try ImageEncoding.normalized(try ImageEncoding.jpeg(sample()), as: "jpeg", dpi: 300)
    let twice = try ImageEncoding.normalized(once, as: "jpeg", dpi: 300)
    #expect(once == twice)
}

@Test func unreadableBytesAre500() {
    #expect(throws: ProtocolError.self) { try ImageEncoding.normalized(Data([1, 2, 3]), as: "jpeg", dpi: 300) }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter ImageResultTests 2>&1 | tail -10`
Expected: build error (`extra argument 'image'`, `cannot find 'ImageFile'`).

- [ ] **Step 3: Implement.** In `macos/Sources/HelperCore/ScannerBackend.swift` add above `ScanDocuments`:

```swift
/// A finished image scan: the file's bytes as scanned, `format` being "jpeg" or "png".
public struct ImageFile: Sendable {
    public let data: Data
    public let format: String
    public init(data: Data, format: String) { self.data = data; self.format = format }
}
```

and in `ScanDocuments` add `/// An image scan (one JPEG or PNG file instead of pages for a PDF).` + `public var image: ImageFile?` and extend the init:

```swift
    public init(documents: [[PageImage]], partialMessage: String?, pdfs: [Data]? = nil, fakeTexts: [[String]]? = nil,
                image: ImageFile? = nil) {
        self.documents = documents; self.partialMessage = partialMessage; self.pdfs = pdfs; self.fakeTexts = fakeTexts
        self.image = image
    }
```

In `macos/Sources/HelperCore/ScanResponse.swift`: add `public let pageCount: Int` to `File` (last property; update the doc comment of `pdf` to "the file's bytes: a PDF, or a JPEG/PNG for an image scan"); add

```swift
    public static func imagesMessage(_ count: Int) -> String {
        count == 1 ? "1 image scanned." : "\(count) images scanned."
    }
```

and restructure `files(_:date:)` so that the date formatter comes first and an image result is handled before the page lists:

```swift
    public static func files(_ result: ScanDocuments, date: Date) throws -> [File] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        if let image = result.image {
            let name = "scan_\(stamp).\(image.format == "png" ? "png" : "jpg")"
            return [File(name: name, pages: [], pdf: image.data, fakeTexts: nil, pageCount: 1)]
        }
        let kept = result.documents.indices.filter { !result.documents[$0].isEmpty }
        guard !kept.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        return try kept.enumerated().map { position, index in
            let pages = result.documents[index]
            let name = kept.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(position + 1).pdf"
            let pdf = try result.pdfs?[safe: index] ?? PdfBuilder.makePdf(pages)
            return File(name: name, pages: pages, pdf: pdf, fakeTexts: result.fakeTexts?[safe: index],
                        pageCount: pages.count)
        }
    }
```

in `payload`, use the page count and the right message:

```swift
            var entry: [String: Any] = ["name": file.name, "pages": file.pageCount,
                                        "data": file.pdf.base64EncodedString()]
            ...
        let total = files.reduce(0) { $0 + $1.pageCount }
        let partial = result.partialMessage != nil
        let message = result.image != nil ? imagesMessage(files.count) : pagesMessage(total)
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? message, "files": entries]
```

In `macos/Sources/HelperCore/FakePages.swift`, inside `enum ImageEncoding` add (the file already imports ImageIO, CoreGraphics and UniformTypeIdentifiers):

```swift
    public static func png(_ image: CGImage) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// The scanned file as `format` ("jpeg" or "png") with the dpi set: returned unchanged when it already is
    /// that type and carries that dpi, re-encoded with ImageIO otherwise (some drivers ignore the requested file type).
    public static func normalized(_ data: Data, as format: String, dpi: Int) throws -> Data {
        let type = format == "png" ? UTType.png : UTType.jpeg
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProtocolError(500, "Couldn't read the scanned image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasRightDPI = abs((properties?[kCGImagePropertyDPIWidth] as? Double ?? 0) - Double(dpi)) < 1
        if (CGImageSourceGetType(source) as String?) == type.identifier && hasRightDPI { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ProtocolError(500, "Couldn't encode the scanned image.")
        }
        var options: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format != "png" { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProtocolError(500, "Couldn't encode the scanned image.") }
        return output as Data
    }
```

If ImageIO does not report a dpi for a re-encoded JPEG in `aJpegWithoutADpiGetsOne` (the test reads `kCGImagePropertyDPIWidth`), keep the behaviour but fix the encoder: for JPEG also pass `kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFXDensity: dpi, kCGImagePropertyJFIFYDensity: dpi, kCGImagePropertyJFIFIsProgressive: false]` and report that you did.

- [ ] **Step 4: Run the tests**

Run: `cd macos && scripts/test.sh 2>&1 | tail -4`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/ScannerBackend.swift macos/Sources/HelperCore/ScanResponse.swift macos/Sources/HelperCore/FakePages.swift macos/Tests/HelperCoreTests/ImageResultTests.swift
git commit -m "macOS helper: the image result, its response, and ImageEncoding.normalized"
```

---

### Task 7: Fake mode serves `fake:photo`

**Files:**
- Modify: `macos/Sources/HelperCore/FakeScanners.swift`, `macos/Sources/HelperCore/FakeBackend.swift`, `macos/Sources/HelperCore/FakePages.swift`
- Test: `macos/Tests/HelperCoreTests/FakeScanTests.swift`, `macos/Tests/HelperCoreTests/RouterTests.swift`

**Interfaces:**
- Consumes: `ScannerInfo` fields (Task 3), `ImageFile` and `ImageEncoding.png` (Task 6), the validator (Task 4).
- Produces: `fake:photo` last in `FakeScanners.all` ("Fake Photo Scanner", flatbed, color/gray/bw, resolutions 150/300/600/1200, formats pdf/jpeg/png, areas a4/10x15); `FakePages.image(_ format: String) throws -> Data`; a `fake:photo` image scan returns one tiny JPEG or PNG.

- [ ] **Step 1: Write the failing tests.** In `macos/Tests/HelperCoreTests/RouterTests.swift` change `#expect(list?.count == 8)` to `#expect(list?.count == 9)`. Append to `macos/Tests/HelperCoreTests/FakeScanTests.swift`:

```swift
@Test func thePhotoScannerComesLastWithItsFormatsAndAreas() throws {
    let infos = FakeScanners.infos
    #expect(infos.map(\.id).last == "fake:photo")
    let photo = try #require(infos.last)
    #expect(photo.name == "Fake Photo Scanner" && photo.sources == [.flatbed] && !photo.duplex)
    #expect(photo.resolutions == [150, 300, 600, 1200])
    #expect(photo.formats == ["pdf", "jpeg", "png"] && photo.areas == ["a4", "10x15"])
    #expect(photo.ocrLanguages.isEmpty && photo.extras.isEmpty)
    #expect(infos.dropLast().allSatisfy { $0.formats == ["pdf"] && $0.areas.isEmpty })
}

@Test(arguments: [("jpeg", Data([0xFF, 0xD8, 0xFF])), ("png", Data([0x89, 0x50, 0x4E, 0x47]))])
func aPhotoScanReturnsOneTinyImage(format: String, signature: Data) async throws {
    let backend = FakeBackend()
    let settings = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 600, extras: [:],
                                format: format, area: "10x15")
    let result = try await backend.scan(scannerID: "fake:photo", settings: settings)
    let image = try #require(result.image)
    #expect(image.format == format && image.data.prefix(signature.count) == signature)
    #expect(result.documents.isEmpty && result.partialMessage == nil)
    let payload = try ScanResponse.payload(result, date: Date())
    #expect(payload["message"] as? String == "1 image scanned.")
}

@Test func aPhotoScannerPdfScanStillMakesAPdf() async throws {
    let settings = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 150, extras: [:],
                                area: "a4")
    let result = try await FakeBackend().scan(scannerID: "fake:photo", settings: settings)
    #expect(result.image == nil && result.documents.map(\.count) == [1])
}

@Test func theRouterAnswersAnImageScanAndTheRefusals() async throws {
    let (router, token) = try await photoRouter()
    let scan = await router.handle(photoRequest(token, #"{"scanner":"fake:photo","format":"jpeg","area":"10x15","resolution":1200}"#))
    #expect(scan.status == 200)
    let files = try #require(photoObject(scan)["files"] as? [[String: Any]])
    #expect(files.count == 1 && files[0]["pages"] as? Int == 1 && (files[0]["name"] as? String)?.hasSuffix(".jpg") == true)
    for body in [#"{"scanner":"fake:photo","area":"a4","resolution":1200}"#,
                 #"{"scanner":"fake:photo","format":"jpeg","colorMode":"bw"}"#,
                 #"{"scanner":"fake:photo","format":"png","ocr":true}"#,
                 #"{"scanner":"fake:flatbed","format":"jpeg"}"#,
                 #"{"scanner":"fake:flatbed","area":"a4"}"#] {
        #expect(await router.handle(photoRequest(token, body)).status == 422, "\(body)")
    }
    #expect(await router.handle(photoRequest(token, #"{"scanner":"fake:photo","area":5}"#)).status == 400)
}
```

and add, before that last test in the same file, these three helpers (the same style as the private helpers at the top of `RouterTests.swift`):

```swift
private func photoRouter() async throws -> (Router, String) {
    let pairing = PairingStore(mode: .fake)
    let token = try pairing.pair(code: "000000", client: nil)
    return (Router(backend: FakeBackend(), pairing: pairing), token)
}

private func photoRequest(_ token: String, _ body: String) -> HTTPRequest {
    HTTPRequest(method: "POST", path: "/scan", headers: ["Authorization": "Bearer \(token)"],
                body: Data(body.utf8), bodyError: nil)
}

private func photoObject(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter FakeScanTests 2>&1 | tail -10`
Expected: FAIL (no `fake:photo`).

- [ ] **Step 3: Implement.** In `macos/Sources/HelperCore/FakeScanners.swift` extend `make` with three parameters and pass them on:

```swift
    private static func make(_ id: String, _ name: String, _ sources: [Source], duplex: Bool = false,
                             extras: [String] = [], sheets: [String] = [], delay: TimeInterval = 0,
                             offline: Bool = false, jamAfter: Int? = nil, empty: Bool = false, ocr: [String] = [],
                             resolutions: [Int] = [150, 300, 600], formats: [String] = ["pdf"],
                             areas: [String] = []) -> FakeScanner {
        FakeScanner(info: ScannerInfo(id: id, name: name, sources: sources, duplex: duplex,
                                      colorModes: [.color, .gray, .bw], resolutions: resolutions, extras: extras,
                                      ocrLanguages: ocr, formats: formats, areas: areas),
                    sheets: sheets, delay: delay, offline: offline, jamAfter: jamAfter, empty: empty)
    }
```

and append to `all` (after the `fake:ocr` line):

```swift
        make("fake:photo", "Fake Photo Scanner", [.flatbed], resolutions: [150, 300, 600, 1200],
             formats: ["pdf", "jpeg", "png"], areas: ["a4", "10x15"]),
```

In `macos/Sources/HelperCore/FakePages.swift` add to `enum FakePages`:

```swift
    /// A tiny valid 8 x 8 gray JPEG or PNG: the fake photo scanner's scan.
    public static func image(_ format: String) throws -> Data {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ProtocolError(500, "Couldn't draw an image.")
        }
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else { throw ProtocolError(500, "Couldn't draw an image.") }
        return format == "png" ? ImageEncoding.png(image) : try ImageEncoding.jpeg(image)
    }
```

In `macos/Sources/HelperCore/FakeBackend.swift`, in `scan`, directly after the `if fake.empty { throw ... }` line add:

```swift
        if settings.format != "pdf" {
            return ScanDocuments(documents: [], partialMessage: nil,
                                 image: ImageFile(data: try FakePages.image(settings.format), format: settings.format))
        }
```

- [ ] **Step 4: Run the tests and the conformance suite**

Run: `cd macos && scripts/test.sh 2>&1 | tail -4` (expected: all pass). Then, from `macos/`: `PORT=8799 scripts/run-conformance.sh 2>&1 | grep -E "^Ran|^OK|FAIL|skipped"` (**never the default port**). Expected: `Ran 58 tests ... OK` with **no skipped tests** (`PhotoTests` now run against the macOS helper's fake mode, and the unconditional refusal tests still pass). Confirm nothing is left listening on 8799.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/FakeScanners.swift macos/Sources/HelperCore/FakeBackend.swift macos/Sources/HelperCore/FakePages.swift macos/Tests/HelperCoreTests
git commit -m "macOS helper: fake mode serves fake:photo; the conformance photo tests run on macOS"
```

---

### Task 8: Remote scanners forward `format` and `area`

**Files:**
- Modify: `macos/Sources/HelperCore/RemoteScanners.swift`
- Test: `macos/Tests/HelperCoreTests/RemoteScannersTests.swift`, `macos/Tests/HelperCoreTests/RemoteTestSupport.swift`

**Interfaces:**
- Consumes: `ScanSettings.format/area`, `ScannerInfo(json:)` reading `formats`/`areas` (Task 3).
- Produces: the forwarded `POST /scan` body carries `format` (only when it isn't `"pdf"`) and `area` (only when set).

- [ ] **Step 1: Write the failing tests.** In `macos/Tests/HelperCoreTests/RemoteTestSupport.swift` add below `piScanner`:

```swift
let piPhotoScanner: [String: Any] = ["id": "sane:canoscan-8800f", "name": "Canon CanoScan 8800F", "sources": ["flatbed"],
                                     "duplex": false, "colorModes": ["color", "gray", "bw"],
                                     "resolutions": [150, 300, 600, 1200], "extras": [],
                                     "formats": ["pdf", "jpeg", "png"], "areas": ["a4", "a5", "a6", "10x15", "13x18"]]
```

Append to `macos/Tests/HelperCoreTests/RemoteScannersTests.swift`:

```swift
@Test func theListingKeepsTheServersFormatsAndAreas() async {
    let (store, server) = pairedStore()
    let transport = FakeTransport { _ in (200, ["scanners": [piScanner, piPhotoScanner]]) }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    let list = await remote.listScanners()
    let photo = list.first { $0.id == "remote:\(server.id):sane:canoscan-8800f" }
    #expect(photo?.name == "Canon CanoScan 8800F (scanner)")
    #expect(photo?.formats == ["pdf", "jpeg", "png"] && photo?.areas == ["a4", "a5", "a6", "10x15", "13x18"])
    let ix500 = list.first { $0.id == "remote:\(server.id):sane:ix500" }
    #expect(ix500?.formats == ["pdf"] && ix500?.areas.isEmpty == true)
}

@Test func aPhotoScanForwardsItsFormatAndArea() async throws {
    let (store, server) = pairedStore()
    let transport = FakeTransport { _ in
        (200, ["ok": true, "partial": false, "message": "1 image scanned.",
               "files": [["name": "scan_1.jpg", "pages": 1, "data": "/9j/"]]])
    }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    let photo = ScanSettings(source: .flatbed, duplex: false, colorMode: .color, resolution: 1200, extras: [:],
                             format: "jpeg", area: "10x15")
    let (status, body) = try await remote.scan(scannerID: "remote:\(server.id):sane:canoscan-8800f", settings: photo)
    #expect(status == 200)
    let file = (body["files"] as? [[String: Any]])?.first
    #expect(file?["name"] as? String == "scan_1.jpg" && file?["pages"] as? Int == 1 && file?["ocrJob"] == nil)
    let sent = try #require(transport.sent.first)
    let forwarded = try #require((try? JSONSerialization.jsonObject(with: sent.body ?? Data())) as? [String: Any])
    #expect(forwarded["scanner"] as? String == "sane:canoscan-8800f")
    #expect(forwarded["format"] as? String == "jpeg" && forwarded["area"] as? String == "10x15")
    #expect(forwarded["resolution"] as? Int == 1200)
}

@Test func aPdfScanForwardsNoFormatAndOnlyAnAreaThatWasSet() async throws {
    let (store, server) = pairedStore()
    let transport = FakeTransport { _ in (200, ["ok": true, "partial": false, "message": "1 page scanned.", "files": []]) }
    let remote = RemoteScanners(store: store, transport: { _ in transport })
    let plain = ScanSettings(source: .feeder, duplex: false, colorMode: .color, resolution: 300, extras: [:])
    _ = try await remote.scan(scannerID: "remote:\(server.id):sane:ix500", settings: plain)
    let forwarded = try #require((try? JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data())) as? [String: Any])
    #expect(forwarded["format"] == nil && forwarded["area"] == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd macos && swift test --filter RemoteScannersTests 2>&1 | tail -10`
Expected: `aPhotoScanForwardsItsFormatAndArea` FAILS (`format` is nil in the forwarded body).

- [ ] **Step 3: Implement.** In `RemoteScanners.scan`, directly after the line `if settings.ocr { body["ocr"] = true; body["ocrLanguages"] = settings.ocrLanguages }` add:

```swift
        if settings.format != "pdf" { body["format"] = settings.format }
        if let area = settings.area { body["area"] = area }
```

- [ ] **Step 4: Run the tests**

Run: `cd macos && scripts/test.sh 2>&1 | tail -4`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/RemoteScanners.swift macos/Tests/HelperCoreTests
git commit -m "macOS helper: remote scans forward format and area"
```

---

### Task 9: Image Capture: the area, the file type and the image result (hardware code)

**Files:**
- Modify: `macos/Sources/HelperCore/ImageCaptureBackend.swift`

**Interfaces:**
- Consumes: `UnitCapabilities.physicalSizeMM`, `CapabilityMapping.documentType`, `CapabilityMapping.scanAreaInches` (Task 5); `ImageFile`, `ImageEncoding.normalized` (Task 6); `ScanSettings.format/area` (Task 3).
- Produces: local flatbeds report their glass size; a flatbed scan uses the chosen area; an image scan writes the requested file type and returns the normalized file as an `ImageFile`.

This is Image Capture code: it is **not** unit tested and **must not be run by the implementer** (no real scanner here); the controller verifies it on real scanners (Task 11). The pure parts it uses are already tested.

- [ ] **Step 1: The glass size in `probe`.** In `probe`, inside the loop over unit types, replace the `units.append(UnitCapabilities(...))` call with:

```swift
                unit.measurementUnit = .inches
                let glass = unit.physicalSize
                units.append(UnitCapabilities(
                    source: type == .documentFeeder ? .feeder : .flatbed,
                    duplex: (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false,
                    bitDepths: Array(unit.supportedBitDepths), resolutions: Array(unit.supportedResolutions),
                    preferredResolutions: Array(unit.preferredResolutions),
                    physicalSizeMM: type == .flatbed && glass.width > 0 && glass.height > 0
                        ? SizeMM(width: glass.width * 25.4, height: glass.height * 25.4) : nil))
```

and extend the `log("Found ...")` line to end with `, \(info.formats.joined(separator: "/")) formats.` (so the log shows what was offered).

- [ ] **Step 2: The file type.** In `performScan`, replace

```swift
        device.documentUTI = (settings.colorMode == .bw ? UTType.png : UTType.jpeg).identifier
```

with

```swift
        device.documentUTI = CapabilityMapping.documentType(format: settings.format, colorMode: settings.colorMode).identifier
```

- [ ] **Step 3: The scan area.** In `configure`, replace the `else` branch (the flatbed one) with:

```swift
        } else {
            let glass = unit.physicalSize
            let area = CapabilityMapping.scanAreaInches(area: settings.area,
                                                        glass: (width: glass.width, height: glass.height))
            unit.scanArea = NSRect(x: 0, y: 0, width: area.width, height: area.height)
        }
```

(`unit.measurementUnit = .inches` is already set at the top of `configure`, so both numbers are inches.)

- [ ] **Step 4: The image result.** In `performScan`, directly after `let (urls, error) = try await runScan(device, id: id)` insert:

```swift
        if settings.format != "pdf" {
            guard let url = urls.first else {
                throw ProtocolError(500, error.map { "The scan failed: \($0.localizedDescription)" } ?? "The scanner returned no image.")
            }
            let data = try ImageEncoding.normalized(try Data(contentsOf: url), as: settings.format, dpi: settings.resolution)
            return ScanDocuments(documents: [], partialMessage: nil, image: ImageFile(data: data, format: settings.format))
        }
```

- [ ] **Step 5: Build and run the tests**

Run: `cd macos && swift build 2>&1 | tail -4 && scripts/test.sh 2>&1 | tail -3`
Expected: the build succeeds without warnings from your changes and all tests pass. Do NOT run the app or any scan.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/HelperCore/ImageCaptureBackend.swift
git commit -m "macOS helper: Image Capture scans the chosen area and returns image files"
```

---

### Task 10: Docs and version 0.5.0

**Files:**
- Modify: `macos/Sources/HelperCore/Version.swift`, `macos/README.md`, `README.md`, `docs/manual-check-macos.md`

- [ ] **Step 1: Version.** Set `public static let string = "0.5.0"` in `macos/Sources/HelperCore/Version.swift`. Grep `macos/Tests` and the docs for `0.4.1`; report any other occurrence (the `/health` test may build its expectation from `HelperVersion.string`).

- [ ] **Step 2: READMEs.** In `README.md` (the table row for `macos/` or the macOS helper description) and in `macos/README.md` ("what it does" or its capability section) add this paragraph (adapt the heading level to the file):

```markdown
**Photos.** A scanner that has a flatbed can scan to JPEG or PNG (`format`) over a chosen area
(`area`): local scanners offer `full` (the whole glass, the default) and the standard areas that fit
(`a4`, `a5`, `a6`, `10x15`, `13x18`), and the Pi's scanners show the formats and areas their server
offers. Images come only from the flatbed (the feeder is PDF only), JPEG can't be black & white,
images are not made searchable, and a scan over 100 megapixels is refused with a message saying what
to change. The protocol text is in `PROTOCOL.md` ("Formats and areas").
```

- [ ] **Step 3: The hardware checklist.** Append to `docs/manual-check-macos.md` a section "Photo scans (0.5.0)" with these items as a checklist: on a local flatbed (Canon MF650C): `GET /scanners` lists `formats` and `areas` (`full` first); a JPEG and a PNG scan at `full`, `10x15` and `a5` give images of the expected pixel size (width mm / 25.4 * dpi); a print placed against the glass's corner mark appears flush at the top-left of the `10x15` image; a black & white PNG is 1-bit; a PDF scan from the flatbed and from the feeder is unchanged; an image request from the feeder gets the 422 "Images can only be scanned from the flatbed."; through the helper to the Pi: the 8800F lists its formats and areas and a `10x15` JPEG scan comes back (use a build on a free port, not the installed helper on 8766).

- [ ] **Step 4: Run everything**

Run: `cd macos && scripts/test.sh 2>&1 | tail -3`, `cd reference && python3 -m unittest discover -s tests 2>&1 | tail -3`, and `cd macos && PORT=8799 scripts/run-conformance.sh 2>&1 | grep -E "^Ran|^OK|FAIL|skipped"`. Expected: all pass; conformance 58 tests, none skipped.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/Version.swift macos/README.md README.md docs/manual-check-macos.md
git commit -m "macOS helper 0.5.0: docs, version and the photo hardware checklist"
```

---

### Task 11: Hardware checks (manual, with the user; not for subagents)

The Image Capture code (Task 9) needs real scanners. Build and run this branch's helper on a **free port** (never the user's installed helper on 8766): `cd macos && swift build && .build/debug/dossiary-scan-helper --headless --port 8799` (it reads the user's real pairing store: pair a test browser with the helper's menu code, or read the code from its log, and revoke the test pairing afterwards). Then, with the Canon MF650C (local) and the Pi's 8800F (network):

- [ ] `GET /scanners` lists the MF650C with `formats ["pdf","jpeg","png"]` and `areas` starting with `full`, the feeder-only behaviour unchanged, and the Pi's 8800F with its formats and areas.
- [ ] **Units:** a `10x15` scan at 300 dpi on the MF650C is 1181 x 1772 px (if Image Capture's `physicalSize`/`scanArea` units differ from inches, find out here and fix `configure`/`probe`, with a test for the conversion).
- [ ] **Origin:** a print against the corner mark appears flush top-left in the `10x15` image.
- [ ] `full`, `a5`, `a4` (if the glass allows it) give the expected sizes; JPEG, PNG and a black & white PNG (1-bit) are right; the dpi is embedded (`sips -g dpiWidth`).
- [ ] **File type:** if the driver ignores the requested type, the re-encode path delivers the requested type (check `file` on the saved result).
- [ ] PDF scans from the flatbed and from the feeder are unchanged; an image request from the feeder is the 422 above.
- [ ] Through the helper to the Pi: a `10x15` JPEG from the 8800F comes back (about 20 s at 300 dpi).
- [ ] Clean up: stop the test helper, revoke test pairings, delete the test scans; confirm 8766 was never touched.
