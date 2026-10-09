import re
import unittest

from scanbridge_ref.pdf import make_pdf


class MakePdfTests(unittest.TestCase):
    def test_header_and_trailer(self):
        pdf = make_pdf(["Hello"])
        self.assertTrue(pdf.startswith(b"%PDF-1.4\n"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))

    def test_one_page_object_per_text(self):
        pdf = make_pdf(["One", "Two", ""])
        pages = re.findall(rb"/Type /Page(?!s)", pdf)
        self.assertEqual(len(pages), 3)
        self.assertIn(b"/Count 3", pdf)

    def test_text_is_in_the_content(self):
        pdf = make_pdf(["Sheet 1 (front)"])
        self.assertIn(rb"(Sheet 1 \(front\)) Tj", pdf)

    def test_xref_offsets_point_at_objects(self):
        pdf = make_pdf(["A", "B"])
        startxref = int(re.search(rb"startxref\n(\d+)", pdf).group(1))
        self.assertTrue(pdf[startxref:].startswith(b"xref\n"))
        offsets = [int(m) for m in re.findall(rb"^(\d{10}) 00000 n $", pdf, re.M)]
        for number, offset in enumerate(offsets, start=1):
            self.assertTrue(pdf[offset:].startswith(f"{number} 0 obj\n".encode()), number)

    def test_empty_list_is_refused(self):
        with self.assertRaises(ValueError):
            make_pdf([])


if __name__ == "__main__":
    unittest.main()
