# OCR jobs: protocol, conformance suite, reference helper — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Protocol version 2 gains optional background OCR — a scanner may offer `ocr`, `POST /scan` may ask for it and then answers at once with an `ocrJob` per file, and `GET /ocr/<job>` delivers the searchable PDF later — documented in `PROTOCOL.md`, checked by the conformance suite, and implemented by the reference helper's new `fake:ocr` scanner.

**Architecture:** Step 1 of `/Users/aarneaarebye/Projects/Paperless/Dossiary/docs/superpowers/specs/2026-10-11-background-scan-ocr-design.md` (read its section 2). The additions are optional, so existing helpers stay conformant: the suite's OCR tests run only when the helper lists `fake:ocr`, and are skipped otherwise (the macOS helper and scanix500 get `fake:ocr` in their own later steps). The reference helper keeps OCR jobs in memory with an injectable clock.

**Tech Stack:** Python 3.11 standard library only (reference helper and conformance suite), `unittest`.

## Global Constraints

- Repo: `/Users/aarneaarebye/Projects/Paperless/dossiary-scan-helper`. Reference helper unit tests: `cd reference && python3 -m unittest discover -s tests -v`. Conformance: start `cd reference && python3 -m scanbridge_ref --port 8799 &`, then from the repo root `SCAN_HELPER_URL=http://127.0.0.1:8799 python3 -m unittest discover -s conformance -v`, then kill that helper. Never bind 8765 or 8766 (live helpers may run there).
- Standard library only; no new dependencies.
- All additions are optional and backwards compatible: a helper without OCR leaves them out; every existing conformance test keeps passing unchanged against a helper without `fake:ocr` (today's macOS helper fake mode, scanix500's `scanix500-bridge --fake-scanners`).
- Scanner entry field, exactly: `"ocr": {"languages": [...]}` with Tesseract-style codes (`deu`, `eng`, `fra`, `spa`, `chi_sim`, `chi_tra`); present only when the helper can make a searchable PDF for that scanner.
- `POST /scan` fields: `"ocr"` (boolean) and `"ocrLanguages"` (array of strings). `ocr` not a boolean, or `ocrLanguages` not an array of strings → 400 (validation step 4, with the other type checks); `ocr: true` for a scanner without `ocr`, or a language not in its `languages` → 422 (step 5). `ocrLanguages` without `ocr: true` is checked for type only.
- With `ocr: true`, every file entry of the scan response gains `"ocrJob"`: URL-safe characters, at least 22 characters (`TOKEN_PATTERN` in the suite), unguessable (`secrets.token_urlsafe(24)`). The file itself is the plain scan.
- `GET /ocr/<job>`: token required (401 before anything else about the job); `202 {"ok": true, "state": "queued"|"running", "position": n}` (`position` = jobs ahead of it, 0 when running); `200 {"ok": true, "files": [{"name", "pages", "data"}]}` with the same `name` and `pages` as the plain file; `404` for an unknown, already fetched or expired job; `500` error body when OCR failed. Fetching a `200` deletes the result. Any method other than GET/OPTIONS → 405 `Allow: GET, OPTIONS`. `/ocr` and `/ocr/` (no id) → 404.
- Retention: results kept until fetched, at most 7 days; real helpers keep them on disk across restarts (the reference helper, fake mode only, keeps them in memory).
- Jobs run one at a time per helper; a new scan may start while jobs run; only a second simultaneous scan gets 409.
- `fake:ocr`: name `Fake OCR Scanner`, sources `["flatbed"]`, duplex false, colour modes and resolutions as every fake, extras `[]`, `ocr: {"languages": ["deu", "eng"]}`. Without `ocr: true` it scans like any flatbed (`Flatbed page 1`, no `ocrJob`). With `ocr: true` its file is a one-page PDF *without* the text `Flatbed page 1`, and its job answers 202 for 2 seconds after the scan, then 200 with a one-page PDF whose content has `Flatbed page 1`.
- Messages are plain English for a person; error bodies are `{"ok": false, "partial": false, "message": "..."}`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AnMx4wtUcaKMWsQm9eXUTo
  ```

---

### Task 1: `PROTOCOL.md` and the conformance suite

**Files:**
- Modify: `PROTOCOL.md`
- Modify: `conformance/test_conformance.py`

**Interfaces:**
- Produces: the suite's `OcrTests` class (skipped unless `fake:ocr` is listed) and the relaxed fake-table check, which Task 2's reference helper must satisfy.

- [ ] **Step 1: Update `PROTOCOL.md`**

Make these edits (keep the document's existing style: short sentences, tables, plain English):

1. In "Endpoints and methods", add a row to the table:

   ```
   | `/ocr/<job>` | `GET` | required |
   ```

   and extend the 405 sentence: `Allow: GET, OPTIONS` also for `/ocr/<job>`. Add: "`/ocr` and `/ocr/` without a job id are unknown paths (404)." In the check-order list, step 3 becomes "`/scanners`, `/scan` and `/ocr/<job>` only: no valid token → **401**".

2. In "`GET /scanners`", add a row to the field table:

   ```
   | `ocr` | object, optional | Present only when the helper can make a searchable PDF of this scanner's pages (see Background OCR). `languages`: the OCR languages it offers, as Tesseract-style codes (`deu`, `eng`, `fra`, `spa`, `chi_sim`, `chi_tra`). |
   ```

3. In "`POST /scan`", extend the example body with `"ocr": true, "ocrLanguages": ["deu", "eng"]` and add after "Only `scanner` is required…": "`ocr` (default false) asks for a searchable PDF in the background; `ocrLanguages` (default: the helper's choice) picks its languages."
   In "Request validation" step 4 add: "`ocr` not a boolean; `ocrLanguages` not an array of strings". In step 5 add: "`ocr: true` for a scanner without `ocr`; an `ocrLanguages` entry not in the scanner's `ocr.languages` (checked only with `ocr: true`)".
   In "Response" add a bullet: "`ocrJob`: present on every file when the request had `ocr: true` — the file is then the plain scan, and `GET /ocr/<job>` delivers its searchable version (see Background OCR)."

4. Add a new section after "Response" (before "Errors"):

   ```markdown
   ## Background OCR

   A scan with `ocr: true` answers as soon as the plain PDFs exist; the helper
   then makes each file searchable in the background, one job at a time. The
   client fetches the result:

   ### `GET /ocr/<job>`

   Needs the token, like `/scan`.

   | Answer | Meaning |
   |---|---|
   | **202** `{"ok": true, "state": "queued", "position": 2}` | Not done yet. `state` is `queued` or `running`; `position` counts the jobs ahead of it (0 while it runs). |
   | **200** `{"ok": true, "files": [{"name": "…", "pages": 3, "data": "<base64>"}]}` | The searchable PDF, with the same `name` and `pages` as the plain file. |
   | **404** | Unknown job, already fetched, or expired. |
   | **500** | OCR failed; the message says why. |

   - Fetching a **200** deletes the result: a second fetch answers 404.
   - A helper keeps a finished result until it's fetched, at most 7 days,
     and keeps it across its own restarts (on disk).
   - A new scan may start while OCR jobs run; only a second simultaneous scan
     gets 409.
   - Clients poll every few seconds, without a timeout of their own beyond
     the 7 days.
   ```

5. In "Errors", the table stays (202 is not an error); add to the 404 row: "unknown or fetched OCR job".

6. In "Fake scanner mode": add a row to the table

   ```
   | `fake:ocr` | Fake OCR Scanner | flatbed | false | color, gray, bw | 150, 300, 600 | — |
   ```

   with the note under the table: "`fake:ocr` also offers `ocr: {"languages": ["deu", "eng"]}`. It's optional for now: a helper may list only the first seven." Add to "What a scan returns":

   ```markdown
   - **`fake:ocr`**: without `ocr: true`, like any flatbed. With `ocr: true`:
     one page *without* the text `Flatbed page 1`, and an `ocrJob` that answers
     202 for 2 seconds after the scan, then 200 with one page whose content has
     `Flatbed page 1`.
   ```

   Change "replaces the real scanners with exactly these seven" to "with exactly these seven, plus `fake:ocr` when the helper does background OCR".

- [ ] **Step 2: Relax the fake-table checks**

In `conformance/test_conformance.py`, after `FAKE_IDS = list(FAKE_SCANNERS)` add:

```python
# Optional until every helper does background OCR (PROTOCOL.md, "Fake scanner mode").
OPTIONAL_FAKES = {
    "fake:ocr": {"name": "Fake OCR Scanner", "sources": ["flatbed"], "duplex": False, "extras": [],
                 "ocr": {"languages": ["deu", "eng"]}},
}


