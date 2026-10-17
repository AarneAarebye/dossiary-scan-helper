# dossiary-scan-helper

Lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any
scanner your Mac or Windows PC already supports. Dossiary runs in the
browser, which can't reach a scanner, so this small helper does the
scanning and hands the result to Dossiary over a local connection.

> **Status:** the macOS helper is available (see [docs/install-macos.md](docs/install-macos.md)). The Windows helper comes next. This repo also holds the protocol, the conformance test suite and a reference helper with fake scanners.

## What's here

| Path | What it is |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | The bridge protocol every helper implements. |
| `reference/` | A minimal Python helper with fake scanners, for developing Dossiary and testing the suite. Includes `fake:ocr`, which makes searchable PDFs in the background (`GET /ocr/<job>`). Standard library only. |
| `conformance/` | Tests any running helper over HTTP against `PROTOCOL.md`. |
| `macos/` | The macOS helper: a Swift menu bar app using ImageCaptureCore, which can also use an iX500 on a Raspberry Pi running scanix500-server ("Add network scanner…"). See [macos/README.md](macos/README.md). |

## Run the reference helper

Needs Python 3.11 or newer, nothing else:

    cd reference
    python3 -m scanbridge_ref --port 8766

It listens on `127.0.0.1:8766` and offers seven fake scanners (see
"Fake scanner mode" in `PROTOCOL.md`).

Each browser pairs with a helper once: it sends a code the helper shows
and gets a token for every later request, so other websites can't use
your scanner. The reference helper's code is always `000000`.

### Try it with Dossiary

Dossiary's **📷 Scan** dialog (v1.44.0 and later) finds a helper
on port 8766 by itself:

1. Start the reference helper as above.
2. Open Dossiary and click **📷 Scan**.
3. The dialog shows the helper as "not paired yet". Type `000000` and
   click **Pair**.
4. The seven fake scanners appear. Choose one and click **Scan**: the
   generated PDF lands in the library's Inbox.

"Fake Splitter" offers "split on blank pages", so Dossiary also shows
**📸 Scan Multi** while it runs. Dossiary's
`tests/manual_scan_reference_helper.py` runs this same check
automatically.

## Run the conformance suite

With a helper running (the reference helper, or a native helper started
with `--fake-scanners`):

    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v

The suite pairs automatically with the fake-mode code `000000`.

For the macOS helper, `macos/scripts/run-conformance.sh` builds it, starts it with fake scanners and runs the suite.

The reference helper's own unit tests:

    cd reference && python3 -m unittest discover -s tests -v

## License

MIT
