# macOS Scan Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed, notarized macOS menu bar app, "Dossiary Scan Helper", that lets Dossiary scan with any scanner macOS supports (ImageCaptureCore) over protocol version 2 on `127.0.0.1:8766`, passing the repo's conformance suite in `--fake-scanners` mode.

**Architecture:** A SwiftPM package in `macos/` with two targets. `HelperCore` (library, no UI) holds everything testable: the protocol model and request validation, the fake scanners, page rendering and PDF building, pairing, an HTTP/1.1 parser and a `Router` that turns an `HTTPRequest` into an `HTTPResponse`, the `Network.framework` listener, and the ImageCaptureCore backend behind a `ScannerBackend` protocol. `dossiary-scan-helper` (executable) is a thin AppKit shell: a status-bar menu, the pairing panel, "Start at login", and a `--headless` mode for CI and development. A shell script wraps the binary into `Dossiary Scan Helper.app`; a second one signs it with Developer ID, notarizes and staples it.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, Swift Testing (`import Testing`), Apple frameworks only (Foundation, Network, CoreGraphics, ImageIO, CoreText, CryptoKit, ImageCaptureCore, AppKit, ServiceManagement, UniformTypeIdentifiers). Python 3.11 conformance suite (already in the repo). GitHub Actions `macos-15` runner.

**Design spec:** `~/Projects/Paperless/Dossiary/docs/superpowers/specs/2026-10-09-system-scanner-helper-design.md`, section 3 ("macOS (Swift, ImageCaptureCore)", "Both", "Testing"). The wire contract is this repo's `PROTOCOL.md`; read it before any task that touches HTTP. The reference helper in `reference/scanbridge_ref/` is the behavioural model: when in doubt, do what it does.

**Deviation from the spec, decided by the owner on 2026-10-09:** the spec lists signing and notarization as out of scope for the first release. The owner has an Apple Developer account and wants the macOS helper signed with Developer ID and notarized from the first release (Task 8).

## Global Constraints

- Everything lives under `macos/` in `~/Projects/Paperless/dossiary-scan-helper`, except the CI workflow (`.github/workflows/conformance.yml`), `README.md` and `docs/`.
- `Package.swift`: `// swift-tools-version:6.0`, `platforms: [.macOS(.v14)]`, `swiftLanguageModes: [.v5]`. No package dependencies — Apple frameworks only.
- It must build and test with the **Command Line Tools only** (no Xcode on the owner's Mac): `swift build`, `swift test`. Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`); XCTest is not available. macOS 14 is the floor because the Command Line Tools' `Testing.framework` is built for macOS 14.
- The server listens on `127.0.0.1` only, default port `8766`.
- `/health` answers `"helper": "dossiary-scan-helper-macos"`, `"version": "0.1.0"`, `"protocol": 2`.
- Fake scanner mode (`--fake-scanners`) follows `PROTOCOL.md` "Fake scanner mode" exactly: the seven scanners, pairing code `000000`, and the exact English messages (`"<n> pages scanned."` / `"1 page scanned."`, a jam message containing `jam`, `No paper in the feeder.`, a refused pairing message containing `Pair a browser`).
- Error bodies are always `{"ok": false, "partial": false, "message": "<non-empty, written for a person>"}`.
- All messages and menu text are English in this version.
- No OCR, no window during a scan, plain image PDFs.
- App name `Dossiary Scan Helper`, bundle id `com.aarneaarebye.dossiary-scan-helper`, executable `dossiary-scan-helper`, `LSUIElement` (menu bar only, no Dock icon).
- Paired browsers are stored as SHA-256 hashes of their tokens in `~/Library/Application Support/dossiary-scan-helper/paired-browsers.json`, file mode 0600. Tokens and pairing codes are never written to the log.
- Log file `~/Library/Logs/dossiary-scan-helper/helper.log`. Never log page content or base64 data.
- Signing: Developer ID Application certificate, hardened runtime, notarization with `xcrun notarytool` using the keychain profile `dossiary-notary`. No certificate, password, Apple ID or team id is ever written into the repo or CI; CI builds and tests unsigned.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo
  ```

## File Structure

```
macos/
  Package.swift
  README.md                                  build, test, run, release (Task 8)
  Resources/Info.plist                       app bundle Info.plist template (Task 8)
  scripts/run-conformance.sh                 build, start fake helper, run suite (Task 5)
  scripts/build-app.sh                       universal unsigned .app (Task 8)
  scripts/sign-and-notarize.sh               Developer ID + notarization (Task 8)
  Sources/HelperCore/
    Version.swift                            HelperVersion (Task 1)
    Model.swift                              Source, ColorMode, ScannerInfo, ScanSettings, ProtocolError (Task 1)
    JSONBody.swift                           JSON body parsing and JSON number helpers (Task 1)
    ScanRequestValidator.swift               POST /scan validation steps 1-5 (Task 1)
    FakeScanners.swift                       the seven fake scanners (Task 1)
    ScannerBackend.swift                     ScannerBackend protocol, PageImage, ScanDocuments (Task 2)
    FakePages.swift                          fake page rendering, JPEG encoding (Task 2)
    PdfBuilder.swift                         pages -> PDF data (Task 2)
    FakeBackend.swift                        fake scans (Task 2)
    ScanResponse.swift                       scan result -> response JSON (Task 2)
    PairingStore.swift                       pairing codes and tokens (Task 3)
    HTTPMessage.swift                        HTTPRequest, HTTPRequestParser, HTTPResponse (Task 4)
    Origins.swift                            origin check (Task 4)
    Router.swift                             routing, CORS, token check, one scan at a time (Task 4)
    HTTPServer.swift                         NWListener on 127.0.0.1 (Task 5)
    Log.swift                                log file (Task 5)
    CommandLineOptions.swift                 --fake-scanners, --port, --headless, --version, --help (Task 5)
    HelperRuntime.swift                      wires backend, pairing, router, server (Task 5, extended in Task 7)
    MenuModel.swift                          the status menu's entries, as data (Task 6)
    Callbacks.swift                          Once / awaitCallback: delegate callbacks -> async (Task 7)
    CapabilityMapping.swift                  ImageCaptureCore capabilities -> ScannerInfo (Task 7)
    ScanOutcome.swift                        scanned pages + error -> ScanDocuments or error (Task 7)
    ImageCaptureBackend.swift                real scanners (Task 7)
  Sources/App/
    main.swift                               argument parsing, headless or menu bar (Task 5, Task 6)
    AppDelegate.swift                        status item and menu (Task 6)
    PairingPanel.swift                       the pairing-code window (Task 6)
    LoginItem.swift                          SMAppService wrapper (Task 6)
  Tests/HelperCoreTests/
    ValidationTests.swift (Task 1)  FakeScanTests.swift (Task 2)  PairingTests.swift (Task 3)
    HTTPParserTests.swift, RouterTests.swift (Task 4)  ServerTests.swift, OptionsTests.swift (Task 5)
    MenuModelTests.swift (Task 6)  CapabilityMappingTests.swift, ScanOutcomeTests.swift, CallbackTests.swift (Task 7)
docs/install-macos.md                        for people installing the helper (Task 8)
docs/manual-check-macos.md                   real-hardware checklist before each release (Task 8)
.github/workflows/conformance.yml            + macos-helper job (Task 5)
```

Run every `swift` command from `macos/`. If a build fails with stale-cache errors after files moved, `rm -rf .build` and rebuild.

---

### Task 1: Package, protocol model, request validation, fake scanner table

**Files:**
- Create: `macos/Package.swift`, `macos/Sources/HelperCore/Version.swift`, `Model.swift`, `JSONBody.swift`, `ScanRequestValidator.swift`, `FakeScanners.swift`
- Create: `macos/Tests/HelperCoreTests/ValidationTests.swift`
- Modify: `.gitignore` (repo root)

**Interfaces:**
- Produces: `HelperVersion.string` (`"0.1.0"`), `HelperVersion.helperName` (`"dossiary-scan-helper-macos"`); `enum Source: String { flatbed, feeder }`; `enum ColorMode: String { color, gray, bw }`; `struct ScannerInfo` (fields `id, name, sources, duplex, colorModes, resolutions, extras`, plus `var json: [String: Any]`); `struct ScanSettings` (`source, duplex, colorMode, resolution, extras: [String: Bool]`, `func extra(_:) -> Bool`); `struct ProtocolError: Error, Equatable` (`status: Int`, `message: String`, `init(_ status:, _ message:)`); `JSONBody.parse(_ data: Data) throws -> Any`; `JSONBody.integer(_ value: Any?) -> Int?`; `JSONBody.bool(_ value: Any?) -> Bool?`; `ScanRequestValidator.validate(_ body: Any, scanners: [ScannerInfo]) throws -> (ScannerInfo, ScanSettings)`; `struct FakeScanner` (`info, sheets, delay, offline, jamAfter, empty`); `FakeScanners.all: [FakeScanner]`, `FakeScanners.infos: [ScannerInfo]`, `FakeScanners.emptyFeederMessage`.

- [ ] **Step 1: Package and gitignore**

`macos/Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DossiaryScanHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HelperCore", path: "Sources/HelperCore"),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"], path: "Tests/HelperCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
```

Append to the repo root `.gitignore`:

```
macos/.build/
macos/.build-*/
macos/build/
macos/dist/
```

`macos/Sources/HelperCore/Version.swift`:

```swift
/// The helper's identity as reported by GET /health.
public enum HelperVersion {
    public static let string = "0.1.0"
    public static let helperName = "dossiary-scan-helper-macos"
}
```

- [ ] **Step 2: Write the failing tests**

`macos/Tests/HelperCoreTests/ValidationTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private func json(_ text: String) -> Any { try! JSONBody.parse(Data(text.utf8)) }

private func status(_ text: String) -> Int? {
    do {
        _ = try ScanRequestValidator.validate(json(text), scanners: FakeScanners.infos)
        return nil
    } catch let error as ProtocolError {
        #expect(!error.message.isEmpty)
        return error.status
    } catch {
        return -1
    }
}

@Test func fakeTableHasTheSevenScannersInOrder() {
    #expect(FakeScanners.infos.map(\.id) == ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam",
                                             "fake:slow", "fake:offline", "fake:empty"])
    let feeder = FakeScanners.infos[1]
    #expect(feeder.name == "Fake Feeder")
    #expect(feeder.sources == [.feeder, .flatbed])
    #expect(feeder.duplex)
    #expect(feeder.colorModes == [.color, .gray, .bw])
    #expect(feeder.resolutions == [150, 300, 600])
    #expect(FakeScanners.infos[2].extras == ["splitOnBlank", "skipBlankPages"])
    let described = feeder.json
    #expect(described["sources"] as? [String] == ["feeder", "flatbed"])
    #expect(described["colorModes"] as? [String] == ["color", "gray", "bw"])
    #expect(described["extras"] as? [String] == [])
}

