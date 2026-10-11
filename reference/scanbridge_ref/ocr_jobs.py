"""Background OCR jobs (PROTOCOL.md, "Background OCR"), simulated for fake mode.

Jobs run one at a time: each finishes `delay` seconds after the previous one
(or after its own submission, if the queue was empty). Results live in memory
only -- real helpers keep them on disk across restarts.
"""

import base64
import secrets
import threading
import time


class OcrJobs:
    def __init__(self, delay=2.0, clock=time.monotonic, retention=7 * 24 * 3600):
        self._delay = delay
        self._clock = clock
        self._retention = retention
        self._lock = threading.Lock()
        self._jobs = {}  # id -> {"ready_at", "created_at", "name", "pages", "pdf"}

    def submit(self, pdf, name, pages):
        """Queue a job whose result is `pdf`; returns its id."""
        with self._lock:
            now = self._clock()
            last = max((j["ready_at"] for j in self._jobs.values()), default=now)
            job_id = secrets.token_urlsafe(24)
            self._jobs[job_id] = {"ready_at": max(now, last) + self._delay, "created_at": now,
                                  "name": name, "pages": pages, "pdf": pdf}
            return job_id

    def fetch(self, job_id):
        """(status, body) for GET /ocr/<job_id>."""
        with self._lock:
            now = self._clock()
            # Expired jobs are dropped here, on the next fetch -- enough for fake mode.
            for jid in [j for j, job in self._jobs.items() if now - job["created_at"] > self._retention]:
                del self._jobs[jid]
            job = self._jobs.get(job_id)
            if job is None:
                return 404, {"ok": False, "partial": False,
                             "message": "This OCR job is unknown, already fetched, or expired."}
            if now >= job["ready_at"]:
                del self._jobs[job_id]
                return 200, {"ok": True, "files": [{"name": job["name"], "pages": job["pages"],
                                                    "data": base64.b64encode(job["pdf"]).decode("ascii")}]}
            ahead = sum(1 for j in self._jobs.values() if now < j["ready_at"] < job["ready_at"])
            return 202, {"ok": True, "state": "running" if ahead == 0 else "queued", "position": ahead}
