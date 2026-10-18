# Dossiary Scan Helper (macOS) in Seven Languages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS helper's menu, panels, error messages and the macOS network-permission prompt appear in English, German, Spanish, French, Chinese (Simplified and Traditional) and Armenian, following the person's preferred languages.

**Architecture:** One String Catalog, `macos/Localization/Localizable.xcstrings` (plus `InfoPlist.xcstrings` for the permission prompt), is the single source of every translation. This Mac has no Xcode, so `swift build` can't compile a catalog; instead `scripts/build-app.sh` runs a stdlib-only Python converter that writes `<lang>.lproj/Localizable.strings` and `InfoPlist.strings` into the app bundle. Swift code looks texts up through a small `Texts` value in HelperCore (English text as the key), so the menu model and error texts stay unit-testable without AppKit.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), AppKit, Python 3 stdlib (`unittest`), bash.

Spec: Dossiary repo, `docs/superpowers/specs/2026-10-17-armenian-design.md`, sub-project 3. Deviation decided with the user on 2026-10-18: the catalog is converted by our own script, not compiled by Xcode.

## Global Constraints

- Languages, in this order everywhere: `en`, `de`, `es`, `fr`, `zh-Hans`, `zh-Hant`, `hy`. Folder names `en.lproj` … `zh-Hant.lproj`, `hy.lproj`.
- macOS picks the language from the person's preferred languages (Armenian can be added there, or set for this app alone in System Settings › General › Language & Region › Applications).
- Out of scope: messages the helper sends to Dossiary inside protocol answers stay English. `errorDescription` of `PairingFailure`/`RemoteError`/`ProtocolError` and every `ProtocolError(...)` message stay exactly as they are; translation happens only where text is shown in the menu or a panel.
- No Xcode dependency: nothing may require `xcodebuild`, `xcstringstool` or `.xcstrings` in SwiftPM `resources:`. The Python scripts use the standard library only.
- Keys are the English text. A key contains no backslash, no newline and no Swift interpolation `\(`; arguments use `String(format:)` placeholders `%@` and `%lld` (positional `%1$@` when a sentence has two).
- No plural variants: count-dependent texts are phrased so one form fits every number ("Seconds left: %lld").
- Every translation has exactly the placeholders of its key.
- Form of address matches Dossiary's own scan dialog: German "du", Spanish "usted", French "vous", Chinese "您", Armenian polite capitalised «Դուք/Ձեր».
- Terms match Dossiary: pair = koppeln / emparejar / associer / 配对 / 配對 / զուգակցել; browser = Browser / navegador / navigateur / 浏览器 / 瀏覽器 / դիտարկիչ.
- The product names "Dossiary", "Dossiary Scan Helper", "scanix500", "scanix500-server", "iX500" and the hardware button name "Scan" (es/fr/hy) are not translated.
- Unit tests: `macos/scripts/test.sh` (Swift) and `python3 -m unittest discover -s macos/scripts -p 'test_*.py'` (Python), both green at the end of every task.

---

## File Structure

- Create `macos/Sources/HelperCore/Texts.swift` — `Texts` (lookup + formatting) and `Texts.errorText(_:)`.
- Modify `macos/Sources/HelperCore/MenuModel.swift` — every visible string through `Texts`.
- Modify `macos/Sources/HelperCore/CommandLineOptions.swift` — `--print-menu`; skip Cocoa's `-AppleLanguages`/`-AppleLocale` arguments.
- Modify `macos/Sources/App/main.swift`, `AppDelegate.swift`, `PairingPanel.swift`, `NetworkScannerPanel.swift` — texts through `L(...)`.
- Create `macos/Sources/App/Localized.swift` — `let L = Texts.bundle`.
- Create `macos/Localization/Localizable.xcstrings`, `macos/Localization/InfoPlist.xcstrings` — the catalogs.
- Create `macos/scripts/strings_from_catalog.py` — converter and checks.
- Create `macos/scripts/test_strings_from_catalog.py` — its tests, plus the real catalogs' checks.
- Create `macos/scripts/check-localized-app.sh` — prints the built app's menu in four languages.
- Modify `macos/scripts/build-app.sh`, `macos/Resources/Info.plist`, `.github/workflows/conformance.yml`.
- Create `macos/Tests/HelperCoreTests/TextsTests.swift`; modify `MenuModelTests.swift`, `OptionsTests.swift`.
- Modify docs: `macos/README.md`, `docs/install-macos.md`, `docs/manual-check-macos.md`, `README.md`; `macos/Sources/HelperCore/Version.swift` (0.4.0).

---

### Task 1: `Texts` in HelperCore; the menu model and error texts go through it

**Files:**
- Create: `macos/Sources/HelperCore/Texts.swift`
- Modify: `macos/Sources/HelperCore/MenuModel.swift`
- Create: `macos/Tests/HelperCoreTests/TextsTests.swift`
- Modify: `macos/Tests/HelperCoreTests/MenuModelTests.swift`

**Interfaces:**
- Produces: `public struct Texts: Sendable` with `init(lookup: @escaping @Sendable (String) -> String)`, `static let english`, `static let bundle`, `func callAsFunction(_ key: String, _ args: CVarArg...) -> String`, `func errorText(_ error: Error) -> String`.
- Produces: `MenuModel.entries(scanners:port:fake:pairedCount:startAtLogin:networkServers:texts:)` — new last parameter `texts: Texts = .english`; `NetworkServerEntry.statusText(_ t: Texts) -> String` replaces the `statusText` property.
- Convention later tasks rely on: keys are always written as a string literal directly after `t(` or `L(`, so a script can find them with the regex `\b(?:t|L)\("([^"\\]*)"`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/HelperCoreTests/TextsTests.swift`:

```swift
import Foundation
import Testing
@testable import HelperCore

/// Marks every looked-up text, to prove a visible string went through Texts.
let marked = Texts { "‹" + $0 + "›" }

@Test func englishReturnsTheKeyAndFillsArguments() {
    #expect(Texts.english("Open log") == "Open log")
    #expect(Texts.english("Forget paired browsers (%lld)", 3) == "Forget paired browsers (3)")
    #expect(Texts.english("%1$@ at %2$@", "scanner", "10.0.0.5") == "scanner at 10.0.0.5")
}

@Test func lookupResultIsTheTemplate() {
    let german = Texts { $0 == "Remove “%@”" ? "„%@“ entfernen" : $0 }
    #expect(german("Remove “%@”", "attic") == "„attic“ entfernen")
}

@Test func errorTextInEnglishMatchesErrorDescription() {
    let errors: [Error] = [PairingFailure.notAScanServer, PairingFailure.timedOut, PairingFailure.conflict,
                           PairingFailure.tooMany, RemoteError.unreachable("timed out"),
                           RemoteError.certificateChanged(seen: String(repeating: "A", count: 64))]
    for error in errors {
        #expect(Texts.english.errorText(error) == (error as! LocalizedError).errorDescription)
    }
}

