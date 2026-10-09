"""Conformance suite for the Dossiary scan bridge protocol v2.

Run against a helper in fake scanner mode:
    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v
"""

import base64
import re
import threading
import time
import unittest

from client import BASE_URL, request

FAKE_IDS = ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam", "fake:slow", "fake:offline"]


def setUpModule():
    try:
        resp = request("GET", "/health", timeout=5)
    except OSError as err:
        raise RuntimeError(f"No helper answering at {BASE_URL} ({err}). Start one, or set SCAN_HELPER_URL.")
    if resp.status != 200:
        raise RuntimeError(f"{BASE_URL}/health answered {resp.status}")


def scan(body, **kw):
    return request("POST", "/scan", body=body, **kw)


def assert_error(case, resp, status):
    case.assertEqual(resp.status, status, resp.body[:200])
    case.assertTrue(resp.headers.get("Content-Type", "").startswith("application/json"), "error body must be JSON")
    data = resp.json()
    case.assertIs(data["ok"], False)
    case.assertIs(data["partial"], False)
    case.assertIsInstance(data["message"], str)
    case.assertTrue(data["message"].strip())


class HealthTests(unittest.TestCase):
    def test_health(self):
        resp = request("GET", "/health")
        self.assertEqual(resp.status, 200)
        data = resp.json()
        self.assertIs(data["ok"], True)
        self.assertEqual(data["protocol"], 2)
        self.assertIsInstance(data["helper"], str)
        self.assertTrue(data["helper"])
        self.assertIsInstance(data["version"], str)
        self.assertTrue(data["version"])
        self.assertTrue(resp.headers.get("Content-Type", "").startswith("application/json"))


class ScannersTests(unittest.TestCase):
    def test_lists_the_six_fake_scanners_with_all_fields(self):
        resp = request("GET", "/scanners")
        self.assertEqual(resp.status, 200)
        scanners = resp.json()["scanners"]
        self.assertEqual(sorted(s["id"] for s in scanners), sorted(FAKE_IDS))
        for s in scanners:
            self.assertIsInstance(s["name"], str)
            self.assertTrue(set(s["sources"]) <= {"flatbed", "feeder"} and s["sources"])
            self.assertIsInstance(s["duplex"], bool)
            self.assertTrue(set(s["colorModes"]) <= {"color", "gray", "bw"} and s["colorModes"])
            self.assertTrue(all(isinstance(r, int) for r in s["resolutions"]) and s["resolutions"])
            self.assertEqual(s["resolutions"], sorted(s["resolutions"]))
            self.assertIsInstance(s["extras"], list)

    def test_fake_scanner_details(self):
        scanners = {s["id"]: s for s in request("GET", "/scanners").json()["scanners"]}
        self.assertEqual(scanners["fake:feeder"]["sources"], ["feeder", "flatbed"])
        self.assertIs(scanners["fake:feeder"]["duplex"], True)
        self.assertIs(scanners["fake:flatbed"]["duplex"], False)
        self.assertEqual(sorted(scanners["fake:splitter"]["extras"]), ["skipBlankPages", "splitOnBlank"])
        self.assertEqual(scanners["fake:flatbed"]["extras"], [])


