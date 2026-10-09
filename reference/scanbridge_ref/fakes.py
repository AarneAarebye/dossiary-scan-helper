"""The protocol's fake scanners, request validation, and scan simulation."""

import time
from dataclasses import dataclass

COLOR_MODES = ("color", "gray", "bw")
RESOLUTIONS = (150, 300, 600)


class ScanError(Exception):
    """A protocol error: HTTP status plus a message for a person."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass(frozen=True)
class FakeScanner:
    id: str
    name: str
    sources: tuple
    duplex: bool
    color_modes: tuple
    resolutions: tuple
    extras: tuple
    sheets: tuple
    delay: float = 0.0
    offline: bool = False
    jam_after: int | None = None

    def describe(self) -> dict:
        return {
            "id": self.id, "name": self.name, "sources": list(self.sources), "duplex": self.duplex,
            "colorModes": list(self.color_modes), "resolutions": list(self.resolutions),
            "extras": list(self.extras),
        }


def _scanner(id, name, sources, duplex=False, extras=(), sheets=(), **kw):
    return FakeScanner(id=id, name=name, sources=sources, duplex=duplex, color_modes=COLOR_MODES,
                       resolutions=RESOLUTIONS, extras=extras, sheets=sheets, **kw)


FAKE_SCANNERS = (
    _scanner("fake:flatbed", "Fake Flatbed", ("flatbed",)),
    _scanner("fake:feeder", "Fake Feeder", ("feeder", "flatbed"), duplex=True,
             sheets=("Sheet 1", "Sheet 2", "Sheet 3")),
    _scanner("fake:splitter", "Fake Splitter", ("feeder",), extras=("splitOnBlank", "skipBlankPages"),
             sheets=("Doc A page 1", "Doc A page 2", "", "Doc B page 1")),
    _scanner("fake:jam", "Fake Jamming Feeder", ("feeder",), sheets=("Sheet 1", "Sheet 2", "Sheet 3"),
             jam_after=2),
    _scanner("fake:slow", "Fake Slow Scanner", ("flatbed",), delay=2.0),
    _scanner("fake:offline", "Fake Offline Scanner", ("flatbed",), offline=True),
)


def validate(body):
    """Protocol validation steps 1-5. Returns (scanner, normalized settings)."""
    if not isinstance(body, dict):
        raise ScanError(400, "The request body must be a JSON object.")
    scanner_id = body.get("scanner")
    if not isinstance(scanner_id, str):
        raise ScanError(400, "The request needs a scanner id.")
    scanner = next((s for s in FAKE_SCANNERS if s.id == scanner_id), None)
    if scanner is None:
        raise ScanError(404, f"No scanner with id “{scanner_id}”.")

    for key in ("source", "colorMode", "format"):
        if key in body and not isinstance(body[key], str):
            raise ScanError(400, f"“{key}” must be a string.")
    if "resolution" in body and (not isinstance(body["resolution"], int) or isinstance(body["resolution"], bool)):
        raise ScanError(400, "“resolution” must be a whole number.")
    if "duplex" in body and not isinstance(body["duplex"], bool):
        raise ScanError(400, "“duplex” must be true or false.")
    extras = body.get("extras", {})
    if not isinstance(extras, dict) or not all(isinstance(v, bool) for v in extras.values()):
        raise ScanError(400, "“extras” must map names to true or false.")

    source = body.get("source", scanner.sources[0])
    if source not in scanner.sources:
        raise ScanError(422, f"{scanner.name} has no {source} source.")
    color_mode = body.get("colorMode", scanner.color_modes[0])
    if color_mode not in scanner.color_modes:
        raise ScanError(422, f"{scanner.name} can't scan in {color_mode}.")
    resolution = body.get("resolution", scanner.resolutions[0])
    if resolution not in scanner.resolutions:
        raise ScanError(422, f"{scanner.name} can't scan at {resolution} dpi.")
    fmt = body.get("format", "pdf")
    if fmt != "pdf":
        raise ScanError(422, f"Format “{fmt}” isn't supported; use pdf.")
    duplex = body.get("duplex", False)
    if duplex and not (scanner.duplex and source == "feeder"):
        raise ScanError(422, f"{scanner.name} can't scan both sides from the {source}.")
    for name, on in extras.items():
        if on and name not in scanner.extras:
            raise ScanError(422, f"{scanner.name} doesn't offer “{name}”.")

    return scanner, {"source": source, "duplex": duplex, "colorMode": color_mode,
                     "resolution": resolution, "format": fmt, "extras": dict(extras)}


def _pages_message(count: int) -> str:
    return "1 page scanned." if count == 1 else f"{count} pages scanned."


def simulate(scanner, settings):
    """Run a fake scan. Returns (documents, partial, message)."""
    if scanner.offline:
        raise ScanError(503, f"{scanner.name} isn't reachable. Check that it's switched on and connected.")
    if scanner.delay:
        time.sleep(scanner.delay)

    if settings["source"] == "flatbed":
        pages = ["Flatbed page 1"]
    else:
        sheets = scanner.sheets if scanner.jam_after is None else scanner.sheets[:scanner.jam_after]
        pages = []
        for sheet in sheets:
            pages.append(sheet)
            if settings["duplex"]:
                pages.append(f"{sheet} back" if sheet else "")

    extras = settings["extras"]
    if extras.get("splitOnBlank"):
        documents, current = [], []
        for page in pages:
            if page == "":
                if current:
                    documents.append(current)
                current = []
            else:
                current.append(page)
        if current:
            documents.append(current)
    else:
        if extras.get("skipBlankPages"):
            pages = [p for p in pages if p != ""]
        documents = [pages]

    total = sum(len(d) for d in documents)
    if scanner.jam_after is not None and settings["source"] == "feeder":
        return documents, True, f"Paper jam after {scanner.jam_after} sheets. The pages before it were kept."
    return documents, False, _pages_message(total)