@Test func errorTextIsTranslated() {
    #expect(marked.errorText(PairingFailure.timedOut) == "‹Nobody pressed the Scan button within 2 minutes. Try again.›")
    #expect(marked.errorText(RemoteError.unreachable("timed out")) == "‹The network scanner can't be reached (timed out).›")
    // A refusal is the server's own message, shown as it came.
    #expect(marked.errorText(PairingFailure.refused("Wrong code.")) == "Wrong code.")
    // Anything else keeps its own (system) description.
    #expect(marked.errorText(URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
}
```

Append to `macos/Tests/HelperCoreTests/MenuModelTests.swift`:

```swift
@Test func everyVisibleMenuTextGoesThroughTexts() {
    let entries = MenuModel.entries(scanners: Array(FakeScanners.infos.prefix(1)), port: 8766, fake: true, pairedCount: 1,
                                    startAtLogin: true,
                                    networkServers: [NetworkServerEntry(id: "1", name: "attic", status: .unreachable)],
                                    texts: marked)
    var texts: [String] = []
    for entry in entries {
        switch entry {
        case .title(let s), .info(let s): texts.append(s)
        case .action(let s, _, _, _): texts.append(s)
        case .separator: break
        }
    }
    let scannerNames: Set = ["Fake Flatbed"]
    for text in texts where !scannerNames.contains(text) {
        #expect(text.hasPrefix("‹"), "not translated: \(text)")
    }
    #expect(texts.contains("‹Listening on 127.0.0.1:8766›"))
    // The server line is t("%1$@: %2$@", name, statusText(t)): the status is looked up too.
    #expect(texts.contains("‹attic: ‹can't be reached››"))
}

