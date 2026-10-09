import re
import unittest

from scanbridge_ref.fakes import ScanError
from scanbridge_ref.pairing import FAKE_PAIRING_CODE, bearer_token, pair, token_valid, validate_pair_body


class PairTests(unittest.TestCase):
    def test_fake_code(self):
        self.assertEqual(FAKE_PAIRING_CODE, "000000")

    def test_each_pairing_gives_a_new_valid_token(self):
        first, second = pair("000000"), pair("000000")
        self.assertNotEqual(first, second)
        for token in (first, second):
            self.assertRegex(token, r"\A[A-Za-z0-9_-]{22,}\Z")
            self.assertTrue(token_valid(token))

    def test_wrong_code_is_403(self):
        for code in ("000001", "", "00000", "0000000"):
            with self.assertRaises(ScanError) as ctx:
                pair(code)
            self.assertEqual(ctx.exception.status, 403)
            self.assertIn("Pair a browser", ctx.exception.message)

    def test_unknown_tokens(self):
        self.assertFalse(token_valid(None))
        self.assertFalse(token_valid("wrong"))
        self.assertFalse(token_valid(""))


class BearerTokenTests(unittest.TestCase):
    def test_parsing(self):
        self.assertEqual(bearer_token("Bearer abc"), "abc")
        for header in (None, "", "Bearer ", "Basic xyz", "bearer abc", "Bearerabc"):
            self.assertIsNone(bearer_token(header), header)


class ValidatePairBodyTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(validate_pair_body({"code": "123456"}), "123456")
        self.assertEqual(validate_pair_body({"code": "123456", "client": "Chrome on Mac"}), "123456")
        self.assertEqual(validate_pair_body({"code": "1", "client": "x" * 200}), "1")

    def test_malformed_is_400(self):
        for body in ([], None, "x", {}, {"code": 123}, {"code": None}, {"code": "000000", "client": 5},
                     {"code": "000000", "client": None}, {"code": "000000", "client": "x" * 201}):
            with self.assertRaises(ScanError) as ctx:
                validate_pair_body(body)
            self.assertEqual(ctx.exception.status, 400, body)


if __name__ == "__main__":
    unittest.main()
