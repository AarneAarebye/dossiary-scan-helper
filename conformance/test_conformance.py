"""Conformance suite for the Dossiary scan bridge protocol v2.

Run against a helper in fake scanner mode:
    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v
"""

import base64
import re
import threading
import time
import unittest

import client
from client import BASE_URL, raw_request, request

FAKE_PAIRING_CODE = "000000"
TOKEN_PATTERN = r"\A[A-Za-z0-9_-]{22,}\Z"

_STANDARD = {"colorModes": ["color", "gray", "bw"], "resolutions": [150, 300, 600]}
# The complete /scanners entries of PROTOCOL.md's fake scanner table.
FAKE_SCANNERS = {
    "fake:flatbed": {"name": "Fake Flatbed", "sources": ["flatbed"], "duplex": False, "extras": []},
    "fake:feeder": {"name": "Fake Feeder", "sources": ["feeder", "flatbed"], "duplex": True, "extras": []},
    "fake:splitter": {"name": "Fake Splitter", "sources": ["feeder"], "duplex": False,
                      "extras": ["splitOnBlank", "skipBlankPages"]},
    "fake:jam": {"name": "Fake Jamming Feeder", "sources": ["feeder"], "duplex": False, "extras": []},
    "fake:slow": {"name": "Fake Slow Scanner", "sources": ["flatbed"], "duplex": False, "extras": []},
    "fake:offline": {"name": "Fake Offline Scanner", "sources": ["flatbed"], "duplex": False, "extras": []},
    "fake:empty": {"name": "Fake Empty Feeder", "sources": ["feeder"], "duplex": False, "extras": []},
}
FAKE_IDS = list(FAKE_SCANNERS)
# Optional until every helper does background OCR (PROTOCOL.md, "Fake scanner mode").
OPTIONAL_FAKES = {
    "fake:ocr": {"name": "Fake OCR Scanner", "sources": ["flatbed"], "duplex": False, "extras": [],
                 "ocr": {"languages": ["deu", "eng"]}},
}


def listed_ids():
    return {s["id"] for s in request("GET", "/scanners").json()["scanners"]}


def pair_request(body, **kw):
    return request("POST", "/pair", body=body, auth=None, **kw)


def setUpModule():
    try:
        resp = request("GET", "/health", timeout=5, auth=None)
    except OSError as err:
        raise RuntimeError(f"No helper answering at {BASE_URL} ({err}). Start one, or set SCAN_HELPER_URL.")
    if resp.status != 200:
        raise RuntimeError(f"{BASE_URL}/health answered {resp.status}")
    resp = pair_request({"code": FAKE_PAIRING_CODE, "client": "conformance suite"}, timeout=5)
    if resp.status != 200:
        raise RuntimeError(f"Pairing with code {FAKE_PAIRING_CODE} answered {resp.status}: {resp.body[:200]!r}. "
                           "Is the helper in fake scanner mode?")
    client.TOKEN = resp.json()["token"]


def scan(body, **kw):
    return request("POST", "/scan", body=body, **kw)


def assert_cors(case, resp, origin):
    case.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), origin, resp.status)
    case.assertIn("Origin", resp.headers.get("Vary", ""), resp.status)


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

    def test_query_string_is_ignored(self):
        self.assertEqual(request("GET", "/health?x=1").status, 200)
        self.assertEqual(request("GET", "/scanners?x=1").status, 200)