def listed_ids():
    return {s["id"] for s in request("GET", "/scanners").json()["scanners"]}
```

Change `test_lists_the_seven_fake_scanners_with_all_fields`'s id assertion to:

```python
        ids = sorted(s["id"] for s in scanners)
        optional = sorted(i for i in ids if i in OPTIONAL_FAKES)
        self.assertEqual(ids, sorted(FAKE_IDS + optional))
```

and add inside its loop:

```python
            if "ocr" in s:
                self.assertIsInstance(s["ocr"]["languages"], list)
                self.assertTrue(s["ocr"]["languages"] and all(isinstance(l, str) for l in s["ocr"]["languages"]))
```

Change `test_fake_scanner_table` to:

```python
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
```

(The seven fakes have no `ocr` key, so the exact comparison also checks that no other fake claims OCR.)

- [ ] **Step 3: Add the OCR tests**

Append to `conformance/test_conformance.py`:

```python
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
        self.assertEqual(first.status, 202, "the result takes about 2 seconds")
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
        assert_error(self, scan({"scanner": "fake:flatbed", "ocr": True}), 422)
        assert_error(self, scan({"scanner": "fake:ocr", "ocr": True, "ocrLanguages": ["xyz"]}), 422)

    def test_ocr_false_is_accepted_anywhere(self):
        resp = scan({"scanner": "fake:flatbed", "ocr": False})
        self.assertEqual(resp.status, 200, resp.body[:200])
        self.assertNotIn("ocrJob", resp.json()["files"][0])

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
```

- [ ] **Step 4: Run against today's reference helper — OCR tests skip, nothing else changes**

Run (from the repo root):

```bash
cd reference && python3 -m scanbridge_ref --port 8799 & PID=$!; sleep 1
SCAN_HELPER_URL=http://127.0.0.1:8799 python3 -m unittest discover -s conformance -v 2>&1 | tail -4
kill $PID
```

Expected: `OK` with skips — the 43 existing tests pass and `OcrTests` is reported as skipped ("helper doesn't list fake:ocr"); no failures or errors.

- [ ] **Step 5: Commit**

```bash
git add PROTOCOL.md conformance/test_conformance.py
git commit -m "Protocol: optional background OCR (ocr field, ocrJob, GET /ocr/<job>) and its conformance tests"
```

---

### Task 2: Reference helper — `fake:ocr` and OCR jobs

**Files:**
- Create: `reference/scanbridge_ref/ocr_jobs.py`, `reference/tests/test_ocr_jobs.py`
- Modify: `reference/scanbridge_ref/fakes.py`, `reference/scanbridge_ref/server.py`, `reference/tests/test_fakes.py`, `reference/tests/test_server.py`, `README.md` (root: one line in the reference helper's description)

**Interfaces:**
- Consumes: Task 1's `PROTOCOL.md` contract and conformance tests.
- Produces: `FakeScanner.ocr_languages: tuple` (empty = no OCR); `validate(body)` settings gain `"ocr": bool` and `"ocrLanguages": list[str]`; `OcrJobs(delay=2.0, clock=time.monotonic, retention=7*24*3600)` with `submit(pdf_bytes: bytes, name: str, pages: int) -> str` and `fetch(job_id: str) -> tuple[int, dict]`.

- [ ] **Step 1: Write the failing tests**

`reference/tests/test_ocr_jobs.py`:

```python
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
```

Add to `reference/tests/test_fakes.py`:

```python
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
```

The first existing test, `test_seven_scanners_in_protocol_order`, becomes:

```python
    def test_seven_scanners_in_protocol_order(self):
        self.assertEqual([s.id for s in FAKE_SCANNERS][:7],
                         ["fake:flatbed", "fake:feeder", "fake:splitter", "fake:jam", "fake:slow", "fake:offline",
                          "fake:empty"])
