"""Tests for the shared login failure limiter."""
import tempfile
from pathlib import Path
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from login_limiter import LoginLimiter


class LoginLimiterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.limiter = LoginLimiter(Path(self.temp.name) / 'attempts.json',
                                    max_failures=5, window_seconds=900)

    def tearDown(self):
        self.temp.cleanup()

    def fail(self, client, now):
        allowed, retry = self.limiter.allow(client, now=now)
        self.assertTrue(allowed)
        self.assertEqual(retry, 0)
        self.limiter.record_failure(client, now=now)

    def test_sixth_attempt_is_blocked_until_window_expires(self):
        for index in range(5):
            self.fail('203.0.113.7', 1000 + index)
        allowed, retry = self.limiter.allow('203.0.113.7', now=1005)
        self.assertFalse(allowed)
        self.assertEqual(retry, 895)
        allowed, _ = self.limiter.allow('203.0.113.7', now=1900)
        self.assertTrue(allowed)

    def test_successful_login_clears_failures(self):
        for index in range(4):
            self.fail('203.0.113.8', 1000 + index)
        self.limiter.clear('203.0.113.8', now=1100)
        for index in range(5):
            self.fail('203.0.113.8', 1100 + index)

    def test_clients_are_independent(self):
        for index in range(5):
            self.fail('203.0.113.9', 1000 + index)
        allowed, retry = self.limiter.allow('203.0.113.10', now=1005)
        self.assertTrue(allowed)
        self.assertEqual(retry, 0)


if __name__ == '__main__':
    unittest.main()