@Test func statusTextsTranslate() {
    let entry = NetworkServerEntry(id: "1", name: "attic", status: .certificateChanged)
    #expect(entry.statusText(.english) == "certificate changed, remove and add it again")
    #expect(entry.statusText(marked) == "‹certificate changed, remove and add it again›")
    #expect(NetworkServerEntry(id: "1", name: "a", status: nil).statusText(.english) == "checking…")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && scripts/test.sh`
Expected: compile errors — `Texts` not found, `entries(...texts:)` has no such parameter, `statusText` is not a function.

- [ ] **Step 3: Write `Texts.swift`**

```swift
import Foundation

/// Looks up the text the menu and panels show. Keys are the English text; `lookup` returns the
/// translation (the key itself when there is none), and arguments are filled in with String(format:).
/// Only what a person sees goes through here: messages sent to Dossiary in protocol answers stay English.
public struct Texts: Sendable {
    public let lookup: @Sendable (String) -> String

    public init(lookup: @escaping @Sendable (String) -> String) { self.lookup = lookup }

    /// The keys themselves, for tests and anything without an app bundle.
    public static let english = Texts { $0 }
    /// The app bundle's <lang>.lproj/Localizable.strings, in the person's preferred language.
    public static let bundle = Texts { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }

    public func callAsFunction(_ key: String, _ args: CVarArg...) -> String {
        let template = lookup(key)
        return args.isEmpty ? template : String(format: template, arguments: args)
    }

    /// An error as a panel shows it. The helper's own errors are translated here (their errorDescription
    /// stays English, since it also reaches Dossiary); a scan server's refusal and system errors are shown
    /// as they come.
    public func errorText(_ error: Error) -> String {
        let t = self
        switch error {
        case PairingFailure.notAScanServer: return t("That address doesn't answer like a scanix500 network scan server.")
        case PairingFailure.timedOut: return t("Nobody pressed the Scan button within 2 minutes. Try again.")
        case PairingFailure.conflict: return t("Another computer asked to pair at the same time. Try again, one computer at a time.")
        case PairingFailure.tooMany: return t("Too many pairing requests. Wait a minute, then try again.")
        case PairingFailure.refused(let message): return message
        case RemoteError.unreachable(let detail): return t("The network scanner can't be reached (%@).", detail)
        case RemoteError.certificateChanged(let seen):
            return t("The network scanner presented a different certificate (%@) than when it was paired. If it was reinstalled, remove it in Dossiary Scan Helper and add it again.",
                     RemoteFingerprint.display(seen))
        default: return error.localizedDescription
        }
    }
}
```

If the compiler rejects matching an enum case directly against `Error`, switch on `error as? PairingFailure` / `error as? RemoteError` first; the texts stay the same. Check: `RemoteError.certificateChanged`'s English `errorDescription` is two concatenated literals (`"…than when it " + "was paired. If…"`); the key above must equal their concatenation exactly, which `errorTextInEnglishMatchesErrorDescription` verifies.

- [ ] **Step 4: Route `MenuModel` through `Texts`**

In `MenuModel.swift`, replace the `statusText` property and `entries` with:

```swift
    func statusText(_ t: Texts) -> String {
        switch status {
        case .connected: return t("connected")
        case .needsPairing: return t("needs pairing again")
        case .unreachable: return t("can't be reached")
        case .certificateChanged: return t("certificate changed, remove and add it again")
        case nil: return t("checking…")
        }
    }
```

```swift
    public static func entries(scanners: [ScannerInfo], port: UInt16, fake: Bool, pairedCount: Int,
                               startAtLogin: Bool?, networkServers: [NetworkServerEntry]? = nil,
                               texts t: Texts = .english) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .title(fake ? t("Dossiary Scan Helper — fake scanners") : "Dossiary Scan Helper"),
            .info(t("Listening on %@", "127.0.0.1:\(port)")),
            .separator,
        ]
        entries += scanners.isEmpty ? [.info(t("No scanners found"))] : scanners.map { .info($0.name) }
        entries += [
            .separator,
            .action(t("Pair a browser…"), .pair, checked: false, enabled: true),
            .action(t("Forget paired browsers (%lld)", pairedCount), .forget, checked: false, enabled: pairedCount > 0),
        ]
        if let networkServers {
            entries.append(.separator)
            for server in networkServers {
                entries.append(.info(t("%1$@: %2$@", server.name, server.statusText(t))))
                entries.append(.action(t("Remove “%@”", server.name), .removeNetworkScanner(server.id), checked: false, enabled: true))
            }
            entries.append(.action(t("Add network scanner…"), .addNetworkScanner, checked: false, enabled: true))
        }
        entries += [
            .separator,
            .action(t("Start at login"), .startAtLogin, checked: startAtLogin == true, enabled: startAtLogin != nil),
            .action(t("Open log"), .openLog, checked: false, enabled: true),
            .separator,
            .action(t("Quit Dossiary Scan Helper"), .quit, checked: false, enabled: true),
        ]
        return entries
    }
```

The plain title "Dossiary Scan Helper" is the product name and is not looked up; `everyVisibleMenuTextGoesThroughTexts` uses `fake: true`, so the title it sees is the looked-up one. The port goes in as a string so no locale adds a thousands separator (8,766).

- [ ] **Step 5: Run the tests**

Run: `cd macos && scripts/test.sh`
Expected: all tests pass, including the unchanged English expectations in the existing `MenuModelTests`.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/HelperCore/Texts.swift macos/Sources/HelperCore/MenuModel.swift macos/Tests/HelperCoreTests/TextsTests.swift macos/Tests/HelperCoreTests/MenuModelTests.swift
git commit -m "macOS helper: Texts lookup for the menu and error texts"
```

---

### Task 2: The catalog converter and its checks

**Files:**
- Create: `macos/scripts/strings_from_catalog.py`
- Create: `macos/scripts/test_strings_from_catalog.py`

**Interfaces:**
- Produces (Python module `strings_from_catalog`): `LANGS = ["en", "de", "es", "fr", "zh-Hans", "zh-Hant", "hy"]`; `load(path) -> dict`; `placeholders(text) -> list[str]` (sorted); `problems(catalog, langs=LANGS) -> list[str]`; `strings_file(catalog, lang) -> str`; `write_tables(catalog_paths, out_dir, langs=LANGS) -> list[str]` (returns the written paths); `source_keys(swift_dir) -> set[str]`; `source_problems(catalog, swift_dir) -> list[str]`.
- CLI: `python3 strings_from_catalog.py --out DIR CATALOG...` writes `DIR/<lang>.lproj/<CatalogName>.strings` for all seven languages (a missing translation falls back to English and is printed as a warning); `--strict` makes any `problems()` fatal (exit 1); `--check-sources SWIFT_DIR CATALOG` prints `source_problems()` and exits 1 if there are any.

- [ ] **Step 1: Write the failing tests**

Create `macos/scripts/test_strings_from_catalog.py`:

```python
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import strings_from_catalog as sfc


def catalog(strings):
    return {"sourceLanguage": "en", "version": "1.0", "strings": strings}


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


class ConverterTests(unittest.TestCase):
    def test_placeholders(self):
        self.assertEqual(sfc.placeholders("%1$@ at %2$@, %lld left, 100%% sure"), ["%1$@", "%2$@", "%lld"])
        self.assertEqual(sfc.placeholders("no arguments"), [])

    def test_strings_file_escapes_and_falls_back_to_english(self):
        c = catalog({
            'Say "hi"\\': {"localizations": {"de": unit('Sag „hi“ "jetzt"\\')}},
            "Open log": {"localizations": {}},
        })
        de = sfc.strings_file(c, "de")
        self.assertIn('"Say \\"hi\\"\\\\" = "Sag „hi“ \\"jetzt\\"\\\\";', de)
        self.assertIn('"Open log" = "Open log";', de)
        en = sfc.strings_file(c, "en")
        self.assertIn('"Open log" = "Open log";', en)

    def test_english_localization_overrides_the_key(self):
        c = catalog({"Open log": {"localizations": {"en": unit("Open the log")}}})
        self.assertIn('"Open log" = "Open the log";', sfc.strings_file(c, "en"))

    def test_problems(self):
        c = catalog({
            "Remove “%@”": {"localizations": {"de": unit("„%@“ entfernen"), "es": unit("Quitar"),
                                              "fr": unit("Retirer « %@ »", state="needs_review")}},
        })
        found = sfc.problems(c, langs=["en", "de", "es", "fr", "hy"])
        self.assertIn("Remove “%@”: es has placeholders [] instead of ['%@']", found)
        self.assertIn("Remove “%@”: fr is not marked translated (needs_review)", found)
        self.assertIn("Remove “%@”: hy is missing", found)
        self.assertFalse(any(": de " in p or ": en " in p for p in found))

    def test_keys_must_be_plain(self):
        c = catalog({"Line one\nline two": {"localizations": {}}})
        self.assertIn("Line one\nline two: key contains a newline or backslash", sfc.problems(c, langs=["en"]))

    def test_write_tables(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "InfoPlist.xcstrings")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(catalog({"NSLocalNetworkUsageDescription": {"localizations": {
                    "en": unit("Looks for scanners."), "de": unit("Sucht Scanner.")}}}), f)
            out = os.path.join(d, "Resources")
            written = sfc.write_tables([path], out, langs=["en", "de"])
            self.assertEqual(sorted(os.path.relpath(p, out) for p in written),
                             ["de.lproj/InfoPlist.strings", "en.lproj/InfoPlist.strings"])
            with open(os.path.join(out, "de.lproj", "InfoPlist.strings"), encoding="utf-8") as f:
                self.assertIn('"NSLocalNetworkUsageDescription" = "Sucht Scanner.";', f.read())

    def test_source_problems(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "App"))
            with open(os.path.join(d, "App", "A.swift"), "w") as f:
                f.write('let a = L("Open log")\nlet b = t("Pairing…", x)\nlet c = alert("not a key")\n')
            self.assertEqual(sfc.source_keys(d), {"Open log", "Pairing…"})
            c = catalog({"Open log": {}, "Unused": {}})
            self.assertEqual(sorted(sfc.source_problems(c, d)),
                             ["in the catalog but not used: Unused", "used but not in the catalog: Pairing…"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest discover -s macos/scripts -p 'test_*.py' -v`
Expected: `ModuleNotFoundError: No module named 'strings_from_catalog'`.

- [ ] **Step 3: Write `strings_from_catalog.py`**

```python
#!/usr/bin/env python3
"""Turns the String Catalogs in macos/Localization/ into <lang>.lproj/<Table>.strings files.

Xcode compiles .xcstrings itself; this Mac builds with the Command Line Tools only, so build-app.sh
runs this instead. Standard library only. Keys are the English text; a missing translation falls back
to English (with a warning), and --strict turns every problem() into an error.
"""
import argparse
import json
import os
import re
import sys

LANGS = ["en", "de", "es", "fr", "zh-Hans", "zh-Hant", "hy"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|@)")
SOURCE_KEY = re.compile(r'\b(?:t|L)\("([^"\\]*)"')


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def _value(entry, lang):
    unit = ((entry or {}).get("localizations") or {}).get(lang, {}).get("stringUnit")
    return unit


def problems(catalog, langs=LANGS):
    found = []
    for key, entry in catalog["strings"].items():
        if "\n" in key or "\\" in key:
            found.append(f"{key}: key contains a newline or backslash")
        wanted = placeholders(key)
        for lang in langs:
            unit = _value(entry, lang)
            if unit is None:
                if lang != "en":
                    found.append(f"{key}: {lang} is missing")
                continue
            if unit.get("state") != "translated":
                found.append(f"{key}: {lang} is not marked translated ({unit.get('state')})")
            got = placeholders(unit.get("value", ""))
            if got != wanted:
                found.append(f"{key}: {lang} has placeholders {got} instead of {wanted}")
    return found


def _escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def strings_file(catalog, lang):
    lines = []
    for key in sorted(catalog["strings"]):
        unit = _value(catalog["strings"][key], lang)
        value = unit["value"] if unit and "value" in unit else key
        lines.append(f'"{_escape(key)}" = "{_escape(value)}";')
    return "\n".join(lines) + "\n"


def write_tables(catalog_paths, out_dir, langs=LANGS):
    written = []
    for path in catalog_paths:
        table = os.path.splitext(os.path.basename(path))[0]
        catalog = load(path)
        for lang in langs:
            folder = os.path.join(out_dir, f"{lang}.lproj")
            os.makedirs(folder, exist_ok=True)
            target = os.path.join(folder, f"{table}.strings")
            with open(target, "w", encoding="utf-8") as f:
                f.write(strings_file(catalog, lang))
            written.append(target)
    return written


def source_keys(swift_dir):
    keys = set()
    for root, _, files in os.walk(swift_dir):
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(root, name), encoding="utf-8") as f:
                    keys.update(SOURCE_KEY.findall(f.read()))
    return keys


def source_problems(catalog, swift_dir):
    used = source_keys(swift_dir)
    known = set(catalog["strings"])
    return ([f"used but not in the catalog: {k}" for k in sorted(used - known)]
            + [f"in the catalog but not used: {k}" for k in sorted(known - used)])


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", nargs="+")
    parser.add_argument("--out")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--check-sources", metavar="SWIFT_DIR")
    args = parser.parse_args(argv)
    if args.check_sources:
        found = source_problems(load(args.catalogs[0]), args.check_sources)
        for p in found:
            print(p)
        return 1 if found else 0
    status = 0
    for path in args.catalogs:
        for p in problems(load(path)):
            print(f"{'error' if args.strict else 'warning'}: {os.path.basename(path)}: {p}", file=sys.stderr)
            status = 1 if args.strict else status
    if status:
        return status
    if args.out:
        for p in write_tables(args.catalogs, args.out):
            print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

An InfoPlist key such as `NSLocalNetworkUsageDescription` has no placeholders and neither has its value, so it passes the same check.

- [ ] **Step 4: Run the tests**

Run: `python3 -m unittest discover -s macos/scripts -p 'test_*.py' -v`
Expected: 7 tests, all OK.

- [ ] **Step 5: Run them in CI too**

In `.github/workflows/conformance.yml`, job `macos-helper`, add after the `actions/setup-python` step:

```yaml
      - name: Localization scripts
        run: python -m unittest discover -s macos/scripts -p 'test_*.py' -v
```

- [ ] **Step 6: Commit**

```bash
git add macos/scripts/strings_from_catalog.py macos/scripts/test_strings_from_catalog.py .github/workflows/conformance.yml
git commit -m "macOS helper: String Catalog converter and checks (no Xcode needed)"
```

---

### Task 3: The app uses the catalog (English), builds the .lproj files, and can print its menu

**Files:**
- Create: `macos/Sources/App/Localized.swift`
- Modify: `macos/Sources/App/AppDelegate.swift`, `PairingPanel.swift`, `NetworkScannerPanel.swift`, `main.swift`
- Modify: `macos/Sources/HelperCore/CommandLineOptions.swift`, `macos/Tests/HelperCoreTests/OptionsTests.swift`
- Create: `macos/Localization/Localizable.xcstrings`, `macos/Localization/InfoPlist.xcstrings`
- Modify: `macos/scripts/build-app.sh`, `macos/Resources/Info.plist`, `macos/scripts/test_strings_from_catalog.py`

**Interfaces:**
- Consumes: `Texts`, `Texts.bundle`, `Texts.errorText(_:)`, `MenuModel.entries(...texts:)` (Task 1); `strings_from_catalog.py` CLI and `source_problems()` (Task 2).
- Produces: `CommandLineOptions.printMenu: Bool` (`--print-menu`); the full key list of `Localizable.xcstrings` (the 43 keys below, English only for now); Task 4 adds the other six languages to these exact keys.

- [ ] **Step 1: Failing tests for the options**

Append to `macos/Tests/HelperCoreTests/OptionsTests.swift`:

```swift
@Test func printMenuFlag() throws {
    #expect(try CommandLineOptions.parse(["--print-menu"]).printMenu)
    #expect(try CommandLineOptions.parse([]).printMenu == false)
}

@Test func cocoaLanguageArgumentsAreSkipped() throws {
    let options = try CommandLineOptions.parse(["--print-menu", "-AppleLanguages", "(hy)", "-AppleLocale", "hy_AM"])
    #expect(options.printMenu)
    #expect(throws: UsageError.self) { try CommandLineOptions.parse(["-AppleLanguages"]) }
}
```

Run: `cd macos && scripts/test.sh` — Expected: compile error, no member `printMenu`.

- [ ] **Step 2: Implement the options**

In `CommandLineOptions.swift`: add `public var printMenu = false`; add to `usage` the line `          --print-menu     print the status menu in the current language and quit (checks translations)`; in `parse`, add the cases:

```swift
            case "--print-menu": options.printMenu = true
            case "-AppleLanguages", "-AppleLocale":
                // Cocoa's own arguments (e.g. -AppleLanguages "(hy)" to try a language); Foundation reads them.
                guard rest.popFirst() != nil else { throw UsageError(message: "\(argument) needs a value.") }
```

Run: `cd macos && scripts/test.sh` — Expected: PASS.

- [ ] **Step 3: Route the App's texts through `L`**

Create `macos/Sources/App/Localized.swift`:

```swift
import HelperCore

/// The texts of the menu and panels, from <lang>.lproj/Localizable.strings in the app bundle
/// (written by scripts/build-app.sh from Localization/Localizable.xcstrings).
let L = Texts.bundle
```

Replace these literals (left: current code, right: new code):

`AppDelegate.swift`
- `alert.messageText = "Dossiary Scan Helper couldn't start"` → `alert.messageText = L("Dossiary Scan Helper couldn't start")`
- `MenuModel.entries(... networkServers: ...)` → add the argument `, texts: L` after `networkServers:`'s closure.
- `alert.messageText = "Couldn't forget the paired browsers"` → `alert.messageText = L("Couldn't forget the paired browsers")`
- The `accessibilityDescription: "Dossiary Scan Helper"` stays (product name).

`PairingPanel.swift`
- `title = "Pair a browser"` → `title = L("Pair a browser")`
- `"Fake scanner mode: this code always works."` → `L("Fake scanner mode: this code always works.")`
- `"Type this code in Dossiary's scan dialog.\nIt works for \(pairing.secondsLeft ?? 0) more seconds."` → `L("Type this code in Dossiary's scan dialog.") + "\n" + L("Seconds left: %lld", pairing.secondsLeft ?? 0)`

`NetworkScannerPanel.swift`
- `NSTextField(wrappingLabelWithString: "Looking for scan servers on the network…")` and the same text in `show()` → `L("Looking for scan servers on the network…")`
- `NSButton(title: "Pair with the Scan button", …)` → `L("Pair with the Scan button")`
- `NSButton(title: "Pair with code", …)` → `L("Pair with code")`
- `title = "Add network scanner"` → `L("Add network scanner")`
- `"or an address, e.g. scanner.local"` → `L("or an address, e.g. scanner.local")`
- `"6-digit code"` → `L("6-digit code")`
- `NSButton(title: "Connect", …)` → `L("Connect")`
- `"No scan server found yet"` → `L("No scan server found yet")`
- `"Choose a scan server or type its address."` → `L("Choose a scan server or type its address.")`
- `"Connecting to \(host)…"` → `L("Connecting to %@…", host)`
- the three-part probe text becomes:

```swift
                detailLabel.stringValue = L("%1$@ at %2$@", found.name, host) + "\n"
                    + L("Fingerprint: %@", RemoteFingerprint.display(found.fingerprint)) + "\n"
                    + L("It should match “scanix500-server status” on the Pi. Then press the button below and, within 2 minutes, the Scan button on the iX500 — or enter a code from “sudo scanix500-server pair”.")
```

- `"Press the Scan button on the iX500 now (2 minutes)…"` → `L("Press the Scan button on the iX500 now (2 minutes)…")`
- `"Pairing…"` → `L("Pairing…")`
- both `detailLabel.stringValue = error.localizedDescription` → `detailLabel.stringValue = L.errorText(error)`

`Host.current().localizedName ?? "Mac"` is the computer's name sent to the server, not shown text: unchanged.

- [ ] **Step 4: `--print-menu` in `main.swift`**

After the `showHelp` line add:

```swift
if options.printMenu {
    // Checks the translations: the menu as the app would show it, in the current language
    // (try another with -AppleLanguages "(de)").
    let entries = MenuModel.entries(scanners: [], port: options.port, fake: false, pairedCount: 0, startAtLogin: false,
                                    networkServers: [NetworkServerEntry(id: "x", name: "scanner", status: .connected)],
                                    texts: L)
    for entry in entries {
        switch entry {
        case .title(let s), .info(let s): print(s)
        case .action(let s, _, _, _): print(s)
        case .separator: print("—")
        }
    }
    exit(0)
}
```

- [ ] **Step 5: The catalogs (English)**

Create `macos/Localization/Localizable.xcstrings` with these 43 keys, each with an empty `localizations` object for now (`"<key>": {"localizations": {}}`), `"sourceLanguage": "en"`, `"version": "1.0"`, keys in this order:

```
Dossiary Scan Helper — fake scanners
Listening on %@
No scanners found
Pair a browser…
Forget paired browsers (%lld)
%1$@: %2$@
Remove “%@”
Add network scanner…
Start at login
Open log
Quit Dossiary Scan Helper
connected
needs pairing again
can't be reached
certificate changed, remove and add it again
checking…
Dossiary Scan Helper couldn't start
Couldn't forget the paired browsers
Pair a browser
Fake scanner mode: this code always works.
Type this code in Dossiary's scan dialog.
Seconds left: %lld
Looking for scan servers on the network…
Pair with the Scan button
Pair with code
Add network scanner
or an address, e.g. scanner.local
6-digit code
Connect
No scan server found yet
Choose a scan server or type its address.
Connecting to %@…
%1$@ at %2$@
Fingerprint: %@
It should match “scanix500-server status” on the Pi. Then press the button below and, within 2 minutes, the Scan button on the iX500 — or enter a code from “sudo scanix500-server pair”.
Press the Scan button on the iX500 now (2 minutes)…
Pairing…
That address doesn't answer like a scanix500 network scan server.
Nobody pressed the Scan button within 2 minutes. Try again.
Another computer asked to pair at the same time. Try again, one computer at a time.
Too many pairing requests. Wait a minute, then try again.
The network scanner can't be reached (%@).
The network scanner presented a different certificate (%@) than when it was paired. If it was reinstalled, remove it in Dossiary Scan Helper and add it again.
```

Write it with a throwaway snippet so the JSON is exact: paste the list into a file `keys.txt` outside the repo and run
`python3 -c "import json,sys; ks=[l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8') if l.strip()]; json.dump({'sourceLanguage':'en','version':'1.0','strings':{k:{'localizations':{}} for k in ks}}, open('macos/Localization/Localizable.xcstrings','w',encoding='utf-8'), ensure_ascii=False, indent=2)" keys.txt`.

Create `macos/Localization/InfoPlist.xcstrings`:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "NSLocalNetworkUsageDescription": {
      "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": "Dossiary Scan Helper looks for scanners on your network."}}
      }
    }
  }
}
```

- [ ] **Step 6: The source check as a test**

Append to `macos/scripts/test_strings_from_catalog.py`, before the `if __name__` line:

```python
HERE = os.path.dirname(os.path.abspath(__file__))
LOCALIZATION = os.path.join(HERE, "..", "Localization")
SOURCES = os.path.join(HERE, "..", "Sources")


