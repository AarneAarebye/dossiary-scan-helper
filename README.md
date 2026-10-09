# dossiary-scan-helper

Lets [Dossiary](https://github.com/AarneAarebye/Dossiary) scan with any
scanner your Mac or Windows PC already supports. Dossiary runs in the
browser, which can't reach a scanner, so this small helper does the
scanning and hands the result to Dossiary over a local connection.

> **Status:** early development. This repo currently holds the protocol,
> the conformance test suite and a reference helper with fake scanners.
> The macOS and Windows helpers come next.

## What's here

| Path | What it is |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | The bridge protocol every helper implements. |
| `reference/` | A minimal Python helper with fake scanners, for developing Dossiary and testing the suite. Standard library only. |
| `conformance/` | Tests any running helper over HTTP against `PROTOCOL.md`. |

## Run the reference helper

Needs Python 3.11 or newer, nothing else:

    cd reference
    python3 -m scanbridge_ref --port 8766

It listens on `127.0.0.1:8766` and offers seven fake scanners (see
"Fake scanner mode" in `PROTOCOL.md`).

Each browser pairs with a helper once: it sends a code the helper shows
and gets a token for every later request, so other websites can't use
your scanner. The reference helper's code is always `000000`.

## Run the conformance suite

With a helper running (the reference helper, or a native helper started
with `--fake-scanners`):

    SCAN_HELPER_URL=http://127.0.0.1:8766 python3 -m unittest discover -s conformance -v

The suite pairs automatically with the fake-mode code `000000`.

The reference helper's own unit tests:

    cd reference && python3 -m unittest discover -s tests -v

## License

MIT
