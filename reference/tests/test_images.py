import struct
import unittest
import zlib

from scanbridge_ref.images import EXTENSIONS, make_image, make_jpeg, make_png


class ImageTests(unittest.TestCase):
    def test_the_jpeg_is_a_complete_jpeg(self):
        data = make_jpeg()
        self.assertTrue(data.startswith(b"\xff\xd8\xff"))
        self.assertTrue(data.endswith(b"\xff\xd9"))

    def test_the_png_is_a_complete_png_with_valid_chunks(self):
        data = make_png()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertTrue(data.endswith(b"IEND\xaeB`\x82"))
        position, names = 8, []
        while position < len(data):
            length, name = struct.unpack(">I4s", data[position:position + 8])
            body = data[position + 8:position + 8 + length]
            (crc,) = struct.unpack(">I", data[position + 8 + length:position + 12 + length])
            self.assertEqual(crc, zlib.crc32(name + body) & 0xFFFFFFFF, name)
            names.append(name)
            position += 12 + length
        self.assertEqual(names, [b"IHDR", b"IDAT", b"IEND"])
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual((width, height), (8, 8))

    def test_make_image_picks_by_format_and_refuses_others(self):
        self.assertEqual(make_image("jpeg"), make_jpeg())
        self.assertEqual(make_image("png"), make_png())
        with self.assertRaises(ValueError):
            make_image("tiff")

    def test_extensions(self):
        self.assertEqual(EXTENSIONS, {"jpeg": "jpg", "png": "png"})


if __name__ == "__main__":
    unittest.main()
