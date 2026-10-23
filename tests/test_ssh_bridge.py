"""Tests for the SSH bridge URL validation."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ssh_bridge import proxy_options, validate_origin


class OriginValidationTest(unittest.TestCase):
    def test_accepts_https_origins(self):
        self.assertEqual(validate_origin('https://example.com'), 'https://example.com')
        self.assertEqual(validate_origin('https://example.com/'), 'https://example.com')
        self.assertEqual(validate_origin('https://example.com:8443'), 'https://example.com:8443')

    def test_rejects_non_origin_urls(self):
        for value in (
            'http://example.com',
            'https://example.com/path',
            'https://example.com?query=1',
            'https://example.com?',
            'https://example.com#fragment',
            'https://example.com#',
            'https://user:pass@example.com',
            'https://example.com:bad',
            'https://example.com:',
            'https://example.com:/',
            'https://example.com:99999',
            'https://exa mple.com',
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_origin(value)

    def test_proxy_must_be_an_http_origin(self):
        self.assertEqual(proxy_options('http://127.0.0.1:7890', 'example.com')['http_proxy_port'], 7890)
        for value in (
            'http://127.0.0.1',
            'https://127.0.0.1:7890',
            'http://127.0.0.1:7890/path',
            'http://127.0.0.1:7890?query=1',
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    proxy_options(value, 'example.com')


if __name__ == '__main__':
    unittest.main()