class ScannersTests(unittest.TestCase):
    def test_lists_the_seven_fake_scanners_with_all_fields(self):
        resp = request("GET", "/scanners")
        self.assertEqual(resp.status, 200)
        scanners = resp.json()["scanners"]
        ids = sorted(s["id"] for s in scanners)
        optional = sorted(i for i in ids if i in OPTIONAL_FAKES)
        self.assertEqual(ids, sorted(FAKE_IDS + optional))
        for s in scanners:
            self.assertIsInstance(s["name"], str)
            self.assertTrue(set(s["sources"]) <= {"flatbed", "feeder"} and s["sources"])
            self.assertIsInstance(s["duplex"], bool)
            self.assertTrue(set(s["colorModes"]) <= {"color", "gray", "bw"} and s["colorModes"])
            self.assertTrue(all(isinstance(r, int) for r in s["resolutions"]) and s["resolutions"])
            self.assertEqual(s["resolutions"], sorted(s["resolutions"]))
            self.assertIsInstance(s["extras"], list)
            if "ocr" in s:
                self.assertIsInstance(s["ocr"]["languages"], list)
                self.assertTrue(s["ocr"]["languages"] and all(isinstance(l, str) for l in s["ocr"]["languages"]))

    def test_fake_scanner_table(self):
        scanners = {s["id"]: s for s in request("GET", "/scanners").json()["scanners"]}
        expected_table = dict(FAKE_SCANNERS)
        expected_table.update({i: e for i, e in OPTIONAL_FAKES.items() if i in scanners})
        self.assertEqual(len(scanners), len(expected_table))
        for scanner_id, expected in expected_table.items():
            actual = dict(scanners[scanner_id])
            # The order of extras carries no meaning; every other list's order does.
            actual["extras"] = sorted(actual["extras"])
            self.assertEqual(actual, {"id": scanner_id, **expected, **_STANDARD,
                                      "extras": sorted(expected["extras"])}, scanner_id)


