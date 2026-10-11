import time
import unittest

from scanbridge_ref import fakes
from scanbridge_ref.fakes import FAKE_SCANNERS, ScanError, simulate, validate


def by_id(scanner_id):
    return next(s for s in FAKE_SCANNERS if s.id == scanner_id)


class DescribeTests(unittest.TestCase):
    def test_seven_scanners_in_protocol_order(self):
        self.assertEqual([s.id for s in FAKE_SCANNERS][:7],
                         ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam", "fake:slow", "fake:offline",
                          "fake:empty"])

    def test_empty_feeder_description(self):
        self.assertEqual(by_id("fake:empty").describe(), {
            "id": "fake:empty", "name": "Fake Empty Feeder", "sources": ["feeder"], "duplex": False,
            "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600], "extras": [],
        })

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
                                    "resolution": 150, "format": "pdf", "extras": {},
                                    "ocr": False, "ocrLanguages": []})

    def test_400s(self):
        self.assertStatus([1, 2], 400)
        self.assertStatus({}, 400)
        self.assertStatus({"scanner": 5}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": "300"}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": True}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "resolution": 300.0}, 400)
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

    def test_empty_feeder_is_500(self):
        scanner, settings = validate({"scanner": "fake:empty"})
        with self.assertRaises(ScanError) as ctx:
            simulate(scanner, settings)
        self.assertEqual(ctx.exception.status, 500)
        self.assertEqual(ctx.exception.message, "No paper in the feeder.")

    def test_slow_takes_its_delay(self):
        scanner, settings = validate({"scanner": "fake:slow"})
        self.assertGreaterEqual(scanner.delay, 2.0)
        fast = fakes.FakeScanner(**{**scanner.__dict__, "delay": 0.2})
        start = time.monotonic()
        simulate(fast, settings)
        self.assertGreaterEqual(time.monotonic() - start, 0.2)



class OcrFakeTests(unittest.TestCase):
    def test_eight_scanners_with_fake_ocr_last(self):
        self.assertEqual([s.id for s in FAKE_SCANNERS][-1], "fake:ocr")
        self.assertEqual(by_id("fake:ocr").describe(), {
            "id": "fake:ocr", "name": "Fake OCR Scanner", "sources": ["flatbed"], "duplex": False,
            "colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600], "extras": [],
            "ocr": {"languages": ["deu", "eng"]},
        })
        self.assertNotIn("ocr", by_id("fake:flatbed").describe())

    def assertStatus(self, body, status):
        with self.assertRaises(ScanError) as ctx:
            validate(body)
        self.assertEqual(ctx.exception.status, status)

    def test_ocr_fields(self):
        self.assertStatus({"scanner": "fake:ocr", "ocr": "yes"}, 400)
        self.assertStatus({"scanner": "fake:ocr", "ocrLanguages": "deu"}, 400)
        self.assertStatus({"scanner": "fake:ocr", "ocrLanguages": [1]}, 400)
        self.assertStatus({"scanner": "fake:flatbed", "ocr": True}, 422)
        self.assertStatus({"scanner": "fake:ocr", "ocr": True, "ocrLanguages": ["xyz"]}, 422)
        _, settings = validate({"scanner": "fake:ocr", "ocr": True})
        self.assertEqual((settings["ocr"], settings["ocrLanguages"]), (True, []))
        _, settings = validate({"scanner": "fake:flatbed", "ocr": False, "ocrLanguages": ["xyz"]})
        self.assertIs(settings["ocr"], False)


if __name__ == "__main__":
    unittest.main()
