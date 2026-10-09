"""A minimal PDF writer: one A4 page per text line, Helvetica. Standard library only."""


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def make_pdf(page_texts: list[str]) -> bytes:
    """Build a PDF with one page per entry of page_texts ("" gives a blank page)."""
    if not page_texts:
        raise ValueError("a PDF needs at least one page")
    count = len(page_texts)
    # Object numbers: 1 catalog, 2 page tree, 3 font, then a page and its content per text.
    page_numbers = [4 + 2 * i for i in range(count)]
    bodies = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        ("<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(f"{n} 0 R" for n in page_numbers), count)).encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for page_number, text in zip(page_numbers, page_texts):
        bodies.append((
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {page_number + 1} 0 R >>"
        ).encode())
        stream = f"BT /F1 36 Tf 72 720 Td ({_escape(text)}) Tj ET".encode("latin-1")
        bodies.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(bodies, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref_at = len(out)
    out += f"xref\n0 {len(bodies) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(bodies) + 1} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n".encode()
    return bytes(out)