class ScanTests(unittest.TestCase):
    def assertPdfFiles(self, resp, page_counts):
        data = resp.json()
        self.assertEqual([f["pages"] for f in data["files"]], page_counts)
        names = [f["name"] for f in data["files"]]
        self.assertEqual(len(set(names)), len(names), "file names must be unique")
        for f in data["files"]:
            self.assertTrue(f["name"].endswith(".pdf"), f["name"])
            self.assertNotIn("/", f["name"])
            self.assertNotIn("\\", f["name"])
            self.assertFalse(f["name"].startswith("."), f["name"])
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
        self.assertEqual(self.assertPdfFiles(resp, [6])["message"], "6 pages scanned.")

    def test_feeder_scanner_flatbed_source(self):
        resp = scan({"scanner": "fake:feeder", "source": "flatbed"})
        self.assertEqual(resp.status, 200)
        self.assertPdfFiles(resp, [1])

    def test_splitter_extras(self):
        self.assertPdfFiles(scan({"scanner": "fake:splitter"}), [4])
        self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"skipBlankPages": True}}), [3])
        data = self.assertPdfFiles(scan({"scanner": "fake:splitter", "extras": {"splitOnBlank": True}}), [2, 1])
        self.assertEqual(data["message"], "3 pages scanned.")  # n counts the pages of all files
        self.assertPdfFiles(scan({"scanner": "fake:splitter",
                                  "extras": {"splitOnBlank": True, "skipBlankPages": True}}), [2, 1])

    def test_unknown_extra_set_false_is_accepted(self):
        resp = scan({"scanner": "fake:flatbed", "extras": {"splitOnBlank": False}})
        self.assertEqual(resp.status, 200)

    def test_post_without_content_type(self):
        # Helpers must not require a request Content-Type.
        body = b'{"scanner": "fake:flatbed"}'
        resp = raw_request("POST", "/scan", [f"Content-Length: {len(body)}"], body)
        self.assertEqual(resp.status, 200, resp.body[:200])
        self.assertPdfFiles(resp, [1])

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
        self.assertError(request("POST", "/scan", raw_body=b"null", headers={"Content-Type": "application/json"}), 400)
        self.assertError(scan("x"), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "source": 1}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "colorMode": 1}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "format": ["pdf"]}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": True}), 400)
        self.assertError(scan({"scanner": "fake:flatbed", "resolution": 300.0}), 400)
        self.assertError(scan({"scanner": "fake:splitter", "extras": {"splitOnBlank": "yes"}}), 400)

    def test_400_bad_content_length(self):
        for length in ("abc", "-1"):
            resp = raw_request("POST", "/scan", ["Content-Type: application/json", f"Content-Length: {length}"])
            self.assertError(resp, 400)

    def test_400_missing_content_length(self):
        # No Content-Length means an empty body, which isn't a JSON object.
        self.assertError(raw_request("POST", "/scan", ["Content-Type: application/json"]), 400)

    def test_404(self):
        self.assertError(scan({"scanner": "fake:does-not-exist"}), 404)
        self.assertError(request("GET", "/no-such-endpoint"), 404)

    def test_405_wrong_method(self):
        for method, path, allow in [("GET", "/scan", "POST, OPTIONS"), ("POST", "/health", "GET, OPTIONS"),
                                    ("POST", "/scanners", "GET, OPTIONS"), ("GET", "/pair", "POST, OPTIONS"),
                                    ("PUT", "/scan", "POST, OPTIONS"), ("PATCH", "/pair", "POST, OPTIONS"),
                                    ("DELETE", "/health", "GET, OPTIONS")]:
            # 405 comes before the token check, so no token is sent.
            resp = request(method, path, raw_body=b"{}" if method != "GET" else None, auth=None)
            self.assertError(resp, 405)
            self.assertEqual(resp.headers.get("Allow"), allow, f"{method} {path}")

    def test_head_on_known_endpoint_is_405(self):
        resp = request("HEAD", "/health", auth=None)
        self.assertEqual(resp.status, 405)
        self.assertEqual(resp.headers.get("Allow"), "GET, OPTIONS")

    def test_other_methods_on_unknown_path_are_404(self):
        self.assertError(request("DELETE", "/nope", auth=None), 404)
        self.assertError(request("PUT", "/nope", raw_body=b"{}", auth=None), 404)
        self.assertEqual(request("HEAD", "/nope", auth=None).status, 404)

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

    def test_500_empty_feeder(self):
        resp = scan({"scanner": "fake:empty"})
        self.assertError(resp, 500)
        self.assertEqual(resp.json()["message"], "No paper in the feeder.")

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
            busy = scan({"scanner": "fake:flatbed"}, headers={"Origin": "null"})
            assert_error(self, busy, 409)
            assert_cors(self, busy, "null")
            # GET endpoints keep answering while a scan runs.
            self.assertEqual(request("GET", "/health", timeout=1.5).status, 200)
            self.assertEqual(request("GET", "/scanners", timeout=1.5).status, 200)
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
                       "http://192.168.1.5:8766", "http://localhost:0", "http://127.0.0.1:65536"]:
            resp = request("GET", "/health", headers={"Origin": origin})
            assert_error(self, resp, 403)
            self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"))
        resp = scan({"scanner": "fake:flatbed"}, headers={"Origin": "https://evil.example"})
        assert_error(self, resp, 403)
        self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"))

    def test_cors_headers_on_every_response_for_an_allowed_origin(self):
        null = {"Origin": "null"}
        cases = [
            ("200 scan", scan({"scanner": "fake:flatbed"}, headers=null), 200),
            ("400", scan({"scanner": 7}, headers=null), 400),
            ("404 unknown scanner", scan({"scanner": "fake:nope"}, headers=null), 404),
            ("401", request("GET", "/scanners", headers=null, auth=None), 401),
            ("403 wrong pairing code", pair_request({"code": "000001"}, headers=null), 403),
            ("500", scan({"scanner": "fake:empty"}, headers=null), 500),
        ]
        for label, resp, status in cases:
            with self.subTest(label):
                self.assertEqual(resp.status, status)
                assert_cors(self, resp, "null")
        # The 409 case is checked in ErrorTests.test_409_while_another_scan_runs.

    def test_preflight(self):
        resp = request("OPTIONS", "/scan", headers={
            "Origin": "null", "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type",
            "Access-Control-Request-Private-Network": "true"})
        self.assertEqual(resp.status, 204)
        self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), "null")
        self.assertIn("POST", resp.headers.get("Access-Control-Allow-Methods", ""))
        self.assertIn("content-type", resp.headers.get("Access-Control-Allow-Headers", "").lower())
        self.assertEqual(resp.headers.get("Access-Control-Allow-Private-Network"), "true")
        self.assertEqual(resp.headers.get("Access-Control-Allow-Methods"), "GET, POST, OPTIONS")
        self.assertEqual(resp.headers.get("Access-Control-Allow-Headers", "").lower(), "content-type, authorization")
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


