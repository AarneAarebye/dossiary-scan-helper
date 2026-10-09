import unittest

from scanbridge_ref.__main__ import host_allowed


class HostAllowedTests(unittest.TestCase):
    def test_loopback_only(self):
        self.assertTrue(host_allowed("127.0.0.1"))
        self.assertTrue(host_allowed("localhost"))
        for host in ("0.0.0.0", "", "::", "192.168.1.5", "example.com", "127.0.0.2"):
            self.assertFalse(host_allowed(host), host)


if __name__ == "__main__":
    unittest.main()