class ScanTests(unittest.TestCase):
    def assertPdfFiles(self, resp, page_counts):
        data = resp.json()
        self.assertEqual([f["pages"] for f in data["files"]], page_counts)
        names = [f["name"] for f in data["files"]]
        self.assertEqual(len(set(names)), len(names))
        for f in data["files"]:
            self.assertTrue(f["name"].endswith(".pdf"))
            pdf = base64.b64decode(f["data"], validate=True)
            self.assertTrue(pdf.startswith(b"%PDF-"))
            self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))
            counted = len(re.findall(rb"/Type\s*/Page(?!s)", pdf))
            if counted:  # writers that compress page objects can't be counted this way
                self.assertEqual(counted, f["pages"])
        return data

    def test_flatbed_minimal_request(self):
        resp = scan({"scanner": "fake:flatbed"})
        self.assertEqual(resp.status, 200)
        data = self.assertPdfFiles(resp, [1])
        self.assertIs(data["ok"], True)
        self.assertIs(data["partial"], False)
        self.assertEqual(data["message"], "1 page scanned.")

    def test_full_request(self):
        resp = scan({"scanner": "fake:feeder", "source": "feeder", "duplex": False, "colorMode": "gray",
                     "resolution": 300, "format": "pdf", "extras": {}})
        self.assertEqual(resp.status, 200)
        self.assertEqual(self.assertPdfFiles(resp, [3])["message"], "3 pages scanned.")

    def test_duplex(self):
        resp = scan({"scanner": "fake:feeder", "duplex": True})
        self.assertEqual(resp.status, 200)
        self.assertPdfFiles(resp, [6])

    def test_feeder_scanner_flatbed_source(self):
        resp = scan({"scanner": "fake:feeder", "source": "flatbed"})
        self.assertEqual(resp.status, 200)
        self.assertPdfFiles(resp, [1])

    def test_splitter_extras(self):
        self.assertPdfFiles(scan({"scanner": "fake:splitter"}), [4])
        self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"skipBlankPages": True}}), [3])
        self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"splitOnBlank": True}}), [2, 1])
        self.assertPdfFiles(scan({"scanner": "fake:splitter",
                                  "extras": {"splitOnBlank": True, "skipBlankPages": True}}), [2, 1])

    def test_unknown_extra_set_false_is_accepted(self):
        resp = scan({"scanner": "fake:flatbed", "extras": {"splitOnBlank": False}})
        self.assertEqual(resp.status, 200)

    def test_jam_is_partial(self):
        resp = scan({"scanner": "fake:jam"})
        self.assertEqual(resp.status, 200)
        data = self.assertPdfFiles(resp, [2])
        self.assertIs(data["ok"], False)
        self.assertIs(data["partial"], True)
        self.assertIn("jam", data["message"].lower())