class PairingTests(unittest.TestCase):
    def test_health_reports_paired(self):
        self.assertIs(request("GET", "/health", auth=None).json()["paired"], False)
        self.assertIs(request("GET", "/health", auth="Bearer wrong").json()["paired"], False)
        self.assertIs(request("GET", "/health").json()["paired"], True)

    def test_token_is_required(self):
        for auth in (None, "Bearer wrong", "Basic xyz", "Bearer "):
            with self.subTest(auth=auth):
                assert_error(self, request("GET", "/scanners", auth=auth), 401)
                assert_error(self, scan({"scanner": "fake:flatbed"}, auth=auth), 401)

    def test_token_check_comes_before_validation(self):
        assert_error(self, scan({"scanner": 7}, auth=None), 401)
        assert_error(self, scan({"scanner": "fake:nope"}, auth=None), 401)

    def test_origin_check_comes_before_token_check(self):
        evil = {"Origin": "https://evil.example"}
        assert_error(self, request("GET", "/scanners", headers=evil, auth=None), 403)
        assert_error(self, scan({"scanner": "fake:flatbed"}, headers=evil, auth=None), 403)
        assert_error(self, pair_request({"code": FAKE_PAIRING_CODE}, headers=evil), 403)

    def test_pairing_gives_a_new_working_token_each_time(self):
        tokens = []
        for _ in range(2):
            resp = pair_request({"code": FAKE_PAIRING_CODE})
            self.assertEqual(resp.status, 200)
            data = resp.json()
            self.assertIs(data["ok"], True)
            self.assertRegex(data["token"], TOKEN_PATTERN)
            tokens.append(data["token"])
        self.assertNotEqual(tokens[0], tokens[1])
        for token in tokens:
            self.assertEqual(request("GET", "/scanners", auth=f"Bearer {token}").status, 200)
            self.assertIs(request("GET", "/health", auth=f"Bearer {token}").json()["paired"], True)
        # Earlier tokens stay valid.
        self.assertEqual(request("GET", "/scanners").status, 200)

    def test_client_is_optional(self):
        self.assertEqual(pair_request({"code": FAKE_PAIRING_CODE}).status, 200)
        self.assertEqual(pair_request({"code": FAKE_PAIRING_CODE, "client": "x" * 200}).status, 200)

    def test_wrong_code_is_403(self):
        for code in ("000001", "123456", ""):
            resp = pair_request({"code": code})
            assert_error(self, resp, 403)
            self.assertIn("Pair a browser", resp.json()["message"])

    def test_malformed_pairing_body_is_400(self):
        for body in ([], {}, {"code": 123}, {"code": None}, {"code": FAKE_PAIRING_CODE, "client": 5},
                     {"code": FAKE_PAIRING_CODE, "client": "x" * 201}):
            with self.subTest(body=body):
                assert_error(self, pair_request(body), 400)
        assert_error(self, request("POST", "/pair", raw_body=b"{not json", auth=None,
                                   headers={"Content-Type": "application/json"}), 400)


