import unittest

from scanbridge_ref.server import origin_allowed


class OriginAllowedTests(unittest.TestCase):
    def test_allowed(self):
        for origin in [None, "null", "http://localhost", "http://localhost:5173", "http://127.0.0.1:8833"]:
            self.assertTrue(origin_allowed(origin), origin)

    def test_refused(self):
        for origin in ["https://evil.example", "http://localhost.evil.example", "https://localhost",
                       "http://192.168.1.5:8766", "http://localhost/path", "file://"]:
            self.assertFalse(origin_allowed(origin), origin)


if __name__ == "__main__":
    unittest.main()