@Test func missingFieldsUseTheScannerDefaults() throws {
    let (scanner, settings) = try ScanRequestValidator.validate(json(#"{"scanner":"fake:feeder"}"#),
                                                                scanners: FakeScanners.infos)
    #expect(scanner.id == "fake:feeder")
    #expect(settings == ScanSettings(source: .feeder, duplex: false, colorMode: .color, resolution: 150, extras: [:]))
}

@Test func fullRequestIsAccepted() throws {
    let (_, settings) = try ScanRequestValidator.validate(json(#"""
        {"scanner":"fake:feeder","source":"feeder","duplex":true,"colorMode":"gray",
         "resolution":300,"format":"pdf","extras":{"somethingNew":false}}
        """#), scanners: FakeScanners.infos)
    #expect(settings == ScanSettings(source: .feeder, duplex: true, colorMode: .gray, resolution: 300,
                                     extras: ["somethingNew": false]))
}

@Test func malformedRequestsAre400() {
    for body in ["[]", "null", "\"x\"", "{}", #"{"scanner":7}"#, #"{"scanner":null}"#,
                 #"{"scanner":"fake:flatbed","source":1}"#, #"{"scanner":"fake:flatbed","source":null}"#,
                 #"{"scanner":"fake:flatbed","colorMode":["color"]}"#, #"{"scanner":"fake:flatbed","format":["pdf"]}"#,
                 #"{"scanner":"fake:flatbed","resolution":"300"}"#, #"{"scanner":"fake:flatbed","resolution":300.0}"#,
                 #"{"scanner":"fake:flatbed","resolution":3e2}"#, #"{"scanner":"fake:flatbed","resolution":true}"#,
                 #"{"scanner":"fake:flatbed","duplex":1}"#, #"{"scanner":"fake:flatbed","duplex":"true"}"#,
                 #"{"scanner":"fake:flatbed","extras":[]}"#, #"{"scanner":"fake:flatbed","extras":{"splitOnBlank":1}}"#] {
        #expect(status(body) == 400, "\(body)")
    }
}

@Test func unknownScannerIs404() {
    #expect(status(#"{"scanner":"fake:nope"}"#) == 404)
}

@Test func unsupportedValuesAre422() {
    for body in [#"{"scanner":"fake:flatbed","source":"feeder"}"#, #"{"scanner":"fake:flatbed","source":"glass"}"#,
                 #"{"scanner":"fake:flatbed","colorMode":"sepia"}"#, #"{"scanner":"fake:flatbed","resolution":299}"#,
                 #"{"scanner":"fake:flatbed","format":"tiff"}"#, #"{"scanner":"fake:flatbed","duplex":true}"#,
                 #"{"scanner":"fake:feeder","source":"flatbed","duplex":true}"#,
                 #"{"scanner":"fake:flatbed","extras":{"splitOnBlank":true}}"#] {
        #expect(status(body) == 422, "\(body)")
    }
}

@Test func checksRunInProtocolOrder() {
    #expect(status(#"{"scanner":"fake:nope","source":1}"#) == 404)            // unknown scanner beats wrong type
    #expect(status(#"{"scanner":"fake:flatbed","source":1,"resolution":299}"#) == 400)  // wrong type beats 422
}

@Test func emptyAndInvalidBodies() {
    #expect(throws: ProtocolError.self) { try JSONBody.parse(Data("{not json".utf8)) }
    #expect(try JSONBody.parse(Data()) is NSNull)
}

@Test func jsonNumberHelpers() {
    #expect(JSONBody.integer(json("300")) == 300)
    #expect(JSONBody.integer(json("300.0")) == nil)
    #expect(JSONBody.integer(json("true")) == nil)
    #expect(JSONBody.bool(json("true")) == true)
    #expect(JSONBody.bool(json("1")) == nil)
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd macos && swift test`
Expected: build fails (`cannot find 'JSONBody' in scope` and similar).

- [ ] **Step 4: Implement the model, JSON helpers, fakes and validator**

`macos/Sources/HelperCore/Model.swift`:

```swift
import Foundation

public enum Source: String, Sendable { case flatbed, feeder }
public enum ColorMode: String, Sendable { case color, gray, bw }

/// One entry of GET /scanners.
public struct ScannerInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var sources: [Source]
    public var duplex: Bool
    public var colorModes: [ColorMode]
    public var resolutions: [Int]
    public var extras: [String]

    public init(id: String, name: String, sources: [Source], duplex: Bool, colorModes: [ColorMode],
                resolutions: [Int], extras: [String]) {
        self.id = id; self.name = name; self.sources = sources; self.duplex = duplex
        self.colorModes = colorModes; self.resolutions = resolutions; self.extras = extras
    }

    public var json: [String: Any] {
        ["id": id, "name": name, "sources": sources.map(\.rawValue), "duplex": duplex,
         "colorModes": colorModes.map(\.rawValue), "resolutions": resolutions, "extras": extras]
    }
}

/// A validated POST /scan request, with every default filled in.
public struct ScanSettings: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var colorMode: ColorMode
    public var resolution: Int
    public var extras: [String: Bool]

    public init(source: Source, duplex: Bool, colorMode: ColorMode, resolution: Int, extras: [String: Bool]) {
        self.source = source; self.duplex = duplex; self.colorMode = colorMode
        self.resolution = resolution; self.extras = extras
    }

    public func extra(_ name: String) -> Bool { extras[name] ?? false }
}

/// A protocol error: the HTTP status plus a message for a person.
public struct ProtocolError: Error, Equatable, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
```

`macos/Sources/HelperCore/JSONBody.swift`:

```swift
import Foundation

public enum JSONBody {
    /// Parses a request body. An empty body is JSON `null` (the protocol: no Content-Length = empty body).
    public static func parse(_ data: Data) throws -> Any {
        if data.isEmpty { return NSNull() }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ProtocolError(400, "The request body isn't valid JSON.")
        }
    }

    /// An integer is a JSON number without fraction or exponent: JSONSerialization makes those
    /// non-float NSNumbers, while `300.0` and `3e2` come back as floats. Booleans are NSNumbers too.
    public static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    /// `as? Bool` would accept the number 1; only JSON true/false count.
    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
```

`macos/Sources/HelperCore/FakeScanners.swift`:

```swift
import Foundation

/// A fake scanner from PROTOCOL.md "Fake scanner mode". Pages carry the text in `sheets`; "" is blank.
public struct FakeScanner: Sendable {
    public let info: ScannerInfo
    public let sheets: [String]
    public let delay: TimeInterval
    public let offline: Bool
    public let jamAfter: Int?
    public let empty: Bool
}

public enum FakeScanners {
    public static let emptyFeederMessage = "No paper in the feeder."

    private static func make(_ id: String, _ name: String, _ sources: [Source], duplex: Bool = false,
                             extras: [String] = [], sheets: [String] = [], delay: TimeInterval = 0,
                             offline: Bool = false, jamAfter: Int? = nil, empty: Bool = false) -> FakeScanner {
        FakeScanner(info: ScannerInfo(id: id, name: name, sources: sources, duplex: duplex,
                                      colorModes: [.color, .gray, .bw], resolutions: [150, 300, 600], extras: extras),
                    sheets: sheets, delay: delay, offline: offline, jamAfter: jamAfter, empty: empty)
    }

    public static let all: [FakeScanner] = [
        make("fake:flatbed", "Fake Flatbed", [.flatbed]),
        make("fake:feeder", "Fake Feeder", [.feeder, .flatbed], duplex: true, sheets: ["Sheet 1", "Sheet 2", "Sheet 3"]),
        make("fake:splitter", "Fake Splitter", [.feeder], extras: ["splitOnBlank", "skipBlankPages"],
             sheets: ["Doc A page 1", "Doc A page 2", "", "Doc B page 1"]),
        make("fake:jam", "Fake Jamming Feeder", [.feeder], sheets: ["Sheet 1", "Sheet 2", "Sheet 3"], jamAfter: 2),
        make("fake:slow", "Fake Slow Scanner", [.flatbed], delay: 2),
        make("fake:offline", "Fake Offline Scanner", [.flatbed], offline: true),
        make("fake:empty", "Fake Empty Feeder", [.feeder], empty: true),
    ]

    public static var infos: [ScannerInfo] { all.map(\.info) }
}
```

`macos/Sources/HelperCore/ScanRequestValidator.swift` (messages match the reference helper's `fakes.validate`):

```swift
import Foundation

/// POST /scan validation, steps 1-5 of PROTOCOL.md "Request validation", in that order.
public enum ScanRequestValidator {
    public static func validate(_ body: Any, scanners: [ScannerInfo]) throws -> (ScannerInfo, ScanSettings) {
        guard let object = body as? [String: Any] else {
            throw ProtocolError(400, "The request body must be a JSON object.")
        }
        guard let scannerID = object["scanner"] as? String else {
            throw ProtocolError(400, "The request needs a scanner id.")
        }
        guard let scanner = scanners.first(where: { $0.id == scannerID }) else {
            throw ProtocolError(404, "No scanner with id “\(scannerID)”.")
        }

        for key in ["source", "colorMode", "format"] where object[key] != nil && !(object[key] is String) {
            throw ProtocolError(400, "“\(key)” must be a string.")
        }
        if object["resolution"] != nil && JSONBody.integer(object["resolution"]) == nil {
            throw ProtocolError(400, "“resolution” must be a whole number.")
        }
        if object["duplex"] != nil && JSONBody.bool(object["duplex"]) == nil {
            throw ProtocolError(400, "“duplex” must be true or false.")
        }
        var extras: [String: Bool] = [:]
        if let rawExtras = object["extras"] {
            guard let dict = rawExtras as? [String: Any] else {
                throw ProtocolError(400, "“extras” must map names to true or false.")
            }
            for (name, value) in dict {
                guard let on = JSONBody.bool(value) else {
                    throw ProtocolError(400, "“extras” must map names to true or false.")
                }
                extras[name] = on
            }
        }

        let sourceText = object["source"] as? String ?? scanner.sources[0].rawValue
        guard let source = Source(rawValue: sourceText), scanner.sources.contains(source) else {
            throw ProtocolError(422, "\(scanner.name) has no \(sourceText) source.")
        }
        let colorText = object["colorMode"] as? String ?? scanner.colorModes[0].rawValue
        guard let colorMode = ColorMode(rawValue: colorText), scanner.colorModes.contains(colorMode) else {
            throw ProtocolError(422, "\(scanner.name) can't scan in \(colorText).")
        }
        let resolution = JSONBody.integer(object["resolution"]) ?? scanner.resolutions[0]
        guard scanner.resolutions.contains(resolution) else {
            throw ProtocolError(422, "\(scanner.name) can't scan at \(resolution) dpi.")
        }
        let format = object["format"] as? String ?? "pdf"
        guard format == "pdf" else {
            throw ProtocolError(422, "Format “\(format)” isn't supported; use pdf.")
        }
        let duplex = JSONBody.bool(object["duplex"]) ?? false
        if duplex && !(scanner.duplex && source == .feeder) {
            throw ProtocolError(422, "\(scanner.name) can't scan both sides from the \(source.rawValue).")
        }
        for (name, on) in extras.sorted(by: { $0.key < $1.key }) where on && !scanner.extras.contains(name) {
            throw ProtocolError(422, "\(scanner.name) doesn't offer “\(name)”.")
        }

        return (scanner, ScanSettings(source: source, duplex: duplex, colorMode: colorMode,
                                      resolution: resolution, extras: extras))
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd macos && swift test`
Expected: every test passes.

- [ ] **Step 6: Commit**

```bash
git add .gitignore macos/Package.swift macos/Sources macos/Tests
git commit -m "macOS helper: Swift package, protocol model, scan request validation, fake scanner table"
```

---

### Task 2: Fake pages, PDF building, fake scans, scan responses

**Files:**
- Create: `macos/Sources/HelperCore/ScannerBackend.swift`, `FakePages.swift`, `PdfBuilder.swift`, `FakeBackend.swift`, `ScanResponse.swift`
- Create: `macos/Tests/HelperCoreTests/FakeScanTests.swift`

**Interfaces:**
- Consumes: Task 1's `ScannerInfo`, `ScanSettings`, `ProtocolError`, `FakeScanner`, `FakeScanners`.
- Produces:
  - `struct PageImage { data: Data; dpi: Int }` — encoded image bytes (JPEG/PNG/TIFF) and their resolution.
  - `struct ScanDocuments { documents: [[PageImage]]; partialMessage: String? }` — `partialMessage != nil` means `partial: true`.
  - `protocol ScannerBackend: AnyObject, Sendable { func listScanners() async -> [ScannerInfo]; func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments; func setChangeHandler(_ handler: @escaping @Sendable () -> Void) }`
  - `final class FakeBackend: ScannerBackend` with `static func plan(_ fake: FakeScanner, _ settings: ScanSettings) -> (documents: [[String]], partialMessage: String?)`.
  - `FakePages.render(_ text: String) throws -> PageImage`; `ImageEncoding.jpeg(_ image: CGImage, quality: Double) throws -> Data`.
  - `PdfBuilder.makePdf(_ pages: [PageImage]) throws -> Data`.
  - `ScanResponse.payload(_ result: ScanDocuments, date: Date) throws -> [String: Any]`; `ScanResponse.pagesMessage(_ count: Int) -> String`.

PDF note (verified on this Mac before planning): drawing a `CGImage` made from JPEG data with `CGImageSourceCreateWithData` into a `CGContext(consumer:mediaBox:)` PDF context embeds the JPEG as is (`DCTDecode`, no re-encoding), and the output contains one `/Type /Page` per page, which is what the conformance suite counts.

- [ ] **Step 1: Write the failing tests**

`macos/Tests/HelperCoreTests/FakeScanTests.swift`:

```swift
import Foundation
import PDFKit
import Testing
@testable import HelperCore

private func fake(_ id: String) -> FakeScanner { FakeScanners.all.first { $0.info.id == id }! }
private func settings(_ source: Source, duplex: Bool = false, extras: [String: Bool] = [:]) -> ScanSettings {
    ScanSettings(source: source, duplex: duplex, colorMode: .color, resolution: 150, extras: extras)
}

@Test func flatbedSourceGivesOnePage() {
    #expect(FakeBackend.plan(fake("fake:feeder"), settings(.flatbed)).documents == [["Flatbed page 1"]])
}

@Test func feederDuplexGivesFrontsAndBacks() {
    #expect(FakeBackend.plan(fake("fake:feeder"), settings(.feeder, duplex: true)).documents ==
            [["Sheet 1", "Sheet 1 back", "Sheet 2", "Sheet 2 back", "Sheet 3", "Sheet 3 back"]])
}

@Test func splitterExtras() {
    let splitter = fake("fake:splitter")
    #expect(FakeBackend.plan(splitter, settings(.feeder)).documents.map(\.count) == [4])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["skipBlankPages": true])).documents.map(\.count) == [3])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["splitOnBlank": true])).documents ==
            [["Doc A page 1", "Doc A page 2"], ["Doc B page 1"]])
    #expect(FakeBackend.plan(splitter, settings(.feeder, extras: ["splitOnBlank": true, "skipBlankPages": true]))
            .documents.map(\.count) == [2, 1])
}

@Test func jamIsPartial() {
    let plan = FakeBackend.plan(fake("fake:jam"), settings(.feeder))
    #expect(plan.documents == [["Sheet 1", "Sheet 2"]])
    #expect(plan.partialMessage?.contains("jam") == true)
}

@Test func renderedPageIsAJpeg() throws {
    let page = try FakePages.render("Sheet 1")
    #expect(page.dpi == FakePages.dpi)
    #expect(page.data.prefix(2) == Data([0xFF, 0xD8]))
}

@Test func pdfHasOnePagePerImageAtA4Size() throws {
    let pages = try ["One", "", "Three"].map(FakePages.render)
    let pdf = try PdfBuilder.makePdf(pages)
    #expect(pdf.starts(with: Data("%PDF-".utf8)))
    let document = try #require(PDFDocument(data: pdf))
    #expect(document.pageCount == 3)
    let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
    #expect(abs(bounds.width - 595) < 3 && abs(bounds.height - 842) < 3)
    let text = String(decoding: pdf, as: UTF8.self)
    let pageObjects = try NSRegularExpression(pattern: "/Type\\s*/Page(?!s)")
        .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    #expect(pageObjects == 3)
}

@Test func emptyPdfIsRefused() {
    #expect(throws: ProtocolError.self) { try PdfBuilder.makePdf([]) }
}

@Test func responsePayloadForOneAndTwoDocuments() throws {
    let page = try FakePages.render("x")
    let date = Date(timeIntervalSince1970: 0)
    let one = try ScanResponse.payload(ScanDocuments(documents: [[page, page, page]], partialMessage: nil), date: date)
    #expect(one["ok"] as? Bool == true)
    #expect(one["partial"] as? Bool == false)
    #expect(one["message"] as? String == "3 pages scanned.")
    let files = try #require(one["files"] as? [[String: Any]])
    #expect(files.count == 1)
    let name = try #require(files[0]["name"] as? String)
    #expect(name.range(of: #"^scan_\d{8}_\d{6}\.pdf$"#, options: .regularExpression) != nil)
    #expect(files[0]["pages"] as? Int == 3)
    let data = try #require(Data(base64Encoded: try #require(files[0]["data"] as? String)))
    #expect(data.starts(with: Data("%PDF-".utf8)))

    let two = try ScanResponse.payload(ScanDocuments(documents: [[page], [page]], partialMessage: "Paper jam."), date: date)
    #expect(two["ok"] as? Bool == false)
    #expect(two["partial"] as? Bool == true)
    #expect(two["message"] as? String == "Paper jam.")
    let names = try #require(two["files"] as? [[String: Any]]).compactMap { $0["name"] as? String }
    #expect(names.count == 2 && names[0].hasSuffix("_1.pdf") && names[1].hasSuffix("_2.pdf"))
    #expect(ScanResponse.pagesMessage(1) == "1 page scanned.")
}

@Test func fakeBackendErrors() async {
    let backend = FakeBackend()
    do { _ = try await backend.scan(scannerID: "fake:offline", settings: settings(.flatbed)); Issue.record("no error") }
    catch let error as ProtocolError { #expect(error.status == 503) } catch { Issue.record("\(error)") }
    do { _ = try await backend.scan(scannerID: "fake:empty", settings: settings(.feeder)); Issue.record("no error") }
    catch let error as ProtocolError { #expect(error == ProtocolError(500, "No paper in the feeder.")) }
    catch { Issue.record("\(error)") }
}

@Test func fakeBackendScansTheSplitter() async throws {
    let result = try await FakeBackend().scan(scannerID: "fake:splitter",
                                              settings: settings(.feeder, extras: ["splitOnBlank": true]))
    #expect(result.documents.map(\.count) == [2, 1])
    #expect(result.partialMessage == nil)
    #expect(await FakeBackend().listScanners() == FakeScanners.infos)
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd macos && swift test`
Expected: build fails (`cannot find 'FakeBackend' in scope`).

- [ ] **Step 3: Implement**

`macos/Sources/HelperCore/ScannerBackend.swift`:

```swift
import Foundation

/// One scanned page: encoded image bytes (JPEG, PNG or TIFF) and the resolution they were scanned at.
public struct PageImage: Sendable {
    public let data: Data
    public let dpi: Int
    public init(data: Data, dpi: Int) { self.data = data; self.dpi = dpi }
}

/// A scan's result: one page list per PDF. A non-nil `partialMessage` means `ok: false, partial: true`.
public struct ScanDocuments: Sendable {
    public var documents: [[PageImage]]
    public var partialMessage: String?
    public init(documents: [[PageImage]], partialMessage: String?) {
        self.documents = documents; self.partialMessage = partialMessage
    }
}

/// Where scanners come from: the fakes, or ImageCaptureCore.
public protocol ScannerBackend: AnyObject, Sendable {
    func listScanners() async -> [ScannerInfo]
    /// Throws ProtocolError (503 unreachable/denied, 500 failed with no page).
    func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments
    /// Called (on any thread) whenever the scanner list changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
}
```

`macos/Sources/HelperCore/FakePages.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {
    public static func jpeg(_ image: CGImage, quality: Double = 0.8) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProtocolError(500, "Couldn't encode a page.")
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProtocolError(500, "Couldn't encode a page.") }
        return output as Data
    }
}

/// The fake scanners' pages: an A4 page at a low resolution with one line of text ("" = blank).
public enum FakePages {
    public static let dpi = 50
    static let width = 413   // 8.27 in × 50 dpi
    static let height = 585  // 11.69 in × 50 dpi

    public static func render(_ text: String) throws -> PageImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ProtocolError(500, "Couldn't draw a page.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !text.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 36, y: height - 72)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw ProtocolError(500, "Couldn't draw a page.") }
        return PageImage(data: try ImageEncoding.jpeg(image), dpi: dpi)
    }
}
```

`macos/Sources/HelperCore/PdfBuilder.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

/// Joins page images into one PDF, each page sized from its pixels and dpi. JPEG pages are embedded as is.
public enum PdfBuilder {
    public static func makePdf(_ pages: [PageImage]) throws -> Data {
        guard !pages.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ProtocolError(500, "Couldn't create the PDF.")
        }
        for page in pages {
            guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProtocolError(500, "A scanned page couldn't be read.")
            }
            let dpi = Double(max(page.dpi, 1))
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return output as Data
    }
}
```

`macos/Sources/HelperCore/FakeBackend.swift` (same behaviour as the reference helper's `fakes.simulate`):

```swift
import Foundation

/// PROTOCOL.md "Fake scanner mode".
public final class FakeBackend: ScannerBackend, @unchecked Sendable {
    public init() {}

    public func listScanners() async -> [ScannerInfo] { FakeScanners.infos }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}  // the fakes never change

    public func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments {
        guard let fake = FakeScanners.all.first(where: { $0.info.id == scannerID }) else {
            throw ProtocolError(404, "No scanner with id “\(scannerID)”.")
        }
        if fake.offline {
            throw ProtocolError(503, "\(fake.info.name) isn't reachable. Check that it's switched on and connected.")
        }
        if fake.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(fake.delay * 1_000_000_000)) }
        if fake.empty { throw ProtocolError(500, FakeScanners.emptyFeederMessage) }
        let plan = FakeBackend.plan(fake, settings)
        let documents = try plan.documents.map { try $0.map(FakePages.render) }
        return ScanDocuments(documents: documents, partialMessage: plan.partialMessage)
    }

    /// Which page texts a fake scan returns, grouped into documents, and the jam message if any.
    public static func plan(_ fake: FakeScanner, _ settings: ScanSettings) -> (documents: [[String]], partialMessage: String?) {
        var pages: [String]
        if settings.source == .flatbed {
            pages = ["Flatbed page 1"]
        } else {
            let sheets = fake.jamAfter.map { Array(fake.sheets.prefix($0)) } ?? fake.sheets
            pages = []
            for sheet in sheets {
                pages.append(sheet)
                if settings.duplex { pages.append(sheet.isEmpty ? "" : "\(sheet) back") }
            }
        }

        var documents: [[String]]
        if settings.extra("splitOnBlank") {
            documents = []
            var current: [String] = []
            for page in pages {
                if page.isEmpty {
                    if !current.isEmpty { documents.append(current) }
                    current = []
                } else {
                    current.append(page)
                }
            }
            if !current.isEmpty { documents.append(current) }
        } else {
            if settings.extra("skipBlankPages") { pages = pages.filter { !$0.isEmpty } }
            documents = [pages]
        }

        if let jamAfter = fake.jamAfter, settings.source == .feeder {
            return (documents, "Paper jam after \(jamAfter) sheets. The pages before it were kept.")
        }
        return (documents, nil)
    }
}
```

`macos/Sources/HelperCore/ScanResponse.swift`:

```swift
import Foundation

/// The 200 answer to POST /scan.
public enum ScanResponse {
    public static func pagesMessage(_ count: Int) -> String {
        count == 1 ? "1 page scanned." : "\(count) pages scanned."
    }

    public static func payload(_ result: ScanDocuments, date: Date) throws -> [String: Any] {
        let documents = result.documents.filter { !$0.isEmpty }
        guard !documents.isEmpty else { throw ProtocolError(500, "The scanner returned no pages.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        var files: [[String: Any]] = []
        for (index, pages) in documents.enumerated() {
            let name = documents.count == 1 ? "scan_\(stamp).pdf" : "scan_\(stamp)_\(index + 1).pdf"
            files.append(["name": name, "pages": pages.count,
                          "data": try PdfBuilder.makePdf(pages).base64EncodedString()])
        }
        let total = documents.reduce(0) { $0 + $1.count }
        let partial = result.partialMessage != nil
        return ["ok": !partial, "partial": partial,
                "message": result.partialMessage ?? pagesMessage(total), "files": files]
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd macos && swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore macos/Tests/HelperCoreTests
git commit -m "macOS helper: fake pages, PDF building with embedded JPEGs, fake scans, scan responses"
```

---

### Task 3: Pairing

**Files:**
- Create: `macos/Sources/HelperCore/PairingStore.swift`
- Create: `macos/Tests/HelperCoreTests/PairingTests.swift`

**Interfaces:**
- Consumes: `ProtocolError`.
- Produces: `final class PairingStore` with
  - `enum Mode { case fake; case real(fileURL: URL) }`, `init(mode:now:makeCode:)` (`now: @escaping @Sendable () -> Date = { Date() }`, `makeCode: @escaping @Sendable () -> String = PairingStore.randomCode`)
  - `static let fakeCode = "000000"`, `codeLifetime: TimeInterval = 120`, `maxAttempts = 5`, `refusedMessage`
  - `static var defaultFileURL: URL` (`~/Library/Application Support/dossiary-scan-helper/paired-browsers.json`)
  - `var isFake: Bool`, `func openWindow() -> String`, `var activeCode: String?`, `var secondsLeft: Int?`, `func closeWindow()`
  - `func pair(code: String, client: String?) throws -> String`, `func isValid(token: String?) -> Bool`, `var pairedCount: Int`, `func forgetAll()`
  - `static func validatePairBody(_ body: Any) throws -> (code: String, client: String?)`, `static func randomCode() -> String`, `static func randomToken() -> String`

Rules (PROTOCOL.md "Pairing"): a real pairing window shows a fresh 6-digit code for 2 minutes and 5 attempts; the 5th wrong attempt or expiry closes it, and then every code is refused until a new window opens. A right code issues a new token and closes the window (one code pairs one browser). Tokens survive restarts (stored hashed) until "Forget paired browsers". Fake mode: `000000` always works, any number of times; tokens live in memory only.

- [ ] **Step 1: Write the failing tests**

`macos/Tests/HelperCoreTests/PairingTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pairing-\(UUID().uuidString)")
        .appendingPathComponent("paired-browsers.json")
}

private func status(_ block: () throws -> Void) -> Int? {
    do { try block(); return nil } catch let error as ProtocolError { return error.status } catch { return -1 }
}

@Test func fakeModeAcceptsZerosAnyNumberOfTimes() throws {
    let store = PairingStore(mode: .fake)
    let first = try store.pair(code: "000000", client: nil)
    let second = try store.pair(code: "000000", client: "Chrome")
    #expect(first != second)
    #expect(first.count >= 22)
    #expect(first.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    #expect(store.isValid(token: first) && store.isValid(token: second))
    #expect(!store.isValid(token: "nope") && !store.isValid(token: nil))
    #expect(status { _ = try store.pair(code: "000001", client: nil) } == 403)
    #expect(store.openWindow() == "000000")
}

@Test func realModeRefusesWithoutAWindow() {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func realModeRightCodePairsOnceAndClosesTheWindow() throws {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    #expect(store.openWindow() == "123456")
    #expect(store.activeCode == "123456")
    let token = try store.pair(code: "123456", client: "Chrome")
    #expect(store.isValid(token: token))
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func codeExpiresAfterTwoMinutes() {
    let clock = TestClock()
    let store = PairingStore(mode: .real(fileURL: tempFile()), now: { clock.date }, makeCode: { "123456" })
    _ = store.openWindow()
    #expect(store.secondsLeft == 120)
    clock.advance(119)
    #expect(store.activeCode == "123456")
    clock.advance(1)
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func fifthWrongAttemptClosesTheWindow() {
    let store = PairingStore(mode: .real(fileURL: tempFile()), makeCode: { "123456" })
    _ = store.openWindow()
    for _ in 1...4 { #expect(status { _ = try store.pair(code: "000000", client: nil) } == 403) }
    #expect(store.activeCode == "123456")
    #expect(status { _ = try store.pair(code: "000000", client: nil) } == 403)
    #expect(store.activeCode == nil)
    #expect(status { _ = try store.pair(code: "123456", client: nil) } == 403)
}

@Test func tokensPersistHashedAndForgetClearsThem() throws {
    let file = tempFile()
    let store = PairingStore(mode: .real(fileURL: file), makeCode: { "123456" })
    _ = store.openWindow()
    let token = try store.pair(code: "123456", client: "Chrome")
    let saved = try String(contentsOf: file, encoding: .utf8)
    #expect(!saved.contains(token))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    let reopened = PairingStore(mode: .real(fileURL: file))
    #expect(reopened.isValid(token: token))
    #expect(reopened.pairedCount == 1)
    reopened.forgetAll()
    #expect(!reopened.isValid(token: token))
    #expect(!PairingStore(mode: .real(fileURL: file)).isValid(token: token))
}

@Test func pairBodyValidation() throws {
    #expect(try PairingStore.validatePairBody(["code": "1"]) == ("1", nil))
    #expect(try PairingStore.validatePairBody(["code": "1", "client": "Chrome"]) == ("1", "Chrome"))
    for body: Any in [NSNull(), [1], [String: Any](), ["code": 1], ["code": "1", "client": 5],
                      ["code": "1", "client": String(repeating: "x", count: 201)]] {
        #expect(status { _ = try PairingStore.validatePairBody(body) } == 400)
    }
    #expect(PairingStore.refusedMessage.contains("Pair a browser"))
}
```

(`#expect(try ... == ("1", nil))` compares tuples; if Swift Testing can't compare the optional tuple directly, destructure into `let (code, client) = try ...` and compare the parts.)

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd macos && swift test --filter PairingTests`
Expected: build fails (`cannot find 'PairingStore' in scope`).

- [ ] **Step 3: Implement**

`macos/Sources/HelperCore/PairingStore.swift`:

```swift
import CryptoKit
import Foundation

/// Browser pairing (PROTOCOL.md "Pairing"). Thread-safe.
public final class PairingStore: @unchecked Sendable {
    public enum Mode { case fake; case real(fileURL: URL) }

    public static let fakeCode = "000000"
    public static let codeLifetime: TimeInterval = 120
    public static let maxAttempts = 5
    public static let maxClientLength = 200
    public static let refusedMessage =
        "That pairing code isn't valid. In the scan helper, choose “Pair a browser…” and enter the new code."

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dossiary-scan-helper")
            .appendingPathComponent("paired-browsers.json")
    }

    struct Browser: Codable { var tokenHash: String; var client: String?; var pairedAt: Date }
    struct SavedFile: Codable { var browsers: [Browser] }
    struct Window { var code: String; var opened: Date; var attemptsLeft: Int }

    private let lock = NSLock()
    private let mode: Mode
    private let now: @Sendable () -> Date
    private let makeCode: @Sendable () -> String
    private var browsers: [Browser] = []
    private var window: Window?

    public init(mode: Mode, now: @escaping @Sendable () -> Date = { Date() },
                makeCode: @escaping @Sendable () -> String = PairingStore.randomCode) {
        self.mode = mode
        self.now = now
        self.makeCode = makeCode
        if case .real(let url) = mode, let data = try? Data(contentsOf: url),
           let saved = try? PairingStore.decoder.decode(SavedFile.self, from: data) {
            browsers = saved.browsers
        }
    }

    public var isFake: Bool { if case .fake = mode { return true } else { return false } }

    // MARK: Pairing window (real mode)

    /// Opens a new pairing window and returns its code. Fake mode: always "000000".
    public func openWindow() -> String {
        if isFake { return PairingStore.fakeCode }
        return locked {
            let code = makeCode()
            window = Window(code: code, opened: now(), attemptsLeft: PairingStore.maxAttempts)
            return code
        }
    }

    public var activeCode: String? {
        if isFake { return PairingStore.fakeCode }
        return locked { currentWindow()?.code }
    }

    public var secondsLeft: Int? {
        locked {
            guard let window = currentWindow() else { return nil }
            return Int((PairingStore.codeLifetime - now().timeIntervalSince(window.opened)).rounded(.up))
        }
    }

    public func closeWindow() { locked { window = nil } }

    /// The open window, or nil (closing it) once it has expired. Call with the lock held.
    private func currentWindow() -> Window? {
        guard let open = window else { return nil }
        if now().timeIntervalSince(open.opened) >= PairingStore.codeLifetime { window = nil; return nil }
        return open
    }

    // MARK: Pairing and tokens

    public func pair(code: String, client: String?) throws -> String {
        try locked {
            if !isFake {
                guard var open = currentWindow() else { throw ProtocolError(403, PairingStore.refusedMessage) }
                guard code == open.code else {
                    open.attemptsLeft -= 1
                    window = open.attemptsLeft > 0 ? open : nil
                    throw ProtocolError(403, PairingStore.refusedMessage)
                }
                window = nil
            } else if code != PairingStore.fakeCode {
                throw ProtocolError(403, PairingStore.refusedMessage)
            }
            let token = PairingStore.randomToken()
            browsers.append(Browser(tokenHash: PairingStore.hash(token), client: client, pairedAt: now()))
            save()
            return token
        }
    }

    public func isValid(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let hash = PairingStore.hash(token)
        return locked { browsers.contains { $0.tokenHash == hash } }
    }

    public var pairedCount: Int { locked { browsers.count } }

    public func forgetAll() { locked { browsers = []; save() } }

    // MARK: Helpers

    public static func validatePairBody(_ body: Any) throws -> (code: String, client: String?) {
        guard let object = body as? [String: Any] else { throw ProtocolError(400, "The request body must be a JSON object.") }
        guard let code = object["code"] as? String else { throw ProtocolError(400, "The request needs a pairing code.") }
        guard let rawClient = object["client"] else { return (code, nil) }
        guard let client = rawClient as? String else { throw ProtocolError(400, "“client” must be a string.") }
        guard client.count <= maxClientLength else {
            throw ProtocolError(400, "“client” may have at most \(maxClientLength) characters.")
        }
        return (code, client)
    }

    public static func randomCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    /// 24 random bytes (192 bits), base64url without padding: 32 characters.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// Writes the hashed tokens (real mode only), readable by this user only. Call with the lock held.
    /// A failed save keeps the pairing working until the helper restarts.
    private func save() {
        guard case .real(let url) = mode else { return }
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? PairingStore.encoder.encode(SavedFile(browsers: browsers)) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd macos && swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/HelperCore/PairingStore.swift macos/Tests/HelperCoreTests/PairingTests.swift
git commit -m "macOS helper: pairing codes, hashed persistent tokens, fake-mode pairing"
```

---

### Task 4: HTTP parsing and the router

**Files:**
- Create: `macos/Sources/HelperCore/HTTPMessage.swift`, `Origins.swift`, `Router.swift`
- Create: `macos/Tests/HelperCoreTests/HTTPParserTests.swift`, `RouterTests.swift`

**Interfaces:**
- Consumes: `ScannerBackend`, `FakeBackend`, `ScanDocuments`, `ScanResponse`, `ScanRequestValidator`, `PairingStore`, `JSONBody`, `ProtocolError`, `HelperVersion`.
- Produces:
  - `struct HTTPRequest { method: String; path: String; headers: [String: String] /* lowercased names, first value wins */; body: Data; bodyError: ProtocolError?; func header(_ name: String) -> String?; func jsonBody() throws -> Any }` and its memberwise-style `init(method:path:headers:body:bodyError:)` (headers given with any case are lowercased).
  - `struct HTTPRequestParser { static let maxHeaderBytes = 65_536; static let maxBody = 1_000_000; enum Result { case needMore, done(HTTPRequest), malformed }; mutating func feed(_ data: Data) -> Result }`
  - `struct HTTPResponse { status: Int; headers: [(String, String)]; body: Data; static func json(_ status: Int, _ payload: [String: Any], origin: String?, extraHeaders: [(String, String)] = []) -> HTTPResponse; func header(_ name: String) -> String?; func serialized(includeBody: Bool) -> Data }`
  - `Origins.allowed(_ origin: String?) -> Bool`
  - `final class Router { init(backend:pairing:now:log:); func handle(_ request: HTTPRequest) async -> HTTPResponse; static func errorBody(_ message: String) -> [String: Any] }`

Rules (PROTOCOL.md "Requests", "Endpoints and methods", "Origins"): check in this order — origin (403, no CORS headers) → `OPTIONS` preflight (204) → unknown path 404 → wrong method 405 with `Allow` → token for `/scanners` and `/scan` (401) → the endpoint. A bad or oversized `Content-Length` is only reported (400) when the endpoint reads the body, so it comes after the token check, as in the reference helper. Query strings are ignored. Every response to an allowed `Origin` carries `Access-Control-Allow-Origin: <origin>` and `Vary: Origin`. Only one scan at a time (409), checked after validation; `/health` and `/scanners` keep answering during a scan.

- [ ] **Step 1: Write the failing parser tests**

`macos/Tests/HelperCoreTests/HTTPParserTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private func parse(_ text: String, chunks: Int = 1) -> HTTPRequestParser.Result {
    var parser = HTTPRequestParser()
    let data = Data(text.utf8)
    let size = max(1, data.count / chunks)
    var result = HTTPRequestParser.Result.needMore
    var offset = 0
    while offset < data.count {
        result = parser.feed(data.subdata(in: offset..<min(offset + size, data.count)))
        offset += size
        if case .done = result { break }
    }
    return result
}

private func request(_ text: String, chunks: Int = 1) throws -> HTTPRequest {
    guard case .done(let request) = parse(text, chunks: chunks) else { throw ProtocolError(0, "not done") }
    return request
}

@Test func parsesAGetWithQueryAndHeaders() throws {
    let r = try request("GET /health?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: null\r\nX-Two: a\r\nx-two: b\r\n\r\n")
    #expect(r.method == "GET")
    #expect(r.path == "/health")
    #expect(r.header("ORIGIN") == "null")
    #expect(r.header("x-two") == "a")
    #expect(r.body.isEmpty && r.bodyError == nil)
}

@Test func readsABodyArrivingInPieces() throws {
    let body = #"{"scanner":"fake:flatbed"}"#
    let r = try request("POST /scan HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", chunks: 7)
    #expect(String(decoding: r.body, as: UTF8.self) == body)
}

@Test func waitsForTheWholeBody() {
    if case .needMore = parse("POST /scan HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") {} else { Issue.record("expected needMore") }
}

@Test func badContentLengthIsABodyErrorNotMalformed() throws {
    for value in ["abc", "-1", "1.5", "", "1000001"] {
        let r = try request("POST /scan HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n")
        #expect(r.bodyError?.status == 400, "\(value)")
    }
}

@Test func garbageIsMalformed() {
    if case .malformed = parse("NONSENSE\r\n\r\n") {} else { Issue.record("expected malformed") }
    if case .malformed = parse("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n") {} else { Issue.record("expected malformed") }
    if case .malformed = parse("GET / HTTP/1.1\r\n" + String(repeating: "a", count: 70_000)) {} else {
        Issue.record("expected malformed for oversized headers")
    }
}

@Test func responseSerialization() {
    let response = HTTPResponse.json(405, ["ok": false], origin: "null", extraHeaders: [("Allow", "GET, OPTIONS")])
    let text = String(decoding: response.serialized(includeBody: true), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    #expect(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
    #expect(text.contains("Access-Control-Allow-Origin: null\r\n"))
    #expect(text.contains("Vary: Origin\r\n"))
    #expect(text.contains("Allow: GET, OPTIONS\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"ok\":false}"))
    let head = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
    #expect(head.hasSuffix("\r\n\r\n") && head.contains("Content-Length: 12\r\n"))
}
```

- [ ] **Step 2: Write the failing router tests**

`macos/Tests/HelperCoreTests/RouterTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private func makeRouter(backend: ScannerBackend = FakeBackend()) -> (Router, String) {
    let pairing = PairingStore(mode: .fake)
    let token = try! pairing.pair(code: "000000", client: nil)
    return (Router(backend: backend, pairing: pairing), token)
}

private func req(_ method: String, _ path: String, origin: String? = nil, token: String? = nil,
                 body: String? = nil, headers: [String: String] = [:]) -> HTTPRequest {
    var all = headers
    if let origin { all["Origin"] = origin }
    if let token { all["Authorization"] = "Bearer \(token)" }
    return HTTPRequest(method: method, path: path, headers: all, body: Data((body ?? "").utf8), bodyError: nil)
}

private func object(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

@Test func originRules() {
    for origin in [nil, "null", "http://localhost", "http://127.0.0.1", "http://localhost:8080", "http://127.0.0.1:65535"] {
        #expect(Origins.allowed(origin), "\(origin ?? "none")")
    }
    for origin in ["https://localhost", "http://localhost:0", "http://localhost:65536", "http://evil.example",
                   "http://localhost.evil.example", "http://127.0.0.1:80/x", ""] {
        #expect(!Origins.allowed(origin), "\(origin)")
    }
}

@Test func otherOriginsGet403WithoutCORS() async {
    let (router, token) = makeRouter()
    for request in [req("GET", "/health", origin: "https://evil.example"),
                    req("OPTIONS", "/scan", origin: "https://evil.example"),
                    req("POST", "/scan", origin: "https://evil.example", token: token, body: #"{"scanner":"fake:flatbed"}"#)] {
        let response = await router.handle(request)
        #expect(response.status == 403)
        #expect(response.header("Access-Control-Allow-Origin") == nil)
    }
}

@Test func preflight() async {
    let (router, _) = makeRouter()
    let response = await router.handle(req("OPTIONS", "/anything", origin: "null",
                                           headers: ["Access-Control-Request-Private-Network": "true"]))
    #expect(response.status == 204)
    #expect(response.header("Access-Control-Allow-Origin") == "null")
    #expect(response.header("Access-Control-Allow-Methods") == "GET, POST, OPTIONS")
    #expect(response.header("Access-Control-Allow-Headers") == "Content-Type, Authorization")
    #expect(response.header("Access-Control-Max-Age") == "600")
    #expect(response.header("Access-Control-Allow-Private-Network") == "true")
    let plain = await router.handle(req("OPTIONS", "/scan", origin: "null"))
    #expect(plain.header("Access-Control-Allow-Private-Network") == nil)
}

@Test func healthReportsPairing() async {
    let (router, token) = makeRouter()
    let anonymous = object(await router.handle(req("GET", "/health")))
    #expect(anonymous["ok"] as? Bool == true)
    #expect(anonymous["helper"] as? String == "dossiary-scan-helper-macos")
    #expect(anonymous["version"] as? String == HelperVersion.string)
    #expect(anonymous["protocol"] as? Int == 2)
    #expect(anonymous["paired"] as? Bool == false)
    #expect(object(await router.handle(req("GET", "/health", token: token)))["paired"] as? Bool == true)
}

@Test func routingErrors() async {
    let (router, _) = makeRouter()
    #expect(await router.handle(req("GET", "/nope")).status == 404)
    #expect(await router.handle(req("PUT", "/nope")).status == 404)
    let wrong = await router.handle(req("POST", "/health"))
    #expect(wrong.status == 405)
    #expect(wrong.header("Allow") == "GET, OPTIONS")
    #expect(await router.handle(req("GET", "/scan")).header("Allow") == "POST, OPTIONS")
    #expect(await router.handle(req("HEAD", "/health")).status == 405)
    let unpaired = await router.handle(req("GET", "/scanners", origin: "null"))
    #expect(unpaired.status == 401)
    #expect(unpaired.header("Access-Control-Allow-Origin") == "null")
    #expect(await router.handle(req("GET", "/scanners", headers: ["Authorization": "Basic abc"])).status == 401)
    let errorBody = object(await router.handle(req("GET", "/nope")))
    #expect(errorBody["ok"] as? Bool == false && errorBody["partial"] as? Bool == false)
    #expect(!(errorBody["message"] as? String ?? "").isEmpty)
}

@Test func tokenComesBeforeBodyChecks() async {
    let (router, token) = makeRouter()
    let bad = HTTPRequest(method: "POST", path: "/scan", headers: [:], body: Data(),
                          bodyError: ProtocolError(400, "The request has an invalid Content-Length."))
    #expect(await router.handle(bad).status == 401)
    let badPaired = HTTPRequest(method: "POST", path: "/scan", headers: ["Authorization": "Bearer \(token)"],
                                body: Data(), bodyError: ProtocolError(400, "The request has an invalid Content-Length."))
    #expect(await router.handle(badPaired).status == 400)
}

@Test func scannersAndScan() async throws {
    let (router, token) = makeRouter()
    let list = object(await router.handle(req("GET", "/scanners", token: token)))["scanners"] as? [[String: Any]]
    #expect(list?.count == 7)
    let scan = await router.handle(req("POST", "/scan", origin: "http://localhost:8000", token: token,
                                       body: #"{"scanner":"fake:flatbed"}"#))
    #expect(scan.status == 200)
    #expect(scan.header("Access-Control-Allow-Origin") == "http://localhost:8000")
    #expect(scan.header("Vary") == "Origin")
    let files = object(scan)["files"] as? [[String: Any]]
    #expect(files?.count == 1 && files?[0]["pages"] as? Int == 1)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:empty"}"#)).status == 500)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:offline"}"#)).status == 503)
}

@Test func pairEndpoint() async {
    let (router, _) = makeRouter()
    let ok = object(await router.handle(req("POST", "/pair", body: #"{"code":"000000","client":"Test"}"#)))
    #expect(ok["ok"] as? Bool == true && (ok["token"] as? String)?.isEmpty == false)
    let refused = await router.handle(req("POST", "/pair", origin: "null", body: #"{"code":"000001"}"#))
    #expect(refused.status == 403)
    #expect(refused.header("Access-Control-Allow-Origin") == "null")
    #expect(await router.handle(req("POST", "/pair", body: "{not json")).status == 400)
}

@Test func secondScanWhileOneRunsIs409() async throws {
    let (router, token) = makeRouter()
    async let slow = router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:slow"}"#))
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed"}"#)).status == 409)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed","resolution":1}"#)).status == 422)
    #expect(await router.handle(req("GET", "/health")).status == 200)
    #expect(await slow.status == 200)
    #expect(await router.handle(req("POST", "/scan", token: token, body: #"{"scanner":"fake:flatbed"}"#)).status == 200)
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd macos && swift test`
Expected: build fails (`cannot find 'HTTPRequestParser' in scope`, `cannot find 'Router' in scope`).

- [ ] **Step 4: Implement**

`macos/Sources/HelperCore/HTTPMessage.swift`:

```swift
import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    /// Set when Content-Length was invalid or too large; reported only by endpoints that read the body.
    public var bodyError: ProtocolError?

    public init(method: String, path: String, headers: [String: String], body: Data, bodyError: ProtocolError?) {
        self.method = method
        self.path = path
        var lowered: [String: String] = [:]
        for (name, value) in headers where lowered[name.lowercased()] == nil { lowered[name.lowercased()] = value }
        self.headers = lowered
        self.body = body
        self.bodyError = bodyError
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public func jsonBody() throws -> Any {
        if let bodyError { throw bodyError }
        return try JSONBody.parse(body)
    }
}

/// Incremental HTTP/1.1 request parser: one request per connection.
public struct HTTPRequestParser {
    public static let maxHeaderBytes = 65_536
    public static let maxBody = 1_000_000

    public enum Result { case needMore, done(HTTPRequest), malformed }

    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], bodyStart: Int, length: Int)?

    public init() {}

    public mutating func feed(_ data: Data) -> Result {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > HTTPRequestParser.maxHeaderBytes ? .malformed : .needMore
            }
            guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1) else { return .malformed }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") || requestLine[1] == "*" else {
                return .malformed
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return .malformed }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if headers[name] == nil { headers[name] = value }
            }
            let target = String(requestLine[1])
            let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let method = String(requestLine[0])
            let bodyStart = end.upperBound - buffer.startIndex

            if let rawLength = headers["content-length"] {
                guard rawLength.range(of: "^[0-9]+$", options: .regularExpression) != nil, let length = Int(rawLength) else {
                    return .done(HTTPRequest(method: method, path: path, headers: headers, body: Data(),
                                             bodyError: ProtocolError(400, "The request has an invalid Content-Length.")))
                }
                guard length <= HTTPRequestParser.maxBody else {
                    return .done(HTTPRequest(method: method, path: path, headers: headers, body: Data(),
                                             bodyError: ProtocolError(400, "The request body is too large.")))
                }
                head = (method, path, headers, bodyStart, length)
            } else {
                head = (method, path, headers, bodyStart, 0)
            }
        }
        guard let head else { return .needMore }
        let available = buffer.count - head.bodyStart
        guard available >= head.length else { return .needMore }
        let start = buffer.startIndex + head.bodyStart
        let body = buffer.subdata(in: start..<(start + head.length))
        return .done(HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body, bodyError: nil))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }

    /// A JSON response; `origin` (an allowed Origin, or nil) adds the CORS headers.
    public static func json(_ status: Int, _ payload: [String: Any], origin: String?,
                            extraHeaders: [(String, String)] = []) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
        headers += extraHeaders
        if let origin { headers += [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    static let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 422: "Unprocessable Entity",
                          500: "Internal Server Error", 503: "Service Unavailable"]

    /// The bytes to send. `includeBody: false` for HEAD (headers still give the would-be length).
    public func serialized(includeBody: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "Status")\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        if includeBody { data.append(body) }
        return data
    }
}
```

`macos/Sources/HelperCore/Origins.swift`:

```swift
import Foundation

/// PROTOCOL.md "Origins (CORS)": no Origin, "null", or plain-http localhost / 127.0.0.1 on port 1-65535.
public enum Origins {
    public static func allowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        if origin == "null" { return true }
        guard let match = origin.range(of: #"^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$"#, options: .regularExpression),
              match == origin.startIndex..<origin.endIndex else { return false }
        guard let colon = origin.dropFirst("http://".count).firstIndex(of: ":") else { return true }
        guard let port = Int(origin[origin.index(after: colon)...]) else { return false }
        return (1...65535).contains(port)
    }
}
```

`macos/Sources/HelperCore/Router.swift`:

```swift
import Foundation

actor ScanGate {
    private var busy = false
    func tryBegin() -> Bool { if busy { return false }; busy = true; return true }
    func end() { busy = false }
}

/// Turns a request into a response, following PROTOCOL.md. Knows nothing about sockets.
public final class Router: @unchecked Sendable {
    static let endpoints = ["/health": "GET", "/scanners": "GET", "/scan": "POST", "/pair": "POST"]
    static let needsToken: Set<String> = ["/scanners", "/scan"]

    private let backend: ScannerBackend
    private let pairing: PairingStore
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let gate = ScanGate()

    public init(backend: ScannerBackend, pairing: PairingStore, now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.backend = backend; self.pairing = pairing; self.now = now; self.log = log
    }

    public static func errorBody(_ message: String) -> [String: Any] { ["ok": false, "partial": false, "message": message] }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let origin = request.header("origin")
        guard Origins.allowed(origin) else {
            return .json(403, Router.errorBody("This origin may not use the scan helper."), origin: nil)
        }
        if request.method == "OPTIONS" { return preflight(request, origin: origin) }
        guard let method = Router.endpoints[request.path] else {
            return .json(404, Router.errorBody("Unknown endpoint."), origin: origin)
        }
        guard request.method == method else {
            return .json(405, Router.errorBody("Use \(method) for this endpoint."), origin: origin,
                         extraHeaders: [("Allow", "\(method), OPTIONS")])
        }
        let paired = pairing.isValid(token: Router.bearerToken(request.header("authorization")))
        if Router.needsToken.contains(request.path) && !paired {
            return .json(401, Router.errorBody(
                "This browser isn't paired with the scan helper. Pair it in Dossiary's scan dialog."), origin: origin)
        }
        do {
            switch request.path {
            case "/health":
                return .json(200, ["ok": true, "helper": HelperVersion.helperName, "version": HelperVersion.string,
                                   "protocol": 2, "paired": paired], origin: origin)
            case "/scanners":
                let scanners = await backend.listScanners()
                return .json(200, ["scanners": scanners.map(\.json)], origin: origin)
            case "/pair":
                let (code, client) = try PairingStore.validatePairBody(try request.jsonBody())
                let token = try pairing.pair(code: code, client: client)
                log("Paired a browser\(client.map { " (\($0))" } ?? "").")
                return .json(200, ["ok": true, "token": token], origin: origin)
            default:
                return try await scan(request, origin: origin)
            }
        } catch let error as ProtocolError {
            if error.status >= 500 { log("\(request.path): \(error.status) \(error.message)") }
            return .json(error.status, Router.errorBody(error.message), origin: origin)
        } catch {
            log("\(request.path): unexpected error \(error)")
            return .json(500, Router.errorBody("The scan helper hit an unexpected error: \(error.localizedDescription)"),
                         origin: origin)
        }
    }

    private func scan(_ request: HTTPRequest, origin: String?) async throws -> HTTPResponse {
        let body = try request.jsonBody()
        let (scanner, settings) = try ScanRequestValidator.validate(body, scanners: await backend.listScanners())
        guard await gate.tryBegin() else {
            throw ProtocolError(409, "Another scan is still running. Try again when it has finished.")
        }
        let result: ScanDocuments
        do {
            log("Scanning with \(scanner.name): \(settings.source.rawValue), \(settings.colorMode.rawValue), \(settings.resolution) dpi\(settings.duplex ? ", both sides" : "").")
            result = try await backend.scan(scannerID: scanner.id, settings: settings)
        } catch {
            await gate.end()
            throw error
        }
        await gate.end()
        let payload = try ScanResponse.payload(result, date: now())
        log(payload["message"] as? String ?? "Scan finished.")
        return .json(200, payload, origin: origin)
    }

    private func preflight(_ request: HTTPRequest, origin: String?) -> HTTPResponse {
        var headers: [(String, String)] = []
        if let origin { headers += [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")] }
        headers += [("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                    ("Access-Control-Allow-Headers", "Content-Type, Authorization"),
                    ("Access-Control-Max-Age", "600")]
        if request.header("access-control-request-private-network") == "true" {
            headers.append(("Access-Control-Allow-Private-Network", "true"))
        }
        return HTTPResponse(status: 204, headers: headers, body: Data())
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd macos && swift test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/HelperCore macos/Tests/HelperCoreTests
git commit -m "macOS helper: HTTP request parser, responses, origin check and protocol router"
```

---

### Task 5: Listener, log, command line, headless mode, conformance suite in CI

**Files:**
- Create: `macos/Sources/HelperCore/HTTPServer.swift`, `Log.swift`, `CommandLineOptions.swift`, `HelperRuntime.swift`
- Create: `macos/Sources/App/main.swift`
- Create: `macos/scripts/run-conformance.sh` (executable)
- Create: `macos/Tests/HelperCoreTests/ServerTests.swift`, `OptionsTests.swift`
- Modify: `macos/Package.swift` (add the executable target), `.github/workflows/conformance.yml` (add the `macos-helper` job)

**Interfaces:**
- Consumes: `Router`, `HTTPRequestParser`, `HTTPResponse`, `FakeBackend`, `PairingStore`.
- Produces:
  - `final class HTTPServer { init(port: UInt16, router: Router, log: @escaping @Sendable (String) -> Void); func start() throws; func stop(); var boundPort: UInt16? }` — `port: 0` picks a free port (tests).
  - `final class Log { static let shared: Log; static var defaultURL: URL; init(url:maxBytes:); var echoToStderr: Bool; func write(_ message: String) }`
  - `struct CommandLineOptions: Equatable { var fakeScanners = false; var headless = false; var port: UInt16 = 8766; var showVersion = false; var showHelp = false; static let usage: String; static func parse(_ arguments: [String]) throws -> CommandLineOptions }` and `struct UsageError: Error { let message: String }`.
  - `final class HelperRuntime { init(options: CommandLineOptions, log: Log = .shared) throws; let options; let backend: ScannerBackend; let pairing: PairingStore; let router: Router; let server: HTTPServer; func start() throws }`

- [ ] **Step 1: Add the executable target**

In `macos/Package.swift`, add to `targets`, after the `HelperCore` target:

```swift
        .executableTarget(name: "dossiary-scan-helper", dependencies: ["HelperCore"], path: "Sources/App"),
```

- [ ] **Step 2: Write the failing tests**

`macos/Tests/HelperCoreTests/OptionsTests.swift`:

```swift
import Testing
@testable import HelperCore

@Test func defaults() throws {
    #expect(try CommandLineOptions.parse([]) == CommandLineOptions())
    #expect(CommandLineOptions().port == 8766)
}

@Test func flags() throws {
    let options = try CommandLineOptions.parse(["--fake-scanners", "--headless", "--port", "9000"])
    #expect(options.fakeScanners && options.headless && options.port == 9000)
    #expect(try CommandLineOptions.parse(["--version"]).showVersion)
    #expect(try CommandLineOptions.parse(["-h"]).showHelp)
    #expect(try CommandLineOptions.parse(["-psn_0_12345"]) == CommandLineOptions())
}

@Test func badArguments() {
    for arguments in [["--port"], ["--port", "0"], ["--port", "65536"], ["--port", "x"], ["--host", "0.0.0.0"], ["extra"]] {
        #expect(throws: UsageError.self) { try CommandLineOptions.parse(arguments) }
    }
}
```

`macos/Tests/HelperCoreTests/ServerTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

@Test func serverAnswersOnLoopback() async throws {
    let router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake))
    let server = HTTPServer(port: 0, router: router, log: { _ in })
    try server.start()
    defer { server.stop() }
    let port = try #require(server.boundPort)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.setValue("null", forHTTPHeaderField: "Origin")
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "null")
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["protocol"] as? Int == 2)
}

@Test func secondServerOnTheSamePortFailsToStart() throws {
    let router = Router(backend: FakeBackend(), pairing: PairingStore(mode: .fake))
    let first = HTTPServer(port: 0, router: router, log: { _ in })
    try first.start()
    defer { first.stop() }
    let second = HTTPServer(port: try #require(first.boundPort), router: router, log: { _ in })
    #expect(throws: (any Error).self) { try second.start() }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd macos && swift test`
Expected: build fails (`cannot find 'CommandLineOptions' in scope`, `cannot find 'HTTPServer' in scope`; the empty `Sources/App` may also fail — create `main.swift` in Step 4).

- [ ] **Step 4: Implement**

`macos/Sources/HelperCore/HTTPServer.swift`:

```swift
import Foundation
import Network

public struct ServerError: Error, CustomStringConvertible {
    public let description: String
}

/// HTTP/1.1 on 127.0.0.1 only, one request per connection.
public final class HTTPServer: @unchecked Sendable {
    private let port: UInt16
    private let router: Router
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dossiary-scan-helper.http")
    private var listener: NWListener?

    public init(port: UInt16, router: Router, log: @escaping @Sendable (String) -> Void) {
        self.port = port; self.router = router; self.log = log
    }

    public var boundPort: UInt16? { listener?.port?.rawValue }

    /// Binds and waits until listening; throws if the port is taken.
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let settled = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: settled.signal()
            case .failed(let error), .waiting(let error): failure.error = error; settled.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError(description: "The server didn't start within 5 seconds.")
        }
        if let error = failure.error {
            listener.cancel()
            throw ServerError(description: "Port \(port) on 127.0.0.1 isn't available (\(error)). Is the helper already running?")
        }
        listener.stateUpdateHandler = { [log] state in if case .failed(let error) = state { log("Server stopped: \(error)") } }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private final class FailureBox: @unchecked Sendable { var error: Error? }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, parser: HTTPRequestParser())
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var parser = parser
            if let data, !data.isEmpty {
                switch parser.feed(data) {
                case .needMore:
                    break
                case .malformed:
                    self.send(.json(400, Router.errorBody("The request isn't valid HTTP."), origin: nil),
                              on: connection, includeBody: true)
                    return
                case .done(let request):
                    let router = self.router
                    Task {
                        let response = await router.handle(request)
                        self.send(response, on: connection, includeBody: request.method != "HEAD")
                    }
                    return
                }
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.receive(on: connection, parser: parser)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, includeBody: Bool) {
        connection.send(content: response.serialized(includeBody: includeBody), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
```

If `NWListener(using:)` with `requiredLocalEndpoint` refuses to start or the port test fails, switch to `NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)` with `parameters.requiredInterfaceType = .loopback` instead, and keep the Step 6 `lsof` check: the listening socket must show `127.0.0.1:8766`, never `*:8766`.

`macos/Sources/HelperCore/Log.swift`:

```swift
import Foundation

/// Appends timestamped lines to ~/Library/Logs/dossiary-scan-helper/helper.log (rotated at 5 MB).
/// Never pass tokens, pairing codes or page data to it.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/dossiary-scan-helper/helper.log")
    }

    public var echoToStderr = false
    public let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(url: URL = Log.defaultURL, maxBytes: Int = 5_000_000) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }

    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
```

`macos/Sources/HelperCore/CommandLineOptions.swift`:

```swift
import Foundation

public struct UsageError: Error { public let message: String }

public struct CommandLineOptions: Equatable {
    public var fakeScanners = false
    public var headless = false
    public var port: UInt16 = 8766
    public var showVersion = false
    public var showHelp = false

    public init() {}

    public static let usage = """
        Usage: dossiary-scan-helper [--fake-scanners] [--headless] [--port N]
          --fake-scanners  the protocol's seven fake scanners instead of real ones (testing only;
                           pairing code 000000)
          --headless       no menu bar icon; log to the terminal too (CI and development)
          --port N         listen on 127.0.0.1:N instead of 8766
          --version, --help
        """

    public static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--fake-scanners": options.fakeScanners = true
            case "--headless": options.headless = true
            case "--version": options.showVersion = true
            case "-h", "--help": options.showHelp = true
            case "--port":
                guard let value = rest.popFirst(), let port = Int(value), (1...65535).contains(port) else {
                    throw UsageError(message: "--port needs a number from 1 to 65535.")
                }
                options.port = UInt16(port)
            default:
                if argument.hasPrefix("-psn_") { continue }  // added by older Launch Services
                throw UsageError(message: "Unknown argument: \(argument)")
            }
        }
        return options
    }
}
```

`macos/Sources/HelperCore/HelperRuntime.swift`:

```swift
import Foundation

/// The helper's parts, wired together. Shared by the menu bar app and --headless.
public final class HelperRuntime: @unchecked Sendable {
    public let options: CommandLineOptions
    public let backend: ScannerBackend
    public let pairing: PairingStore
    public let router: Router
    public let server: HTTPServer
    private let log: Log

    public init(options: CommandLineOptions, log: Log = .shared) throws {
        self.options = options
        self.log = log
        if options.fakeScanners {
            backend = FakeBackend()
            pairing = PairingStore(mode: .fake)
        } else {
            throw UsageError(message: "Real scanners arrive in a later build. Run with --fake-scanners.")
        }
        let write: @Sendable (String) -> Void = { [log] in log.write($0) }
        router = Router(backend: backend, pairing: pairing, log: write)
        server = HTTPServer(port: options.port, router: router, log: write)
    }

    public func start() throws {
        try server.start()
        log.write("Dossiary Scan Helper \(HelperVersion.string) listening on 127.0.0.1:\(options.port)"
                  + (options.fakeScanners ? " with fake scanners." : "."))
    }
}
```

(Task 7 replaces the `else` branch with the real ImageCaptureCore backend.)

`macos/Sources/App/main.swift`:

```swift
import Foundation
import HelperCore

let options: CommandLineOptions
do {
    options = try CommandLineOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as UsageError {
    FileHandle.standardError.write(Data("\(error.message)\n\(CommandLineOptions.usage)\n".utf8))
    exit(2)
}
if options.showVersion { print("dossiary-scan-helper \(HelperVersion.string)"); exit(0) }
if options.showHelp { print(CommandLineOptions.usage); exit(0) }

Log.shared.echoToStderr = options.headless
let runtime: HelperRuntime
do {
    runtime = try HelperRuntime(options: options)
    try runtime.start()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
print("Dossiary Scan Helper on http://127.0.0.1:\(options.port)\(options.fakeScanners ? " (fake scanners, pairing code 000000)" : ""). Ctrl+C stops it.")
RunLoop.main.run()
```

(Task 6 turns the non-headless path into the menu bar app.)

`macos/scripts/run-conformance.sh` (make it executable with `chmod +x`):

```bash
#!/bin/bash
# Builds the helper, starts it with fake scanners and runs the repo's conformance suite against it.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8766}"
swift build
.build/debug/dossiary-scan-helper --headless --fake-scanners --port "$PORT" > .build/conformance-helper.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/health" > /dev/null; then break; fi
  sleep 0.2
done
curl -sf "http://127.0.0.1:$PORT/health" > /dev/null || { echo "helper did not start"; cat .build/conformance-helper.log; exit 1; }
cd ..
SCAN_HELPER_URL="http://127.0.0.1:$PORT" python3 -m unittest discover -s conformance -v
```

Append this job to `.github/workflows/conformance.yml` under `jobs:` (same indentation as `reference-helper`):

```yaml
  macos-helper:
    timeout-minutes: 20
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Unit tests
        working-directory: macos
        run: swift test
      - name: Conformance suite against the helper with fake scanners
        working-directory: macos
        run: scripts/run-conformance.sh
```

- [ ] **Step 5: Run the unit tests**

Run: `cd macos && swift test`
Expected: all tests pass, including `ServerTests` and `OptionsTests`.

- [ ] **Step 6: Run the conformance suite and check the bind address**

Make sure nothing else listens on 8766 first (`lsof -nP -iTCP:8766 -sTCP:LISTEN` prints nothing; stop the reference helper if it does). Then:

Run: `cd macos && scripts/run-conformance.sh`
Expected: `Ran <n> tests ... OK` — every conformance test passes. Fix any failure in the Swift code, not in the suite; the suite and the reference helper are the contract.

Then check the address while the helper runs:

```bash
cd macos && .build/debug/dossiary-scan-helper --headless --fake-scanners --port 8766 & sleep 1
lsof -nP -iTCP:8766 -sTCP:LISTEN; kill %1
```

Expected: the `NAME` column shows `127.0.0.1:8766`, not `*:8766`.

- [ ] **Step 7: Commit**

```bash
git add macos .github/workflows/conformance.yml
git commit -m "macOS helper: loopback listener, log, command line, headless mode; conformance suite in CI"
```

---

### Task 6: Menu bar app

**Files:**
- Create: `macos/Sources/HelperCore/MenuModel.swift`, `macos/Tests/HelperCoreTests/MenuModelTests.swift`
- Create: `macos/Sources/App/AppDelegate.swift`, `PairingPanel.swift`, `LoginItem.swift`
- Modify: `macos/Sources/App/main.swift`

**Interfaces:**
- Consumes: `HelperRuntime` (`backend`, `pairing`, `options`, `start()`), `ScannerBackend.setChangeHandler`, `PairingStore` (`openWindow`, `activeCode`, `secondsLeft`, `closeWindow`, `pairedCount`, `forgetAll`, `isFake`), `Log.shared.url`.
- Produces: `enum MenuAction { pair, forget, startAtLogin, openLog, quit }`; `enum MenuEntry: Equatable { case title(String), info(String), separator, action(String, MenuAction, checked: Bool, enabled: Bool) }`; `MenuModel.entries(scanners: [ScannerInfo], port: UInt16, fake: Bool, pairedCount: Int, startAtLogin: Bool?) -> [MenuEntry]` (`startAtLogin == nil`: not running from an app bundle, the item is disabled).

Menu, top to bottom: "Dossiary Scan Helper" (+ " — fake scanners"), "Listening on 127.0.0.1:<port>", separator, one disabled line per scanner name or "No scanners found", separator, "Pair a browser…", "Forget paired browsers (<n>)" (disabled at 0), separator, "Start at login" (checkmark), "Open log", separator, "Quit Dossiary Scan Helper".

- [ ] **Step 1: Write the failing test**

`macos/Tests/HelperCoreTests/MenuModelTests.swift`:

```swift
import Testing
@testable import HelperCore

@Test func menuWithScanners() {
    let entries = MenuModel.entries(scanners: Array(FakeScanners.infos.prefix(2)), port: 8766, fake: false,
                                    pairedCount: 2, startAtLogin: true)
    #expect(entries == [
        .title("Dossiary Scan Helper"),
        .info("Listening on 127.0.0.1:8766"),
        .separator,
        .info("Fake Flatbed"),
        .info("Fake Feeder"),
        .separator,
        .action("Pair a browser…", .pair, checked: false, enabled: true),
        .action("Forget paired browsers (2)", .forget, checked: false, enabled: true),
        .separator,
        .action("Start at login", .startAtLogin, checked: true, enabled: true),
        .action("Open log", .openLog, checked: false, enabled: true),
        .separator,
        .action("Quit Dossiary Scan Helper", .quit, checked: false, enabled: true),
    ])
}

@Test func menuWithoutScannersOrBundle() {
    let entries = MenuModel.entries(scanners: [], port: 9000, fake: true, pairedCount: 0, startAtLogin: nil)
    #expect(entries[0] == .title("Dossiary Scan Helper — fake scanners"))
    #expect(entries.contains(.info("No scanners found")))
    #expect(entries.contains(.action("Forget paired browsers (0)", .forget, checked: false, enabled: false)))
    #expect(entries.contains(.action("Start at login", .startAtLogin, checked: false, enabled: false)))
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd macos && swift test --filter MenuModelTests`
Expected: build fails (`cannot find 'MenuModel' in scope`).

- [ ] **Step 3: Implement the model**

`macos/Sources/HelperCore/MenuModel.swift`:

```swift
public enum MenuAction: Equatable, Sendable { case pair, forget, startAtLogin, openLog, quit }

public enum MenuEntry: Equatable, Sendable {
    case title(String)
    case info(String)
    case separator
    case action(String, MenuAction, checked: Bool, enabled: Bool)
}

/// The status menu as data, so it can be tested without AppKit.
public enum MenuModel {
    public static func entries(scanners: [ScannerInfo], port: UInt16, fake: Bool, pairedCount: Int,
                               startAtLogin: Bool?) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .title(fake ? "Dossiary Scan Helper — fake scanners" : "Dossiary Scan Helper"),
            .info("Listening on 127.0.0.1:\(port)"),
            .separator,
        ]
        entries += scanners.isEmpty ? [.info("No scanners found")] : scanners.map { .info($0.name) }
        entries += [
            .separator,
            .action("Pair a browser…", .pair, checked: false, enabled: true),
            .action("Forget paired browsers (\(pairedCount))", .forget, checked: false, enabled: pairedCount > 0),
            .separator,
            .action("Start at login", .startAtLogin, checked: startAtLogin == true, enabled: startAtLogin != nil),
            .action("Open log", .openLog, checked: false, enabled: true),
            .separator,
            .action("Quit Dossiary Scan Helper", .quit, checked: false, enabled: true),
        ]
        return entries
    }
}
```

- [ ] **Step 4: Run the test to see it pass**

Run: `cd macos && swift test --filter MenuModelTests`
Expected: both tests pass.

- [ ] **Step 5: Implement the AppKit shell**

`macos/Sources/App/LoginItem.swift`:

```swift
import Foundation
import ServiceManagement

/// "Start at login" through SMAppService; only possible when running from the .app bundle.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
```

`macos/Sources/App/PairingPanel.swift`:

```swift
import AppKit
import HelperCore

/// A small window showing the pairing code and how long it stays valid. Closes when the code is used or expires.
final class PairingPanel: NSPanel {
    private let pairing: PairingStore
    private let codeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(pairing: PairingStore) {
        self.pairing = pairing
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 170),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Pair a browser"
        isReleasedWhenClosed = false
        level = .floating
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeLabel.alignment = .center
        detailLabel.alignment = .center
        let stack = NSStackView(views: [codeLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    func show() {
        _ = pairing.openWindow()
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func update() {
        guard let code = pairing.activeCode else { finish(); return }
        codeLabel.stringValue = code
        if pairing.isFake {
            detailLabel.stringValue = "Fake scanner mode: this code always works."
        } else {
            detailLabel.stringValue = "Type this code in Dossiary's scan dialog.\nIt works for \(pairing.secondsLeft ?? 0) more seconds."
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    override func close() {
        if !pairing.isFake { pairing.closeWindow() }
        finish()
        super.close()
    }
}
```

`macos/Sources/App/AppDelegate.swift`:

```swift
import AppKit
import HelperCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let runtime: HelperRuntime
    private var statusItem: NSStatusItem?
    private var scanners: [ScannerInfo] = []
    private lazy var pairingPanel = PairingPanel(pairing: runtime.pairing)

    init(runtime: HelperRuntime) { self.runtime = runtime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try runtime.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Dossiary Scan Helper couldn't start"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Dossiary Scan Helper")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        runtime.backend.setChangeHandler { [weak self] in DispatchQueue.main.async { self?.refreshScanners() } }
        refreshScanners()
    }

    private func refreshScanners() {
        Task { [weak self] in
            guard let self else { return }
            let list = await runtime.backend.listScanners()
            await MainActor.run { self.scanners = list }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshScanners()
        menu.removeAllItems()
        let entries = MenuModel.entries(scanners: scanners, port: runtime.options.port, fake: runtime.options.fakeScanners,
                                        pairedCount: runtime.pairing.pairedCount,
                                        startAtLogin: LoginItem.isAvailable ? LoginItem.isEnabled : nil)
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .title(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                item.isEnabled = false
                menu.addItem(item)
            case .info(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .action(let text, let action, let checked, let enabled):
                let item = NSMenuItem(title: text, action: enabled ? #selector(perform(_:)) : nil,
                                      keyEquivalent: action == .quit ? "q" : "")
                item.target = self
                item.representedObject = action
                item.state = checked ? .on : .off
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
    }

    @objc private func perform(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .pair:
            pairingPanel.show()
        case .forget:
            runtime.pairing.forgetAll()
            Log.shared.write("Forgot all paired browsers.")
        case .startAtLogin:
            do { try LoginItem.set(!LoginItem.isEnabled) } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        case .openLog:
            NSWorkspace.shared.open(Log.shared.url)
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
```

Replace the end of `macos/Sources/App/main.swift` (from `Log.shared.echoToStderr = ...` down) with:

```swift
Log.shared.echoToStderr = options.headless
let runtime: HelperRuntime
do {
    runtime = try HelperRuntime(options: options)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

if options.headless {
    do { try runtime.start() } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
    print("Dossiary Scan Helper on http://127.0.0.1:\(options.port)\(options.fakeScanners ? " (fake scanners, pairing code 000000)" : ""). Ctrl+C stops it.")
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(runtime: runtime)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
```

and add `import AppKit` at the top of `main.swift`.

- [ ] **Step 6: Build, test, and check the menu by hand**

Run: `cd macos && swift test && swift build`
Expected: all tests pass, the build succeeds.

Then run `.build/debug/dossiary-scan-helper --fake-scanners` and check, by eye:
- a scanner icon appears in the menu bar, and no Dock icon;
- the menu shows "Dossiary Scan Helper — fake scanners", "Listening on 127.0.0.1:8766", the seven fake scanner names, "Forget paired browsers (0)" greyed out, and "Start at login" greyed out (no app bundle yet);
- "Pair a browser…" shows `000000`;
- `curl -s -X POST -d '{"code":"000000"}' http://127.0.0.1:8766/pair` returns a token, and the menu then shows "Forget paired browsers (1)"; choosing it brings the count back to 0;
- "Open log" opens `helper.log`; "Quit" ends the process.

Report what you saw in the task report. If you can't see the screen (no GUI session), say so: the controller will ask the owner to do this check.

- [ ] **Step 7: Commit**

```bash
git add macos
git commit -m "macOS helper: menu bar app with scanner list, pairing window, forget, start at login, log"
```

---

### Task 7: Real scanners through ImageCaptureCore

**Files:**
- Create: `macos/Sources/HelperCore/Callbacks.swift`, `CapabilityMapping.swift`, `ScanOutcome.swift`, `ImageCaptureBackend.swift`
- Create: `macos/Tests/HelperCoreTests/CallbackTests.swift`, `CapabilityMappingTests.swift`, `ScanOutcomeTests.swift`
- Modify: `macos/Sources/HelperCore/HelperRuntime.swift`

**Interfaces:**
- Consumes: `ScannerBackend`, `ScannerInfo`, `ScanSettings`, `ScanDocuments`, `PageImage`, `ProtocolError`, `PairingStore.defaultFileURL`, `Log`.
- Produces:
  - `final class Once<T: Sendable> { func resume(_ result: Result<T, Error>) }` and `func awaitCallback<T: Sendable>(timeout: TimeInterval?, _ start: (Once<T>) -> Void) async throws -> T`; `struct CallbackTimeout: Error`.
  - `struct UnitCapabilities: Equatable { source: Source; duplex: Bool; bitDepths: [Int]; resolutions: [Int]; preferredResolutions: [Int] }`
  - `CapabilityMapping.scannerID(persistentID: String?, uuid: String?, name: String) -> String`; `CapabilityMapping.scannerInfo(id: String, name: String, units: [UnitCapabilities]) -> ScannerInfo?`; `CapabilityMapping.standardResolutions`.
  - `ScanOutcome.documents(pages: [PageImage], errorMessage: String?, source: Source) throws -> ScanDocuments`
  - `final class ImageCaptureBackend: NSObject, ScannerBackend` with `init(log: @escaping @Sendable (String) -> Void)` and `func start()` (call on the main thread).

How capabilities become a `ScannerInfo` (`CapabilityMapping.scannerInfo`):
- No flatbed or feeder unit → `nil` (not offered).
- `sources`: `feeder` first when there is one (the default for document scanning), then `flatbed`.
- `duplex`: the feeder unit's `supportsDuplexScanning`.
- `colorModes`: `color` and `gray` when any unit supports 8-bit depth or reports no depths; `bw` added when any unit supports 1-bit; `[color]` if that leaves nothing.
- `resolutions`: per unit, the supported resolutions that are in `standardResolutions` (`[75, 100, 150, 200, 240, 300, 400, 600, 1200]`), else its preferred resolutions, else its supported ones; then the values every unit offers (so any source/resolution pair works), or the first unit's list if they share none; sorted ascending; `[300]` if nothing is known.
- `extras`: `[]` — ImageCaptureCore has no blank-page handling.
- `id`: `"ic:" + (persistentID ?? uuid ?? name)`.

How a finished scan becomes a result (`ScanOutcome.documents`):
- pages and no error → `ScanDocuments(documents: [pages], partialMessage: nil)`;
- pages and an error → partial, message `"The scan stopped after <n> page(s): <error>. The pages before it were kept."` (`page` for 1);
- no pages and an error → `ProtocolError(500, "The scan failed: <error>")`;
- no pages, no error → `ProtocolError(500, "No paper in the feeder.")` for the feeder, `ProtocolError(500, "The scanner returned no pages.")` for the flatbed.

- [ ] **Step 1: Write the failing tests**

`macos/Tests/HelperCoreTests/CallbackTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

@Test func callbackResumesOnce() async throws {
    let value: Int = try await awaitCallback(timeout: nil) { once in
        DispatchQueue.main.async {
            once.resume(.success(1))
            once.resume(.success(2))  // ignored
        }
    }
    #expect(value == 1)
}

@Test func callbackTimesOut() async {
    do {
        let _: Int = try await awaitCallback(timeout: 0.1) { _ in }
        Issue.record("expected a timeout")
    } catch {
        #expect(error is CallbackTimeout)
    }
}
```

`macos/Tests/HelperCoreTests/CapabilityMappingTests.swift`:

```swift
import Testing
@testable import HelperCore

private let continuous = Array(50...1200)

@Test func ids() {
    #expect(CapabilityMapping.scannerID(persistentID: "P1", uuid: "U1", name: "HP") == "ic:P1")
    #expect(CapabilityMapping.scannerID(persistentID: nil, uuid: "U1", name: "HP") == "ic:U1")
    #expect(CapabilityMapping.scannerID(persistentID: nil, uuid: nil, name: "HP") == "ic:HP")
}

@Test func feederAndFlatbed() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:1", name: "HP ENVY", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [1, 8], resolutions: continuous, preferredResolutions: [300]),
        UnitCapabilities(source: .feeder, duplex: true, bitDepths: [8], resolutions: [150, 300, 600], preferredResolutions: []),
    ]))
    #expect(info.sources == [.feeder, .flatbed])
    #expect(info.duplex)
    #expect(info.colorModes == [.color, .gray, .bw])
    #expect(info.resolutions == [150, 300, 600])
    #expect(info.extras == [])
}

@Test func flatbedOnlyWithOddResolutions() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:2", name: "Old", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [], resolutions: [72, 144], preferredResolutions: [144]),
    ]))
    #expect(info.sources == [.flatbed])
    #expect(!info.duplex)
    #expect(info.colorModes == [.color, .gray])
    #expect(info.resolutions == [144])
}

@Test func noUsableUnits() {
    #expect(CapabilityMapping.scannerInfo(id: "ic:3", name: "Film", units: []) == nil)
}

@Test func unitsWithoutCommonResolutionsUseTheFirst() throws {
    let info = try #require(CapabilityMapping.scannerInfo(id: "ic:4", name: "X", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [600], preferredResolutions: []),
        UnitCapabilities(source: .feeder, duplex: false, bitDepths: [8], resolutions: [200], preferredResolutions: []),
    ]))
    #expect(info.resolutions == [600])
    #expect(CapabilityMapping.scannerInfo(id: "ic:5", name: "Y", units: [
        UnitCapabilities(source: .flatbed, duplex: false, bitDepths: [8], resolutions: [], preferredResolutions: []),
    ])?.resolutions == [300])
}
```

`macos/Tests/HelperCoreTests/ScanOutcomeTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

private let page = PageImage(data: Data([1]), dpi: 300)

private func status(_ block: () throws -> Void) -> ProtocolError? {
    do { try block(); return nil } catch let error as ProtocolError { return error } catch { return ProtocolError(-1, "") }
}

@Test func pagesWithoutError() throws {
    let result = try ScanOutcome.documents(pages: [page, page], errorMessage: nil, source: .feeder)
    #expect(result.documents.count == 1 && result.documents[0].count == 2)
    #expect(result.partialMessage == nil)
}

@Test func pagesThenError() throws {
    let result = try ScanOutcome.documents(pages: [page], errorMessage: "Paper jam", source: .feeder)
    #expect(result.partialMessage == "The scan stopped after 1 page: Paper jam. The pages before it were kept.")
}

@Test func noPages() {
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: "Device busy", source: .flatbed) }
            == ProtocolError(500, "The scan failed: Device busy"))
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: nil, source: .feeder) }
            == ProtocolError(500, "No paper in the feeder."))
    #expect(status { _ = try ScanOutcome.documents(pages: [], errorMessage: nil, source: .flatbed) }
            == ProtocolError(500, "The scanner returned no pages."))
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd macos && swift test`
Expected: build fails (`cannot find 'awaitCallback' in scope`, `cannot find 'CapabilityMapping' in scope`, `cannot find 'ScanOutcome' in scope`).

- [ ] **Step 3: Implement the pure parts**

`macos/Sources/HelperCore/Callbacks.swift`:

```swift
import Foundation

public struct CallbackTimeout: Error, CustomStringConvertible {
    public var description: String { "The scanner didn't answer in time." }
}

/// Resumes a continuation at most once: the first of a delegate callback and a timeout wins.
public final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    public func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Bridges a callback-style request to async. `start` gets the Once to resume; `timeout` nil waits forever.
public func awaitCallback<T: Sendable>(timeout: TimeInterval?, _ start: (Once<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = Once(continuation)
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(CallbackTimeout())) }
        }
        start(once)
    }
}
```

`macos/Sources/HelperCore/CapabilityMapping.swift`:

```swift
import Foundation

/// What one functional unit (flatbed or document feeder) reported.
public struct UnitCapabilities: Equatable, Sendable {
    public var source: Source
    public var duplex: Bool
    public var bitDepths: [Int]
    public var resolutions: [Int]
    public var preferredResolutions: [Int]

    public init(source: Source, duplex: Bool, bitDepths: [Int], resolutions: [Int], preferredResolutions: [Int]) {
        self.source = source; self.duplex = duplex; self.bitDepths = bitDepths
        self.resolutions = resolutions; self.preferredResolutions = preferredResolutions
    }
}

/// ImageCaptureCore capabilities -> protocol values. Pure, so it can be tested without a scanner.
public enum CapabilityMapping {
    public static let standardResolutions = [75, 100, 150, 200, 240, 300, 400, 600, 1200]

    public static func scannerID(persistentID: String?, uuid: String?, name: String) -> String {
        "ic:" + (persistentID ?? uuid ?? name)
    }

    public static func scannerInfo(id: String, name: String, units: [UnitCapabilities]) -> ScannerInfo? {
        let ordered = units.filter { $0.source == .feeder } + units.filter { $0.source == .flatbed }
        guard !ordered.isEmpty else { return nil }

        let depths = Set(ordered.flatMap(\.bitDepths))
        var colorModes: [ColorMode] = []
        if depths.isEmpty || depths.contains(8) { colorModes += [.color, .gray] }
        if depths.contains(1) { colorModes.append(.bw) }
        if colorModes.isEmpty { colorModes = [.color] }

        let perUnit = ordered.map { unit -> [Int] in
            let standard = unit.resolutions.filter { standardResolutions.contains($0) }
            if !standard.isEmpty { return standard }
            if !unit.preferredResolutions.isEmpty { return unit.preferredResolutions }
            return unit.resolutions
        }
        var common = Set(perUnit[0])
        for list in perUnit.dropFirst() { common.formIntersection(list) }
        var resolutions = (common.isEmpty ? Set(perUnit[0]) : common).sorted()
        if resolutions.isEmpty { resolutions = [300] }

        return ScannerInfo(id: id, name: name, sources: ordered.map(\.source),
                           duplex: ordered.first { $0.source == .feeder }?.duplex ?? false,
                           colorModes: colorModes, resolutions: resolutions, extras: [])
    }
}
```

`macos/Sources/HelperCore/ScanOutcome.swift`:

```swift
import Foundation

/// A finished real scan -> the response's documents, or the error to answer with.
public enum ScanOutcome {
    public static func documents(pages: [PageImage], errorMessage: String?, source: Source) throws -> ScanDocuments {
        if pages.isEmpty {
            if let errorMessage { throw ProtocolError(500, "The scan failed: \(errorMessage)") }
            throw ProtocolError(500, source == .feeder ? FakeScanners.emptyFeederMessage : "The scanner returned no pages.")
        }
        guard let errorMessage else { return ScanDocuments(documents: [pages], partialMessage: nil) }
        let count = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        return ScanDocuments(documents: [pages],
                             partialMessage: "The scan stopped after \(count): \(errorMessage). The pages before it were kept.")
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd macos && swift test`
Expected: all tests pass.

- [ ] **Step 5: Implement the ImageCaptureCore backend**

Check each ImageCaptureCore name below against the SDK before relying on it — the compiler is the authority, and the headers are at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ImageCaptureCore.framework/Headers/` (`ICDeviceBrowser.h`, `ICDevice.h`, `ICScannerDevice.h`, `ICScannerFunctionalUnits.h`). If a Swift name differs (for example an enum case spelling), use the SDK's and note it in the report. Every ImageCaptureCore call runs on the main thread: the backend's entry points hop there with `@MainActor` methods, and ImageCaptureCore calls its delegates on the main thread.

`macos/Sources/HelperCore/ImageCaptureBackend.swift`:

```swift
import AppKit
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

/// Real scanners: USB, network and AirPrint/eSCL devices that macOS's Image Capture sees.
public final class ImageCaptureBackend: NSObject, ScannerBackend, @unchecked Sendable {
    private let log: @Sendable (String) -> Void
    // All state below is touched on the main thread only.
    private var browser: ICDeviceBrowser?
    private var devices: [String: ICScannerDevice] = [:]
    private var infos: [String: ScannerInfo] = [:]
    private var busy: Set<String> = []
    private var changeHandler: (@Sendable () -> Void)?
    private var selectWaiters: [String: Once<Void>] = [:]
    private var collectors: [String: Collector] = [:]

    /// Pages arriving during one scan, and the waiter for the end of the scan.
    private final class Collector {
        let once: Once<([URL], Error?)>
        var urls: [URL] = []
        var watchdog: DispatchWorkItem?
        init(once: Once<([URL], Error?)>) { self.once = once }
    }

    /// A scan with no page and no completion for this long is given up.
    static let inactivityLimit: TimeInterval = 600

    public init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    /// Starts looking for scanners. Call on the main thread.
    @MainActor public func start() {
        let browser = ICDeviceBrowser()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        browser.start()
        self.browser = browser
    }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async { self.changeHandler = handler }
    }

    public func listScanners() async -> [ScannerInfo] { await currentScanners() }

    @MainActor private func currentScanners() -> [ScannerInfo] {
        for id in devices.keys where infos[id] == nil && !busy.contains(id) {
            Task { await self.probe(id) }  // retry devices whose settings couldn't be read yet
        }
        return devices.keys.compactMap { infos[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func scan(scannerID: String, settings: ScanSettings) async throws -> ScanDocuments {
        try await performScan(scannerID, settings)
    }

    // MARK: Discovery

    static func id(for device: ICDevice) -> String {
        CapabilityMapping.scannerID(persistentID: device.persistentIDString, uuid: device.uuidString,
                                    name: device.name ?? "Scanner")
    }

    @MainActor private func probe(_ id: String) async {
        guard let device = devices[id], !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        let name = device.name ?? "Scanner"
        do {
            try await openSession(device)
            defer { device.requestCloseSession(options: [:]) { _ in } }
            var units: [UnitCapabilities] = []
            let types = device.availableFunctionalUnitTypes.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) }
            for type in types where type == .flatbed || type == .documentFeeder {
                try await select(device, type)
                let unit = device.selectedFunctionalUnit
                units.append(UnitCapabilities(
                    source: type == .documentFeeder ? .feeder : .flatbed,
                    duplex: (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false,
                    bitDepths: Array(unit.supportedBitDepths), resolutions: Array(unit.supportedResolutions),
                    preferredResolutions: Array(unit.preferredResolutions)))
            }
            guard let info = CapabilityMapping.scannerInfo(id: id, name: name, units: units) else {
                log("\(name) has no flatbed or document feeder; not offered.")
                return
            }
            infos[id] = info
            log("Found \(name): \(info.sources.map(\.rawValue).joined(separator: ", ")), \(info.resolutions) dpi.")
            changeHandler?()
        } catch {
            log("Couldn't read the settings of \(name): \(error.localizedDescription)")
        }
    }

    // MARK: Scanning

    @MainActor private func performScan(_ id: String, _ settings: ScanSettings) async throws -> ScanDocuments {
        guard let device = devices[id], let info = infos[id] else {
            throw ProtocolError(503, "That scanner isn't connected any more. Check that it's switched on, then try again.")
        }
        guard !busy.contains(id) else {
            throw ProtocolError(503, "\(info.name) is still being set up. Try again in a moment.")
        }
        busy.insert(id)
        defer { busy.remove(id) }

        do { try await openSession(device) } catch {
            throw ProtocolError(503, "Couldn't connect to \(info.name): \(error.localizedDescription). Check that it's "
                + "switched on and that no other app (Image Capture, Preview) is using it. For a network scanner, also "
                + "check System Settings › Privacy & Security › Local Network.")
        }
        defer { device.requestCloseSession(options: [:]) { _ in } }

        let type: ICScannerFunctionalUnitType = settings.source == .feeder ? .documentFeeder : .flatbed
        do { try await select(device, type) } catch {
            throw ProtocolError(503, "\(info.name) couldn't switch to its \(settings.source.rawValue): \(error.localizedDescription)")
        }
        configure(device.selectedFunctionalUnit, settings)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dossiary-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        device.transferMode = .fileBased
        device.downloadsDirectory = folder
        device.documentName = "page"
        device.documentUTI = (settings.colorMode == .bw ? UTType.png : UTType.jpeg).identifier

        let (urls, error) = try await runScan(device, id: id)
        let pages = try urls.map { PageImage(data: try Data(contentsOf: $0), dpi: settings.resolution) }
        return try ScanOutcome.documents(pages: pages, errorMessage: error?.localizedDescription, source: settings.source)
    }

    @MainActor private func configure(_ unit: ICScannerFunctionalUnit, _ settings: ScanSettings) {
        unit.measurementUnit = .inches
        switch settings.colorMode {
        case .color: unit.pixelDataType = .RGB; unit.bitDepth = .depth8Bits
        case .gray: unit.pixelDataType = .gray; unit.bitDepth = .depth8Bits
        case .bw: unit.pixelDataType = .BW; unit.bitDepth = .depth1Bit
        }
        unit.resolution = settings.resolution
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeDefault
            feeder.duplexScanningEnabled = settings.duplex
            let size = feeder.documentSize
            unit.scanArea = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            let size = unit.physicalSize
            unit.scanArea = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }

    @MainActor private func runScan(_ device: ICScannerDevice, id: String) async throws -> ([URL], Error?) {
        try await awaitCallback(timeout: nil) { (once: Once<([URL], Error?)>) in
            let collector = Collector(once: once)
            collectors[id] = collector
            touch(collector, device: device, id: id)
            device.requestScan()
        }
    }

    /// (Re)starts the inactivity watchdog: no page and no completion for `inactivityLimit` ends the scan.
    @MainActor private func touch(_ collector: Collector, device: ICScannerDevice, id: String) {
        collector.watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let current = self.collectors.removeValue(forKey: id) else { return }
            device.cancelScan()
            current.once.resume(.success((current.urls, CallbackTimeout())))
        }
        collector.watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ImageCaptureBackend.inactivityLimit, execute: item)
    }

    // MARK: Session helpers

    @MainActor private func openSession(_ device: ICScannerDevice) async throws {
        device.delegate = self
        let _: Void = try await awaitCallback(timeout: 30) { once in
            device.requestOpenSession(options: [:]) { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    @MainActor private func select(_ device: ICScannerDevice, _ type: ICScannerFunctionalUnitType) async throws {
        if device.selectedFunctionalUnit.type == type { return }
        let id = ImageCaptureBackend.id(for: device)
        let _: Void = try await awaitCallback(timeout: 30) { once in
            selectWaiters[id] = once
            device.requestSelect(type)
        }
    }
}

extension ImageCaptureBackend: ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        let id = ImageCaptureBackend.id(for: scanner)
        devices[id] = scanner
        scanner.delegate = self
        Task { @MainActor in await self.probe(id) }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        forget(device)
    }
}

extension ImageCaptureBackend: ICScannerDeviceDelegate {
    public func didRemove(_ device: ICDevice) { forget(device) }

    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    public func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        let id = ImageCaptureBackend.id(for: scanner)
        selectWaiters.removeValue(forKey: id)?.resume(error.map { .failure($0) } ?? .success(()))
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let id = ImageCaptureBackend.id(for: scanner)
        guard let collector = collectors[id] else { return }
        collector.urls.append(url)
        MainActor.assumeIsolated { touch(collector, device: scanner, id: id) }
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        let id = ImageCaptureBackend.id(for: scanner)
        guard let collector = collectors.removeValue(forKey: id) else { return }
        collector.watchdog?.cancel()
        collector.once.resume(.success((collector.urls, error)))
    }

    private func forget(_ device: ICDevice) {
        let id = ImageCaptureBackend.id(for: device)
        devices.removeValue(forKey: id)
        infos.removeValue(forKey: id)
        let gone = ProtocolError(503, "\(device.name ?? "The scanner") was disconnected.")
        selectWaiters.removeValue(forKey: id)?.resume(.failure(gone))
        if let collector = collectors.removeValue(forKey: id) {
            collector.watchdog?.cancel()
            collector.once.resume(.success((collector.urls, gone)))
        }
        log("\(device.name ?? "A scanner") went away.")
        changeHandler?()
    }
}
```

In `macos/Sources/HelperCore/HelperRuntime.swift`, replace the `else` branch of `init` with the real backend and pairing:

```swift
        } else {
            backend = ImageCaptureBackend(log: { [log] in log.write($0) })
            pairing = PairingStore(mode: .real(fileURL: PairingStore.defaultFileURL))
        }
```

and make `start()` begin browsing after the server is up:

```swift
    public func start() throws {
        try server.start()
        if let real = backend as? ImageCaptureBackend {
            if Thread.isMainThread { MainActor.assumeIsolated { real.start() } }
            else { DispatchQueue.main.async { real.start() } }
        }
        log.write("Dossiary Scan Helper \(HelperVersion.string) listening on 127.0.0.1:\(options.port)"
                  + (options.fakeScanners ? " with fake scanners." : "."))
    }
```

- [ ] **Step 6: Build and test**

Run: `cd macos && swift test && swift build && scripts/run-conformance.sh`
Expected: all unit tests pass, the build succeeds, and the conformance suite still passes (fake mode is unchanged).

- [ ] **Step 7: First real-scanner smoke check (by whoever has a scanner)**

Run `.build/debug/dossiary-scan-helper --headless` with a scanner switched on, then:

```bash
curl -s http://127.0.0.1:8766/health
tail -n 20 ~/Library/Logs/dossiary-scan-helper/helper.log
```

Expected: `/health` answers `"paired": false`, and the log shows `Found <scanner name>: …` for each scanner within ~30 s. A full scan needs a paired browser, which comes from the menu bar app; the end-to-end check with Dossiary is part of Task 8's manual checklist. If no scanner is available, say so in the report; the controller will ask the owner.

- [ ] **Step 8: Commit**

```bash
git add macos
git commit -m "macOS helper: real scanners through ImageCaptureCore (discovery, capabilities, file-based scans)"
```

---

### Task 8: App bundle, signing and notarization, docs, release

**Files:**
- Create: `macos/Resources/Info.plist`, `macos/scripts/build-app.sh`, `macos/scripts/sign-and-notarize.sh` (both executable), `macos/README.md`
- Create: `docs/install-macos.md`, `docs/manual-check-macos.md`
- Modify: `README.md` (repo root)

**Interfaces:**
- Consumes: the `dossiary-scan-helper` executable, `HelperVersion.string`.
- Produces: `macos/build/Dossiary Scan Helper.app` (universal, unsigned) and `macos/dist/DossiaryScanHelper-<version>-macos.zip` (signed, notarized, stapled).

- [ ] **Step 1: Info.plist template**

`macos/Resources/Info.plist` (`__VERSION__` is replaced by `build-app.sh`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Dossiary Scan Helper</string>
    <key>CFBundleDisplayName</key><string>Dossiary Scan Helper</string>
    <key>CFBundleIdentifier</key><string>com.aarneaarebye.dossiary-scan-helper</string>
    <key>CFBundleExecutable</key><string>dossiary-scan-helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Dossiary Scan Helper looks for scanners on your network.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Aarne Aarebye. MIT License.</string>
</dict>
</plist>
```

- [ ] **Step 2: Build script**

`macos/scripts/build-app.sh`:

```bash
#!/bin/bash
# Builds an unsigned universal "Dossiary Scan Helper.app" into macos/build/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HelperCore/Version.swift)
APP="build/Dossiary Scan Helper.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH"
  BINS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --show-bin-path)/dossiary-scan-helper")
done
lipo -create -output "$APP/Contents/MacOS/dossiary-scan-helper" "${BINS[@]}"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/dossiary-scan-helper"
echo "Built $APP ($VERSION)"
```

Run: `cd macos && scripts/build-app.sh`
Expected: `Info.plist: OK`, `x86_64 arm64` (either order), `Built build/Dossiary Scan Helper.app (0.1.0)`. Then `open "build/Dossiary Scan Helper.app"`: the menu bar icon appears, and "Start at login" is now enabled. Quit it from the menu.

- [ ] **Step 3: Signing and notarization script**

`macos/scripts/sign-and-notarize.sh`:

```bash
#!/bin/bash
# Signs the app with Developer ID (hardened runtime), notarizes it, staples the ticket and zips it for release.
# Needs, once per Mac (never in the repo or CI):
#   - a "Developer ID Application" certificate in the login keychain;
#   - notarytool credentials: xcrun notarytool store-credentials dossiary-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/HelperCore/Version.swift)
APP="build/Dossiary Scan Helper.app"
IDENTITY="${DEVELOPER_ID:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-dossiary-notary}"

[ -d "$APP" ] || { echo "Run scripts/build-app.sh first."; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
  echo "No \"$IDENTITY\" certificate in the keychain. See macos/README.md, \"Signing setup\"."; exit 1; }

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p dist
SUBMIT="dist/notarize-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
rm "$SUBMIT"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ZIP="dist/DossiaryScanHelper-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
```

Make both scripts executable (`chmod +x macos/scripts/*.sh`). Don't run this script in this task unless the certificate and the `dossiary-notary` profile already exist (`security find-identity -v -p codesigning` lists a "Developer ID Application" line). Without them, stop after Step 6 and report "signing setup pending": the controller hands the owner the setup steps from `macos/README.md`.

- [ ] **Step 4: macOS README**

`macos/README.md`:

````markdown
# Dossiary Scan Helper for macOS

A menu bar app that lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any scanner
macOS supports (USB, network and AirPrint/eSCL scanners that Image Capture sees). It speaks
[protocol version 2](../PROTOCOL.md) on `127.0.0.1:8766`.

To install a release, see [docs/install-macos.md](../docs/install-macos.md).

## Build and test

Needs macOS 14 or later and the Command Line Tools (`xcode-select --install`); Xcode isn't needed.

    cd macos
    swift test                      # unit tests
    scripts/run-conformance.sh      # the conformance suite against --fake-scanners
    swift run dossiary-scan-helper --fake-scanners   # menu bar app with the seven fake scanners

`--headless` runs without the menu bar icon and logs to the terminal too. The log file is
`~/Library/Logs/dossiary-scan-helper/helper.log`.

## Release

1. Bump `HelperVersion.string` in `Sources/HelperCore/Version.swift`.
2. `scripts/build-app.sh` builds an unsigned universal app in `build/`.
3. `scripts/sign-and-notarize.sh` signs, notarizes and staples it, and writes
   `dist/DossiaryScanHelper-<version>-macos.zip`.
4. Run the [hardware checklist](../docs/manual-check-macos.md) with the signed app.
5. Tag `macos-v<version>` and attach the zip to a GitHub release.

### Signing setup (once per Mac)

Nothing here goes into the repo or CI.

1. **Certificate.** In Keychain Access choose Keychain Access › Certificate Assistant › Request a
   Certificate From a Certificate Authority…, enter your email, choose "Saved to disk". On
   developer.apple.com › Certificates, add a **Developer ID Application** certificate with that
   request, download it and double-click it. `security find-identity -v -p codesigning` then lists
   it.
2. **Notarization password.** At account.apple.com › Sign-In and Security › App-Specific Passwords,
   create one, then run (it asks for the password and keeps it in the keychain):

       xcrun notarytool store-credentials dossiary-notary --apple-id <your Apple ID> --team-id <your team id>

   The team id is on developer.apple.com › Membership details.
````

- [ ] **Step 5: Install guide and hardware checklist**

`docs/install-macos.md`:

```markdown
# Installing Dossiary Scan Helper on a Mac

Dossiary runs in your browser, which can't reach a scanner. Dossiary Scan Helper is a small menu
bar app that does the scanning for it, with any scanner your Mac already supports.

Needs macOS 14 (Sonoma) or later.

1. Download `DossiaryScanHelper-<version>-macos.zip` from the
   [releases page](https://github.com/AarneAarebye/dossiary-scan-helper/releases).
2. Open the zip and drag **Dossiary Scan Helper** into your Applications folder.
3. Open it. A scanner icon appears in the menu bar (it has no window and no Dock icon).
4. In the icon's menu, choose **Start at login** so it's there whenever you scan.

## Connect Dossiary

1. In Dossiary, click **📷 Scan**. The dialog shows the helper as "not paired yet".
2. In the helper's menu, choose **Pair a browser…**. A 6-digit code appears; it works for two
   minutes.
3. Type the code in Dossiary and click **Pair**. Your scanners appear in the dialog.

Each browser pairs once. **Forget paired browsers** in the menu disconnects them all.

## If a scanner is missing

- Check that it's switched on and appears in Apple's Image Capture app.
- Close Image Capture and Preview: a scanner works with one app at a time.
- For a network scanner, check System Settings › Privacy & Security › Local Network, and allow
  Dossiary Scan Helper.
- **Open log** in the menu shows what the helper saw.
```

`docs/manual-check-macos.md`:

```markdown
# Hardware checklist (macOS), before each release

Use the signed, notarized app from `macos/dist/`, a real scanner, and the current Dossiary.

- [ ] The zip opens and the app starts from Applications without a security warning.
- [ ] The menu bar icon appears; the menu lists the scanner within 30 seconds of switching it on.
- [ ] Switching the scanner off removes it from the menu; switching it on again brings it back.
- [ ] Pair a browser…: the code pairs Dossiary; a wrong code five times closes the window.
- [ ] Quit and reopen the helper: Dossiary is still paired.
- [ ] Forget paired browsers: Dossiary's dialog asks for a code again.
- [ ] Dossiary's dialog shows only the settings the scanner offers (sources, two-sided, color, resolution).
- [ ] Flatbed, color, 300 dpi: one page arrives in the Inbox, the right way up and the right size.
- [ ] Feeder with 3 sheets (if the scanner has one): 3 pages in one PDF.
- [ ] Feeder, both sides (if offered): 6 pages, fronts and backs in order.
- [ ] Gray and black & white: the PDF looks right and isn't huge.
- [ ] Empty feeder: Dossiary says "No paper in the feeder." and nothing is added.
- [ ] Scanner opened in Image Capture during a scan request: Dossiary shows the "couldn't connect" message.
- [ ] Start at login: after logging out and in, the icon is back.
- [ ] Open log: the log shows the scans and no codes, tokens or page data.
```

- [ ] **Step 6: Root README**

In the repo root `README.md`:
- Replace the status note with: `> **Status:** the macOS helper is available (see [docs/install-macos.md](docs/install-macos.md)). The Windows helper comes next. This repo also holds the protocol, the conformance test suite and a reference helper with fake scanners.`
- Add a row to the "What's here" table: `| \`macos/\` | The macOS helper: a Swift menu bar app using ImageCaptureCore. See [macos/README.md](macos/README.md). |`
- Under "Run the conformance suite", add: `For the macOS helper, \`macos/scripts/run-conformance.sh\` builds it, starts it with fake scanners and runs the suite.`

Run: `cd macos && swift test && scripts/run-conformance.sh`
Expected: everything passes.

Commit:

```bash
git add macos docs README.md
git commit -m "macOS helper: app bundle, signing and notarization scripts, install guide, hardware checklist"
```

- [ ] **Step 7: Signed build and hardware check (owner present)**

Only once the signing setup in `macos/README.md` is done on the owner's Mac:

Run: `cd macos && scripts/build-app.sh && scripts/sign-and-notarize.sh`
Expected: `codesign` reports `valid on disk` and `satisfies its Designated Requirement`; `notarytool` ends with `status: Accepted`; `stapler` says `The staple and validate action worked!`; `spctl` says `accepted` and `source=Notarized Developer ID`; the script prints `Ready: dist/DossiaryScanHelper-0.1.0-macos.zip`.

Then go through `docs/manual-check-macos.md` with the owner and the owner's scanner, and fix what fails before releasing.

- [ ] **Step 8: Release (needs the owner's OK)**

Publishing a release is outward-facing: ask the owner first. With a yes:

```bash
git push
git tag macos-v0.1.0
git push origin macos-v0.1.0
gh release create macos-v0.1.0 "macos/dist/DossiaryScanHelper-0.1.0-macos.zip" \
  --title "Dossiary Scan Helper for macOS 0.1.0" \
  --notes "First release of the macOS helper: scan from Dossiary (v1.44.0 or later) with any scanner your Mac supports. Signed and notarized. See docs/install-macos.md."
```

Afterwards, in `~/Projects/Paperless/Dossiary`, mark step 3 done in `docs/superpowers/specs/2026-10-09-system-scanner-helper-design.md` ("4. Order of work", the same way step 2 is marked), note there that the macOS helper ships signed and notarized, and update the scanning paragraph of Dossiary's `README.md`/`README.de.md` if it says the helper isn't available yet.