class OcrTests(unittest.TestCase):
    """Background OCR (PROTOCOL.md, "Background OCR"). Runs only against a helper listing fake:ocr."""

    @classmethod
    def setUpClass(cls):
        if "fake:ocr" not in listed_ids():
            raise unittest.SkipTest("helper doesn't list fake:ocr (background OCR is optional)")

    def ocr_scan(self, **extra):
        return scan({"scanner": "fake:ocr", "ocr": True, **extra})

    def wait_for_result(self, job, seconds=10):
        deadline = time.time() + seconds
        while time.time() < deadline:
            resp = request("GET", f"/ocr/{job}")
            if resp.status != 202:
                return resp
            data = resp.json()
            self.assertIs(data["ok"], True)
            self.assertIn(data["state"], ("queued", "running"))
            self.assertIsInstance(data["position"], int)
            self.assertGreaterEqual(data["position"], 0)
            time.sleep(0.3)
        self.fail(f"OCR job {job} still not done after {seconds} s")

    def test_without_ocr_it_scans_like_a_flatbed(self):
        resp = scan({"scanner": "fake:ocr"})
        self.assertEqual(resp.status, 200, resp.body[:200])
        f = resp.json()["files"][0]
        self.assertNotIn("ocrJob", f)
        self.assertIn(b"Flatbed page 1", base64.b64decode(f["data"]))

    def test_job_lifecycle(self):
        resp = self.ocr_scan(ocrLanguages=["deu", "eng"])
        self.assertEqual(resp.status, 200, resp.body[:200])
        data = resp.json()
        self.assertIs(data["ok"], True)
        [f] = data["files"]
        self.assertRegex(f["ocrJob"], TOKEN_PATTERN)
        self.assertNotIn(b"Flatbed page 1", base64.b64decode(f["data"]), "the immediate file is the plain scan")
        first = request("GET", f"/ocr/{f['ocrJob']}")
        self.assertEqual(first.status, 202, "fake:ocr must answer 202 for about 2 s after the scan")
        first_body = first.json()
        self.assertIs(first_body["ok"], True)
        self.assertIn(first_body["state"], ("queued", "running"))
        self.assertIsInstance(first_body["position"], int)
        self.assertGreaterEqual(first_body["position"], 0)
        result = self.wait_for_result(f["ocrJob"])
        self.assertEqual(result.status, 200, result.body[:200])
        body = result.json()
        self.assertIs(body["ok"], True)
        [out] = body["files"]
        self.assertEqual((out["name"], out["pages"]), (f["name"], f["pages"]))
        pdf = base64.b64decode(out["data"], validate=True)
        self.assertTrue(pdf.startswith(b"%PDF-"))
        self.assertIn(b"Flatbed page 1", pdf)
        assert_error(self, request("GET", f"/ocr/{f['ocrJob']}"), 404)

    def test_a_scan_may_start_while_ocr_runs(self):
        job = self.ocr_scan().json()["files"][0]["ocrJob"]
        self.assertEqual(scan({"scanner": "fake:flatbed"}).status, 200)
        self.assertEqual(self.wait_for_result(job).status, 200)

    def test_field_validation(self):
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": "yes"}), 400)
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": True, "ocrLanguages": "deu"}), 400)
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": True, "ocrLanguages": [1]}), 400)
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": "yes", "ocrLanguages": ["xyz"]}), 400)
        assert_error(self, scan({"scanner": "fake:flatbed", "ocr": True}), 422)
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": True, "ocrLanguages": ["xyz"]}), 422)

    def test_ocr_false_is_accepted_anywhere(self):
        resp = scan({"scanner": "fake:flatbed", "ocr": False})
        self.assertEqual(resp.status, 200, resp.body[:200])
        self.assertNotIn("ocrJob", resp.json()["files"][0])
        # Without ocr: true, ocrLanguages is type-checked only.
        self.assertEqual(scan({"scanner": "fake:flatbed", "ocrLanguages": ["xyz"]}).status, 200)

    def test_unknown_job_and_missing_id(self):
        assert_error(self, request("GET", "/ocr/no-such-job-0000000000000"), 404)
        assert_error(self, request("GET", "/ocr/"), 404)
        assert_error(self, request("GET", "/ocr"), 404)

    def test_token_and_method(self):
        assert_error(self, request("GET", "/ocr/no-such-job-0000000000000", auth=None), 401)
        resp = request("POST", "/ocr/no-such-job-0000000000000", raw_body=b"{}", auth=None)
        assert_error(self, resp, 405)
        self.assertEqual(resp.headers.get("Allow"), "GET, OPTIONS")

    def test_cors_on_ocr_answers(self):
        resp = request("GET", "/ocr/no-such-job-0000000000000", headers={"Origin": "null"})
        assert_cors(self, resp, "null")


if __name__ == "__main__":
    unittest.main()
