import json
import threading
import unittest
import urllib.error
import urllib.request

from scanbridge_ref import server
from scanbridge_ref.ocr_jobs import OcrJobs
from scanbridge_ref.server import origin_allowed


class OriginAllowedTests(unittest.TestCase):
    def test_allowed(self):
        for origin in [None, "null", "http://localhost", "http://localhost:5173", "http://127.0.0.1:8833",
                       "http://localhost:1", "http://127.0.0.1:65535"]:
            self.assertTrue(origin_allowed(origin), origin)

    def test_refused(self):
        for origin in ["https://evil.example", "http://localhost.evil.example", "https://localhost",
                       "http://192.168.1.5:8766", "http://localhost/path", "file://", "http://localhost:abc",
                       "http://localhost:99999", "http://localhost:65536", "http://localhost:0",
                       "http://127.0.0.1:00000", "http://localhost:", "http://user@localhost",
                       "http://user:p@127.0.0.1:1", "http://localhost?x=1", "http://localhost#f",
                       "HTTP://LOCALHOST", "http://[::1", "http://localhost:5173/"]:
            self.assertFalse(origin_allowed(origin), origin)



class OcrEndpointTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.saved_jobs = server.OCR_JOBS
        server.OCR_JOBS = OcrJobs(delay=2.0, clock=lambda: self.now)
        self.httpd = server.make_server("127.0.0.1", 0)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.token = self.call("POST", "/pair", {"code": "000000"}, token=None)[1]["token"]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        server.OCR_JOBS = self.saved_jobs

    def call(self, method, path, body=None, token="use"):
        headers = {"Content-Type": "application/json"}
        if token == "use":
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as err:
            with err:
                return err.code, json.loads(err.read())

    def test_ocr_scan_answers_with_a_job_and_the_job_delivers(self):
        status, body = self.call("POST", "/scan", {"scanner": "fake:ocr", "ocr": True})
        self.assertEqual(status, 200)
        job = body["files"][0]["ocrJob"]
        self.assertEqual(self.call("GET", f"/ocr/{job}")[0], 202)
        self.now += 2.0
        status, body = self.call("GET", f"/ocr/{job}")
        self.assertEqual(status, 200)
        self.assertEqual(body["files"][0]["pages"], 1)
        self.assertEqual(self.call("GET", f"/ocr/{job}")[0], 404)

    def test_ocr_paths_without_an_id_are_unknown(self):
        self.assertEqual(self.call("GET", "/ocr/")[0], 404)
        self.assertEqual(self.call("GET", "/ocr")[0], 404)


if __name__ == "__main__":
    unittest.main()
