import unittest

from scanbridge_ref.ocr_jobs import OcrJobs


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class OcrJobsTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.jobs = OcrJobs(delay=2.0, clock=self.clock)

    def test_running_then_done_then_gone(self):
        job = self.jobs.submit(b"%PDF-searchable", "scan.pdf", 1)
        self.assertRegex(job, r"\A[A-Za-z0-9_-]{22,}\Z")
        self.assertEqual(self.jobs.fetch(job), (202, {"ok": True, "state": "running", "position": 0}))
        self.clock.now += 2.0
        status, body = self.jobs.fetch(job)
        self.assertEqual(status, 200)
        self.assertEqual(body["files"][0]["name"], "scan.pdf")
        self.assertEqual(body["files"][0]["pages"], 1)
        self.assertEqual(self.jobs.fetch(job)[0], 404)

    def test_jobs_run_one_at_a_time(self):
        first = self.jobs.submit(b"a", "a.pdf", 1)
        second = self.jobs.submit(b"b", "b.pdf", 1)
        self.assertEqual(self.jobs.fetch(second), (202, {"ok": True, "state": "queued", "position": 1}))
        self.clock.now += 2.0
        self.assertEqual(self.jobs.fetch(first)[0], 200)
        self.assertEqual(self.jobs.fetch(second), (202, {"ok": True, "state": "running", "position": 0}))
        self.clock.now += 2.0
        self.assertEqual(self.jobs.fetch(second)[0], 200)

    def test_unknown_and_expired(self):
        self.assertEqual(self.jobs.fetch("nope")[0], 404)
        job = self.jobs.submit(b"x", "x.pdf", 1)
        self.clock.now += 7 * 24 * 3600 + 3
        self.assertEqual(self.jobs.fetch(job)[0], 404)