class RealCatalogTests(unittest.TestCase):
    def test_every_key_in_the_code_is_in_the_catalog_and_back(self):
        self.assertEqual(sfc.source_problems(sfc.load(os.path.join(LOCALIZATION, "Localizable.xcstrings")), SOURCES), [])

    def test_keys_are_plain(self):
        c = sfc.load(os.path.join(LOCALIZATION, "Localizable.xcstrings"))
        self.assertEqual([p for p in sfc.problems(c, langs=["en"])], [])
```

Run: `python3 -m unittest discover -s macos/scripts -p 'test_*.py' -v` — Expected: OK. If `source_problems` lists a key, the code and the list above disagree: fix the code (the list is the contract).

- [ ] **Step 7: Build the .lproj files into the app; declare the languages**

In `macos/scripts/build-app.sh`, after the `sed … Info.plist` line add:

```bash
python3 scripts/strings_from_catalog.py --out "$APP/Contents/Resources" Localization/Localizable.xcstrings Localization/InfoPlist.xcstrings > /dev/null
for f in "$APP"/Contents/Resources/*.lproj/*.strings; do plutil -lint -s "$f"; done
```

In `macos/Resources/Info.plist`, after the `CFBundleDisplayName` line add:

```xml
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>de</string><string>es</string><string>fr</string><string>zh-Hans</string><string>zh-Hant</string><string>hy</string></array>
```

(`CFBundleLocalizations` is what lets System Settings › Language & Region › Applications offer a language for this app alone.)

- [ ] **Step 8: Build and look**

Run:
```bash
cd macos && scripts/build-app.sh && "build/Dossiary Scan Helper.app/Contents/MacOS/dossiary-scan-helper" --print-menu
```
Expected: the build lists seven `.lproj` folders' files passing `plutil -lint` (warnings about missing translations for six languages are expected at this point); the menu prints in English, ending with `Quit Dossiary Scan Helper`, and contains the line `scanner: connected`.

- [ ] **Step 9: Run all tests, then commit**

Run: `cd macos && scripts/test.sh && cd .. && python3 -m unittest discover -s macos/scripts -p 'test_*.py'`
Expected: all pass.

```bash
git add macos/Sources macos/Tests macos/Localization macos/scripts macos/Resources/Info.plist
git commit -m "macOS helper: texts from the String Catalog; .lproj files built into the app"
```

---

### Task 4: The six translations

**Files:**
- Modify: `macos/Localization/Localizable.xcstrings`, `macos/Localization/InfoPlist.xcstrings`
- Modify: `macos/scripts/test_strings_from_catalog.py`
- Create: `macos/scripts/check-localized-app.sh`

**Interfaces:**
- Consumes: the 43 keys (Task 3), `problems()` (Task 2), `--print-menu` (Task 3).

- [ ] **Step 1: Failing completeness test**

In `RealCatalogTests` add:

```python
    def test_every_language_is_complete(self):
        for name in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
            self.assertEqual(sfc.problems(sfc.load(os.path.join(LOCALIZATION, name))), [], name)
```

Run: `python3 -m unittest discover -s macos/scripts -p 'test_*.py'` — Expected: FAIL, listing `de is missing` etc.

- [ ] **Step 2: Fill in the translations**

Save the table below as `translations.py` in a scratch folder (not committed) and run it from the repo root; it writes every value with `"state": "translated"` into both catalogs. Values are listed in the order de, es, fr, zh-Hans, zh-Hant, hy.

```python
import json

LANGS = ["de", "es", "fr", "zh-Hans", "zh-Hant", "hy"]
T = {
"Dossiary Scan Helper — fake scanners": ["Dossiary Scan Helper — Testscanner", "Dossiary Scan Helper — escáneres de prueba", "Dossiary Scan Helper — scanners de test", "Dossiary Scan Helper — 测试扫描仪", "Dossiary Scan Helper — 測試掃描儀", "Dossiary Scan Helper — փորձնական սկաներներ"],
"Listening on %@": ["Erreichbar unter %@", "Escuchando en %@", "À l'écoute sur %@", "正在监听 %@", "正在監聽 %@", "Լսում է %@ հասցեում"],
"No scanners found": ["Keine Scanner gefunden", "No se encontraron escáneres", "Aucun scanner trouvé", "未找到扫描仪", "未找到掃描儀", "Սկաներներ չեն գտնվել"],
"Pair a browser…": ["Browser koppeln…", "Emparejar un navegador…", "Associer un navigateur…", "配对浏览器…", "配對瀏覽器…", "Զուգակցել դիտարկիչ…"],
"Forget paired browsers (%lld)": ["Gekoppelte Browser vergessen (%lld)", "Olvidar los navegadores emparejados (%lld)", "Oublier les navigateurs associés (%lld)", "忘记已配对的浏览器（%lld）", "忘記已配對的瀏覽器（%lld）", "Մոռանալ զուգակցված դիտարկիչները (%lld)"],
"%1$@: %2$@": ["%1$@: %2$@", "%1$@: %2$@", "%1$@ : %2$@", "%1$@：%2$@", "%1$@：%2$@", "%1$@՝ %2$@"],
"Remove “%@”": ["„%@“ entfernen", "Quitar «%@»", "Retirer « %@ »", "移除“%@”", "移除“%@”", "Հեռացնել «%@»-ը"],
"Add network scanner…": ["Netzwerkscanner hinzufügen…", "Añadir escáner de red…", "Ajouter un scanner réseau…", "添加网络扫描仪…", "添加網絡掃描儀…", "Ավելացնել ցանցային սկաներ…"],
"Start at login": ["Bei der Anmeldung starten", "Abrir al iniciar sesión", "Ouvrir à la connexion", "登录时启动", "登錄時啟動", "Գործարկել մուտք գործելիս"],
"Open log": ["Protokoll öffnen", "Abrir el registro", "Ouvrir le journal", "打开日志", "打開日誌", "Բացել մատյանը"],
"Quit Dossiary Scan Helper": ["Dossiary Scan Helper beenden", "Salir de Dossiary Scan Helper", "Quitter Dossiary Scan Helper", "退出 Dossiary Scan Helper", "退出 Dossiary Scan Helper", "Փակել Dossiary Scan Helper-ը"],
"connected": ["verbunden", "conectado", "connecté", "已连接", "已連接", "միացված է"],
"needs pairing again": ["muss neu gekoppelt werden", "hay que emparejarlo de nuevo", "à associer de nouveau", "需要重新配对", "需要重新配對", "պետք է կրկին զուգակցել"],
"can't be reached": ["nicht erreichbar", "no se puede alcanzar", "injoignable", "无法连接", "無法連接", "հասանելի չէ"],
"certificate changed, remove and add it again": ["Zertifikat geändert, entfernen und neu hinzufügen", "el certificado cambió; quítelo y vuelva a añadirlo", "certificat modifié, retirez-le puis ajoutez-le de nouveau", "证书已更改，请移除后重新添加", "證書已更改，請移除後重新添加", "վկայականը փոխվել է, հեռացրեք և նորից ավելացրեք"],
"checking…": ["wird geprüft…", "comprobando…", "vérification…", "正在检查…", "正在檢查…", "ստուգվում է…"],
"Dossiary Scan Helper couldn't start": ["Dossiary Scan Helper konnte nicht starten", "Dossiary Scan Helper no pudo iniciarse", "Dossiary Scan Helper n'a pas pu démarrer", "Dossiary Scan Helper 无法启动", "Dossiary Scan Helper 無法啟動", "Dossiary Scan Helper-ը չհաջողվեց գործարկել"],
"Couldn't forget the paired browsers": ["Die gekoppelten Browser konnten nicht vergessen werden", "No se pudieron olvidar los navegadores emparejados", "Impossible d'oublier les navigateurs associés", "无法忘记已配对的浏览器", "無法忘記已配對的瀏覽器", "Չհաջողվեց մոռանալ զուգակցված դիտարկիչները"],
"Pair a browser": ["Browser koppeln", "Emparejar un navegador", "Associer un navigateur", "配对浏览器", "配對瀏覽器", "Զուգակցել դիտարկիչ"],
"Fake scanner mode: this code always works.": ["Testscanner-Modus: Dieser Code funktioniert immer.", "Modo de escáneres de prueba: este código siempre funciona.", "Mode scanners de test : ce code fonctionne toujours.", "测试扫描仪模式：此代码始终有效。", "測試掃描儀模式：此代碼始終有效。", "Փորձնական սկաներների ռեժիմ. այս կոդը միշտ աշխատում է։"],
"Type this code in Dossiary's scan dialog.": ["Gib diesen Code im Scan-Dialog von Dossiary ein.", "Escriba este código en el diálogo de escaneo de Dossiary.", "Saisissez ce code dans la fenêtre de numérisation de Dossiary.", "请在 Dossiary 的扫描对话框中输入此代码。", "請在 Dossiary 的掃描對話框中輸入此代碼。", "Մուտքագրեք այս կոդը Dossiary-ի սկանավորման պատուհանում։"],
"Seconds left: %lld": ["Verbleibende Sekunden: %lld", "Segundos restantes: %lld", "Secondes restantes : %lld", "剩余秒数：%lld", "剩餘秒數：%lld", "Մնացած վայրկյաններ՝ %lld"],
"Looking for scan servers on the network…": ["Suche nach Scan-Servern im Netzwerk…", "Buscando servidores de escaneo en la red…", "Recherche de serveurs de numérisation sur le réseau…", "正在网络上查找扫描服务器…", "正在網絡上查找掃描服務器…", "Ցանցում սկանավորման սերվերներ են փնտրվում…"],
"Pair with the Scan button": ["Mit der Scan-Taste koppeln", "Emparejar con el botón Scan", "Associer avec le bouton Scan", "用扫描按钮配对", "用掃描按鈕配對", "Զուգակցել Scan կոճակով"],
"Pair with code": ["Mit Code koppeln", "Emparejar con un código", "Associer avec un code", "用代码配对", "用代碼配對", "Զուգակցել կոդով"],
"Add network scanner": ["Netzwerkscanner hinzufügen", "Añadir escáner de red", "Ajouter un scanner réseau", "添加网络扫描仪", "添加網絡掃描儀", "Ավելացնել ցանցային սկաներ"],
"or an address, e.g. scanner.local": ["oder eine Adresse, z. B. scanner.local", "o una dirección, p. ej. scanner.local", "ou une adresse, p. ex. scanner.local", "或输入地址，例如 scanner.local", "或輸入地址，例如 scanner.local", "կամ հասցե, օրինակ՝ scanner.local"],
"6-digit code": ["6-stelliger Code", "Código de 6 dígitos", "Code à 6 chiffres", "6 位代码", "6 位代碼", "6 նիշանոց կոդ"],
"Connect": ["Verbinden", "Conectar", "Se connecter", "连接", "連接", "Միանալ"],
"No scan server found yet": ["Noch kein Scan-Server gefunden", "Aún no se encontró ningún servidor de escaneo", "Aucun serveur de numérisation trouvé pour l'instant", "尚未找到扫描服务器", "尚未找到掃描服務器", "Սկանավորման սերվեր դեռ չի գտնվել"],
"Choose a scan server or type its address.": ["Wähle einen Scan-Server oder gib seine Adresse ein.", "Elija un servidor de escaneo o escriba su dirección.", "Choisissez un serveur de numérisation ou saisissez son adresse.", "请选择一个扫描服务器或输入其地址。", "請選擇一個掃描服務器或輸入其地址。", "Ընտրեք սկանավորման սերվեր կամ մուտքագրեք դրա հասցեն։"],
"Connecting to %@…": ["Verbinde mit %@…", "Conectando con %@…", "Connexion à %@…", "正在连接 %@…", "正在連接 %@…", "Միանում է %@-ին…"],
"%1$@ at %2$@": ["%1$@ unter %2$@", "%1$@ en %2$@", "%1$@ à %2$@", "%1$@（%2$@）", "%1$@（%2$@）", "%1$@ (%2$@)"],
"Fingerprint: %@": ["Fingerabdruck: %@", "Huella digital: %@", "Empreinte : %@", "指纹：%@", "指紋：%@", "Մատնահետք՝ %@"],
"It should match “scanix500-server status” on the Pi. Then press the button below and, within 2 minutes, the Scan button on the iX500 — or enter a code from “sudo scanix500-server pair”.": [
  "Er sollte mit „scanix500-server status“ auf dem Pi übereinstimmen. Drücke dann die Taste unten und innerhalb von 2 Minuten die Scan-Taste am iX500 — oder gib einen Code von „sudo scanix500-server pair“ ein.",
  "Debe coincidir con «scanix500-server status» en la Pi. Luego pulse el botón de abajo y, en menos de 2 minutos, el botón Scan del iX500, o escriba un código de «sudo scanix500-server pair».",
  "Elle doit correspondre à « scanix500-server status » sur le Pi. Appuyez ensuite sur le bouton ci-dessous puis, dans les 2 minutes, sur le bouton Scan de l'iX500 — ou saisissez un code obtenu avec « sudo scanix500-server pair ».",
  "它应与树莓派上“scanix500-server status”显示的一致。然后点击下方按钮，并在 2 分钟内按下 iX500 上的扫描按钮——或输入“sudo scanix500-server pair”给出的代码。",
  "它應與樹莓派上“scanix500-server status”顯示的一致。然後點擊下方按鈕，並在 2 分鐘內按下 iX500 上的掃描按鈕——或輸入“sudo scanix500-server pair”給出的代碼。",
  "Այն պետք է համընկնի Pi-ի վրա «scanix500-server status»-ի ցուցադրածի հետ։ Ապա սեղմեք ներքևի կոճակը և 2 րոպեի ընթացքում՝ iX500-ի Scan կոճակը, կամ մուտքագրեք «sudo scanix500-server pair»-ի տված կոդը։"],
"Press the Scan button on the iX500 now (2 minutes)…": ["Drücke jetzt die Scan-Taste am iX500 (2 Minuten)…", "Pulse ahora el botón Scan del iX500 (2 minutos)…", "Appuyez maintenant sur le bouton Scan de l'iX500 (2 minutes)…", "请现在按下 iX500 上的扫描按钮（2 分钟内）…", "請現在按下 iX500 上的掃描按鈕（2 分鐘內）…", "Հիմա սեղմեք iX500-ի Scan կոճակը (2 րոպե)…"],
"Pairing…": ["Kopple…", "Emparejando…", "Association…", "正在配对…", "正在配對…", "Զուգակցում…"],
"That address doesn't answer like a scanix500 network scan server.": ["Diese Adresse antwortet nicht wie ein scanix500-Netzwerk-Scan-Server.", "Esa dirección no responde como un servidor de escaneo en red de scanix500.", "Cette adresse ne répond pas comme un serveur de numérisation réseau scanix500.", "该地址的响应不像 scanix500 网络扫描服务器。", "該地址的響應不像 scanix500 網絡掃描服務器。", "Այս հասցեն չի պատասխանում scanix500 ցանցային սկանավորման սերվերի պես։"],
"Nobody pressed the Scan button within 2 minutes. Try again.": ["Niemand hat innerhalb von 2 Minuten die Scan-Taste gedrückt. Versuch es noch einmal.", "Nadie pulsó el botón Scan en 2 minutos. Inténtelo de nuevo.", "Personne n'a appuyé sur le bouton Scan dans les 2 minutes. Réessayez.", "2 分钟内无人按下扫描按钮。请重试。", "2 分鐘內無人按下掃描按鈕。請重試。", "2 րոպեի ընթացքում ոչ ոք չսեղմեց Scan կոճակը։ Փորձեք կրկին։"],
"Another computer asked to pair at the same time. Try again, one computer at a time.": ["Ein anderer Computer wollte gleichzeitig koppeln. Versuch es noch einmal, ein Computer nach dem anderen.", "Otro ordenador pidió emparejarse al mismo tiempo. Inténtelo de nuevo, un ordenador cada vez.", "Un autre ordinateur a demandé l'association en même temps. Réessayez, un ordinateur à la fois.", "另一台电脑同时请求配对。请重试，一次只配对一台电脑。", "另一臺電腦同時請求配對。請重試，一次只配對一臺電腦。", "Մեկ այլ համակարգիչ միաժամանակ զուգակցում խնդրեց։ Փորձեք կրկին՝ մեկ համակարգիչ մեկ անգամ։"],
"Too many pairing requests. Wait a minute, then try again.": ["Zu viele Kopplungsanfragen. Warte eine Minute und versuch es dann noch einmal.", "Demasiadas solicitudes de emparejamiento. Espere un minuto y vuelva a intentarlo.", "Trop de demandes d'association. Patientez une minute, puis réessayez.", "配对请求过多。请等待一分钟后重试。", "配對請求過多。請等待一分鐘後重試。", "Չափազանց շատ զուգակցման հարցումներ։ Սպասեք մեկ րոպե, ապա փորձեք կրկին։"],
"The network scanner can't be reached (%@).": ["Der Netzwerkscanner ist nicht erreichbar (%@).", "No se puede alcanzar el escáner de red (%@).", "Le scanner réseau est injoignable (%@).", "无法连接网络扫描仪（%@）。", "無法連接網絡掃描儀（%@）。", "Ցանցային սկաները հասանելի չէ (%@)։"],
"The network scanner presented a different certificate (%@) than when it was paired. If it was reinstalled, remove it in Dossiary Scan Helper and add it again.": [
  "Der Netzwerkscanner hat ein anderes Zertifikat (%@) vorgelegt als beim Koppeln. Wurde er neu installiert, entferne ihn in Dossiary Scan Helper und füge ihn neu hinzu.",
  "El escáner de red presentó un certificado distinto (%@) del que tenía al emparejarlo. Si se reinstaló, quítelo en Dossiary Scan Helper y vuelva a añadirlo.",
  "Le scanner réseau a présenté un certificat différent (%@) de celui de l'association. S'il a été réinstallé, retirez-le dans Dossiary Scan Helper puis ajoutez-le de nouveau.",
  "网络扫描仪出示的证书（%@）与配对时不同。如果它已重新安装，请在 Dossiary Scan Helper 中移除后重新添加。",
  "網絡掃描儀出示的證書（%@）與配對時不同。如果它已重新安裝，請在 Dossiary Scan Helper 中移除後重新添加。",
  "Ցանցային սկաները ներկայացրեց այլ վկայական (%@), քան զուգակցման ժամանակ։ Եթե այն վերատեղադրվել է, հեռացրեք այն Dossiary Scan Helper-ում և նորից ավելացրեք։"],
}
PLIST = ["Dossiary Scan Helper sucht in deinem Netzwerk nach Scannern.", "Dossiary Scan Helper busca escáneres en su red.",
         "Dossiary Scan Helper recherche des scanners sur votre réseau.", "Dossiary Scan Helper 会在您的网络上查找扫描仪。",
         "Dossiary Scan Helper 會在您的網絡上查找掃描儀。", "Dossiary Scan Helper-ը Ձեր ցանցում սկաներներ է փնտրում։"]

def put(entry, lang, value):
    entry.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "translated", "value": value}}

path = "macos/Localization/Localizable.xcstrings"
c = json.load(open(path, encoding="utf-8"))
assert set(c["strings"]) == set(T), set(c["strings"]) ^ set(T)
for key, values in T.items():
    for lang, value in zip(LANGS, values):
        put(c["strings"][key], lang, value)
json.dump(c, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

path = "macos/Localization/InfoPlist.xcstrings"
c = json.load(open(path, encoding="utf-8"))
for lang, value in zip(LANGS, PLIST):
    put(c["strings"]["NSLocalNetworkUsageDescription"], lang, value)
json.dump(c, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
```

The zh-Hant column is the zh-Hans column converted the way Dossiary's own Traditional Chinese was (OpenCC `s2t`). Check it once: `python3 -m venv /tmp/occ && /tmp/occ/bin/pip -q install opencc-python-reimplemented && /tmp/occ/bin/python -c "import json,opencc; c=json.load(open('macos/Localization/Localizable.xcstrings',encoding='utf-8')); cv=opencc.OpenCC('s2t'); bad=[k for k,e in c['strings'].items() if cv.convert(e['localizations']['zh-Hans']['stringUnit']['value'])!=e['localizations']['zh-Hant']['stringUnit']['value']]; print(bad)"` — Expected: `[]`. If it lists keys, take OpenCC's output for those keys.

- [ ] **Step 3: Run the tests**

Run: `python3 -m unittest discover -s macos/scripts -p 'test_*.py' -v`
Expected: all OK, including `test_every_language_is_complete`.

- [ ] **Step 4: Check the built app in four languages**

Create `macos/scripts/check-localized-app.sh`:

```bash
#!/bin/bash
# Prints the built app's menu in four languages and checks one line of each (needs scripts/build-app.sh first).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="build/Dossiary Scan Helper.app/Contents/MacOS/dossiary-scan-helper"
[ -x "$BIN" ] || { echo "Run scripts/build-app.sh first."; exit 1; }
check() {
  local out
  out=$("$BIN" --print-menu -AppleLanguages "($1)")
  grep -qF "$2" <<<"$out" || { echo "$1: expected \"$2\" in:"; echo "$out"; exit 1; }
  echo "$1: ok ($2)"
}
check en "Pair a browser…"
check de "Browser koppeln…"
check zh-Hant "配對瀏覽器…"
check hy "Զուգակցել դիտարկիչ…"
```

Run: `chmod +x macos/scripts/check-localized-app.sh && cd macos && scripts/build-app.sh && scripts/check-localized-app.sh`
Expected: no missing-translation warnings from the build; four `ok` lines.

- [ ] **Step 5: Commit**

```bash
git add macos/Localization macos/scripts/test_strings_from_catalog.py macos/scripts/check-localized-app.sh
git commit -m "macOS helper: German, Spanish, French, Chinese and Armenian"
```

---

### Task 5: Docs and version

**Files:**
- Modify: `macos/README.md`, `docs/install-macos.md`, `docs/manual-check-macos.md`, `README.md`, `macos/Sources/HelperCore/Version.swift`, and any test or doc that asserts the version string `0.3.0` as the current version (find them with `grep -rn '0\.3\.0' macos/Sources macos/Tests conformance reference docs README.md`; leave historical mentions such as "0.3.0 or later" alone).

- [ ] **Step 1: Version**

`Version.swift`: `public static let string = "0.4.0"`. Run `cd macos && scripts/test.sh` and fix any test that pinned `0.3.0` as the current version.

- [ ] **Step 2: `macos/README.md`** — add a section after "Build and test":

```markdown
## Languages

The menu and panels are in English, German, Spanish, French, Chinese (Simplified and Traditional) and
Armenian. All texts live in `Localization/Localizable.xcstrings` (and the network-permission prompt in
`Localization/InfoPlist.xcstrings`); the English text is the key. Xcode isn't needed: `scripts/build-app.sh`
turns the catalogs into `<lang>.lproj` files with `scripts/strings_from_catalog.py`. To change a text,
edit the catalog (by hand or in Xcode) and keep every language: `python3 -m unittest discover -s
scripts -p 'test_*.py'` fails on a missing translation, a changed placeholder, or a key the code uses
that isn't in the catalog. After a build, `scripts/check-localized-app.sh` prints the menu in four
languages; `dossiary-scan-helper --print-menu -AppleLanguages "(fr)"` shows any other. Messages the
helper sends to Dossiary stay English.
```

- [ ] **Step 3: `docs/install-macos.md`** — add a section before "Files it keeps":

```markdown
## Language

The helper follows your Mac's preferred languages (System Settings › General › Language & Region). It
speaks English, German, Spanish, French, Chinese (Simplified and Traditional) and Armenian. To use one
of them for the helper alone, add Dossiary Scan Helper under "Applications" on that page and choose the
language; quit and reopen the helper.
```

- [ ] **Step 4: `docs/manual-check-macos.md`** — add a numbered item at the end of its list, in the list's own style:

```markdown
- Languages: set Dossiary Scan Helper to German in System Settings › General › Language & Region ›
  Applications, reopen it: the menu, "Pair a browser…" and "Add network scanner…" are German. Do the
  same with Armenian (add Հայերեն under Preferred Languages first if macOS doesn't offer it for the app).
  Set it back.
```

- [ ] **Step 5: `README.md`** — in the macOS helper row/paragraph, add "Its menu and panels are in seven languages (English, German, Spanish, French, Chinese Simplified and Traditional, Armenian)."

- [ ] **Step 6: Everything green, then commit**

Run: `cd macos && scripts/test.sh && scripts/build-app.sh && scripts/check-localized-app.sh && cd .. && python3 -m unittest discover -s macos/scripts -p 'test_*.py' && macos/scripts/run-conformance.sh`
Expected: all pass.

```bash
git add -A macos docs README.md
git commit -m "macOS helper 0.4.0: seven languages"
```

---

## After the tasks (controller, not a task)

- Add the helper's 44 texts (43 + the permission prompt) to the Armenian review page as a "Dossiary Scan Helper (macOS)" group; give the user the English list for Grammarly.
- Release only with the user's OK: `scripts/build-app.sh`, `scripts/sign-and-notarize.sh`, tag `macos-v0.4.0` per the repo's existing release convention, GitHub release, install into `/Applications/Dossiary/`.