```

Add to `reference/tests/test_server.py` (it has no server tests yet; this starts one on a free port):

```python
import json
import threading
import urllib.error
import urllib.request

from scanbridge_ref import server
from scanbridge_ref.ocr_jobs import OcrJobs


class OcrEndpointTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        server.OCR_JOBS = OcrJobs(delay=2.0, clock=lambda: self.now)
        self.httpd = server.make_server("127.0.0.1", 0)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.token = self.call("POST", "/pair", {"code": "000000"}, token=None)[1]["token"]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

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
```

(Move the new imports to the top of the file with the existing one.)

- [ ] **Step 2: Run them to see them fail**

Run: `cd reference && python3 -m unittest discover -s tests -v 2>&1 | tail -5`
Expected: errors (`ModuleNotFoundError: scanbridge_ref.ocr_jobs`, no `fake:ocr`).

- [ ] **Step 3: Implement**

`reference/scanbridge_ref/ocr_jobs.py`:

```python
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
```

`reference/scanbridge_ref/fakes.py`:
- `FakeScanner` gains `ocr_languages: tuple = ()` (after `empty`).
- `describe()` adds `"ocr": {"languages": list(self.ocr_languages)}` only when `self.ocr_languages` is non-empty.
- Append to `FAKE_SCANNERS`: `_scanner("fake:ocr", "Fake OCR Scanner", ("flatbed",), ocr_languages=("deu", "eng"))`.
- In `validate`, with the other type checks (before the 422 checks):

```python
    if "ocr" in body and not isinstance(body["ocr"], bool):
        raise ScanError(400, "“ocr” must be true or false.")
    languages = body.get("ocrLanguages", [])
    if not isinstance(languages, list) or not all(isinstance(lang, str) for lang in languages):
        raise ScanError(400, "“ocrLanguages” must be a list of language codes.")