class ErrorTests(unittest.TestCase):
    def assertError(self, resp, status):
        assert_error(self, resp, status)

    def test_400_malformed(self):
        self.assertError(request("POST", "/scan", raw_body=b"{not json",
                                 headers={"Content-Type": "application/json"}), 400)
        self.assertError(scan([1, 2]), 400)
        self.assertError(scan({}), 400)
        self.assertError(scan({"scanner": 7}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": "300"}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "duplex": "yes"}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "extras": ["splitOnBlank"]}), 400)

    def test_404(self):
        self.assertError(scan({"scanner": "fake:does-not-exist"}), 404)
        self.assertError(request("GET", "/no-such-endpoint"), 404)

    def test_405_wrong_method(self):
        self.assertError(request("GET", "/scan"), 405)
        self.assertError(request("POST", "/health", body={}), 405)

    def test_422_unsupported_settings(self):
        self.assertError(scan({"scanner": "fake:flatbed", "source": "feeder"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "colorMode": "sepia"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": 1200}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "format": "tiff"}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "duplex": True}), 422)
        self.assertError(scan({"scanner": "fake:feeder", "source": "flatbed", "duplex": True}), 422)
        self.assertError(scan({"scanner": "fake:flatbed", "extras": {"splitOnBlank": True}}), 422)

    def test_503_offline(self):
        self.assertError(scan({"scanner": "fake:offline"}), 503)

    def test_409_while_another_scan_runs(self):
        results = {}
        def slow_scan():
            try:
                results["slow"] = scan({"scanner": "fake:slow"})
            except Exception as err:  # keep the failure visible below
                results["slow"] = err
        worker = threading.Thread(target=slow_scan)
        worker.start()
        try:
            time.sleep(0.5)
            assert_error(self, scan({"scanner": "fake:flatbed"}), 409)
        finally:
            worker.join(timeout=30)
        self.assertFalse(worker.is_alive(), "slow scan did not finish")
        self.assertNotIsInstance(results.get("slow"), Exception, results.get("slow"))
        self.assertEqual(results["slow"].status, 200)
        # Once the slow scan is done, the helper accepts scans again.
        self.assertEqual(scan({"scanner": "fake:flatbed"}).status, 200)


class ValidationOrderTests(unittest.TestCase):
    def test_unknown_scanner_beats_wrong_type(self):
        assert_error(self, scan({"scanner": "fake:nope", "resolution": "300"}), 404)

    def test_wrong_type_beats_unsupported_value(self):
        assert_error(self, scan({"scanner": "fake:flatbed", "resolution": "300", "colorMode": "sepia"}), 400)

    def test_unsupported_value_beats_offline(self):
        assert_error(self, scan({"scanner": "fake:offline", "resolution": 1200}), 422)

    def test_while_busy(self):
        results = {}
        def slow_scan():
            try:
                results["slow"] = scan({"scanner": "fake:slow"})
            except Exception as err:  # keep the failure visible below
                results["slow"] = err
        worker = threading.Thread(target=slow_scan)
        worker.start()
        try:
            time.sleep(0.5)
            # Validation (steps 1-5) comes before the busy check (step 6) ...
            assert_error(self, scan({"scanner": "fake:nope"}), 404)
            assert_error(self, scan({"scanner": "fake:flatbed", "resolution": 1200}), 422)
            # ... and busy (step 6) comes before offline (step 7).
            assert_error(self, scan({"scanner": "fake:offline"}), 409)
        finally:
            worker.join(timeout=30)
        self.assertFalse(worker.is_alive(), "slow scan did not finish")
        self.assertNotIsInstance(results.get("slow"), Exception, results.get("slow"))
        self.assertEqual(results["slow"].status, 200)


class OriginTests(unittest.TestCase):
    def test_no_origin_is_allowed(self):
        self.assertEqual(request("GET", "/health").status, 200)

    def test_allowed_origins_are_echoed(self):
        for origin in ["null", "http://localhost", "http://localhost:5173", "http://127.0.0.1:8833"]:
            resp = request("GET", "/health", headers={"Origin": origin})
            self.assertEqual(resp.status, 200, origin)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), origin)
            self.assertIn("Origin", resp.headers.get("Vary", ""))

    def test_other_origins_get_403(self):
        for origin in ["https://evil.example", "http://localhost.evil.example", "https://localhost:5173",
                       "http://192.168.1.5:8766"]:
            resp = request("GET", "/health", headers={"Origin": origin})
            assert_error(self, resp, 403)
            self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"))
        resp = scan({"scanner": "fake:flatbed"}, headers={"Origin": "https://evil.example"})
        assert_error(self, resp, 403)

    def test_preflight(self):
        resp = request("OPTIONS", "/scan", headers={
            "Origin": "null", "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
            "Access-Control-Request-Private-Network": "true"})
        self.assertEqual(resp.status, 204)
        self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), "null")
        self.assertIn("POST", resp.headers.get("Access-Control-Allow-Methods", ""))
        self.assertIn("content-type", resp.headers.get("Access-Control-Allow-Headers", "").lower())
        self.assertEqual(resp.headers.get("Access-Control-Allow-Private-Network"), "true")
        self.assertEqual(resp.headers.get("Access-Control-Allow-Methods"), "GET, POST, OPTIONS")
        self.assertEqual(resp.headers.get("Access-Control-Allow-Headers", "").lower(), "content-type")
        self.assertEqual(resp.headers.get("Access-Control-Max-Age"), "600")

    def test_preflight_without_private_network_request(self):
        resp = request("OPTIONS", "/scan", headers={
            "Origin": "null", "Access-Control-Request-Method": "POST"})
        self.assertEqual(resp.status, 204)
        self.assertIsNone(resp.headers.get("Access-Control-Allow-Private-Network"))

    def test_preflight_on_every_endpoint(self):
        for path in ["/health", "/scanners", "/no-such-endpoint"]:
            resp = request("OPTIONS", path, headers={
                "Origin": "http://localhost:5173", "Access-Control-Request-Method": "GET"})
            self.assertEqual(resp.status, 204, path)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), "http://localhost:5173", path)

    def test_preflight_from_other_origin_is_403(self):
        resp = request("OPTIONS", "/scan", headers={"Origin": "https://evil.example",
                                                    "Access-Control-Request-Method": "POST"})
        assert_error(self, resp, 403)


if __name__ == "__main__":
    unittest.main()
