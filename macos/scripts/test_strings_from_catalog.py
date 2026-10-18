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


HERE = os.path.dirname(os.path.abspath(__file__))
LOCALIZATION = os.path.join(HERE, "..", "Localization")
SOURCES = os.path.join(HERE, "..", "Sources")


class RealCatalogTests(unittest.TestCase):
    def test_every_key_in_the_code_is_in_the_catalog_and_back(self):
        self.assertEqual(sfc.source_problems(sfc.load(os.path.join(LOCALIZATION, "Localizable.xcstrings")), SOURCES), [])

    def test_keys_are_plain(self):
        c = sfc.load(os.path.join(LOCALIZATION, "Localizable.xcstrings"))
        self.assertEqual([p for p in sfc.problems(c, langs=["en"])], [])

    def test_every_language_is_complete(self):
        for name in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
            self.assertEqual(sfc.problems(sfc.load(os.path.join(LOCALIZATION, name))), [], name)


if __name__ == "__main__":
    unittest.main()