```

  and after the extras 422 loop:

```python
    ocr = body.get("ocr", False)
    if ocr and not scanner.ocr_languages:
        raise ScanError(422, f"{scanner.name} can't make a searchable PDF.")
    if ocr:
        for lang in languages:
            if lang not in scanner.ocr_languages:
                raise ScanError(422, f"{scanner.name} has no OCR language “{lang}”.")
```

  and add `"ocr": ocr, "ocrLanguages": list(languages)` to the returned settings dict.

`reference/scanbridge_ref/server.py`:
- `from .ocr_jobs import OcrJobs` and a module-level `OCR_JOBS = OcrJobs()`.
- Routing: before the `ENDPOINTS` lookup in `_dispatch`, map a path `"/ocr/<id>"` with a non-empty id (no further `/`) to the endpoint key `"/ocr/<job>"` with method `"GET"`:

```python
        path = urlsplit(self.path).path
        job_id = None
        if path.startswith("/ocr/") and len(path) > len("/ocr/") and "/" not in path[len("/ocr/"):]:
            job_id, path = path[len("/ocr/"):], "/ocr/<job>"
        method = ENDPOINTS.get(path)
```

  with `ENDPOINTS` gaining `"/ocr/<job>": "GET"` and `NEEDS_TOKEN` gaining `"/ocr/<job>"`. The key can't be requested literally (a real path `/ocr/<job>` maps to job id `<job>`), and `/ocr` or `/ocr/` aren't mapped, so they stay unknown paths (404). In the endpoint branch add:

```python
            elif path == "/ocr/<job>":
                status, body = OCR_JOBS.fetch(job_id)
                self._send_json(status, body)
```

- In `_scan`, for each document: if `settings["ocr"]`, the immediate file is `make_pdf([""] * len(pages))` (the page without its text) plus `"ocrJob": OCR_JOBS.submit(make_pdf(pages), name, len(pages))`; otherwise unchanged. Reference `OCR_JOBS` through the module (`server.OCR_JOBS` in tests can replace it), i.e. read the global at call time.

Root `README.md`: in the reference helper's description add "and `fake:ocr`, which makes searchable PDFs in the background (`GET /ocr/<job>`)".

- [ ] **Step 4: Run the unit tests and the full conformance suite**

Run: `cd reference && python3 -m unittest discover -s tests -v 2>&1 | tail -3` → all pass.
Run the conformance suite against the reference helper as in Task 1 Step 4 → `Ran 51 tests` … `OK` (43 existing + 8 OCR tests, none skipped).

- [ ] **Step 5: Commit**

```bash
git add reference README.md
git commit -m "Reference helper: fake:ocr and background OCR jobs (GET /ocr/<job>)"
```
