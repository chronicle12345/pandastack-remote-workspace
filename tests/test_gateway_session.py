"""Test the gateway session behavior without starting its network listener."""
import ast
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent.parent / "src"


def load_auth():
    path = HERE / 'session_auth.py'
    if path.exists():
        spec = importlib.util.spec_from_file_location('session_auth', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    source = ast.parse((HERE / 'browser-gateway.py').read_text(encoding='utf-8'))
    nodes = [n for n in source.body if isinstance(n, (ast.Import, ast.ImportFrom, ast.Assign, ast.FunctionDef))]
    nodes = [n for n in nodes if not (isinstance(n, ast.ImportFrom) and (n.module or '').startswith('websockify'))]
    module = type('GatewayAuth', (), {})()
    os.environ['BROWSER_PASSWORD'] = 'test-only-generated-password'
    exec(compile(ast.Module(body=nodes, type_ignores=[]), '<gateway-auth>', 'exec'), module.__dict__)
    return module


def load_gateway():
    source = ast.parse((HERE / 'browser-gateway.py').read_text(encoding='utf-8'))
    nodes = [n for n in source.body if isinstance(n, (ast.Import, ast.ImportFrom, ast.Assign, ast.FunctionDef))]
    nodes = [n for n in nodes if not (isinstance(n, ast.ImportFrom) and (n.module or '').startswith('websockify'))]
    module = type('Gateway', (), {})()
    os.environ['BROWSER_PASSWORD'] = 'test-only-generated-password'
    exec(compile(ast.Module(body=nodes, type_ignores=[]), '<gateway>', 'exec'), module.__dict__)
    return module


class GatewaySessionTest(unittest.TestCase):
    def setUp(self):
        self.env_patcher = patch.dict(os.environ, {'SESSION_TTL_MINUTES': '180'})
        self.env_patcher.start()
        self.addCleanup(self.env_patcher.stop)
        self.auth = load_auth()
        self.gateway = load_gateway()
        self.assertTrue(callable(getattr(self.auth, 'issue_session', None)),
                        'Gateway must issue timed sessions that survive process restart')
        self.password = 'test-only-generated-password'

    def test_default_session_remains_valid_for_three_hours(self):
        token = self.auth.issue_session(self.password, now=1000)
        self.assertTrue(self.auth.validate_session(token, self.password, now=1001))
        self.assertTrue(self.auth.validate_session(token, self.password, now=11799))
        self.assertFalse(self.auth.validate_session(token, self.password, now=11800))

    def test_gateway_restart_keeps_an_unexpired_session(self):
        token = self.auth.issue_session(self.password, now=1000)
        restarted = load_auth()
        self.assertTrue(restarted.validate_session(token, self.password, now=2000))

    def test_token_tampering_is_rejected(self):
        token = self.auth.issue_session(self.password, now=1000)
        pieces = token.split('.')
        pieces[1] = str(int(pieces[1]) + 10000)
        self.assertFalse(self.auth.validate_session('.'.join(pieces), self.password, now=2000))
        self.assertFalse(self.auth.validate_session(token[:-1], self.password, now=2000))

    def test_password_change_invalidates_old_sessions(self):
        token = self.auth.issue_session(self.password, now=1000)
        self.assertFalse(self.auth.validate_session(token, 'changed-test-password', now=2000))

    def test_csrf_token_is_bound_to_session(self):
        token = self.auth.issue_session(self.password, now=1000)
        csrf = self.auth.session_csrf(token, self.password, now=1000)
        self.assertTrue(csrf)
        self.assertEqual(csrf, self.auth.session_csrf(token, self.password, now=2000))
        self.assertIsNone(self.auth.session_csrf(token, 'changed-test-password', now=2000))
        self.assertIsNone(self.auth.session_csrf('garbage', self.password, now=2000))

    def test_session_ttl_is_configurable_in_minutes(self):
        with patch.dict(os.environ, {'SESSION_TTL_MINUTES': '5'}):
            auth = load_auth()
        self.assertEqual(auth.SESSION_TTL_MINUTES, 5)
        token = auth.issue_session(self.password, now=1000)
        self.assertTrue(auth.validate_session(token, self.password, now=1299))
        self.assertFalse(auth.validate_session(token, self.password, now=1300))
        self.assertEqual(auth.session_expiry(token, self.password, now=1000), 1300)

    def test_invalid_session_ttl_is_rejected(self):
        for value in ('0', '10081', 'not-a-number'):
            with self.subTest(value=value):
                with patch.dict(os.environ, {'SESSION_TTL_MINUTES': value}):
                    with self.assertRaises(ValueError):
                        load_auth()

    def test_invalid_and_future_tokens_are_rejected(self):
        for token in ('', 'garbage', 'x.y.z', None):
            self.assertFalse(self.auth.validate_session(token, self.password, now=2000))
        future = self.auth.issue_session(self.password, now=3000)
        self.assertFalse(self.auth.validate_session(future, self.password, now=2000))

    def test_app_paths_are_protected(self):
        self.assertTrue(self.gateway.protected_path('/app'))
        self.assertTrue(self.gateway.protected_path('/app/index.html'))
        self.assertTrue(self.gateway.protected_path('/desktop.html'))
        self.assertTrue(self.gateway.protected_path('/app%2f..%2fdesktop.html'))
        self.assertFalse(self.gateway.protected_path('/vnc.html/extra'))

    def test_invalid_forwarded_address_falls_back_to_socket_address(self):
        headers = {'CF-Connecting-IP': 'not-an-ip', 'X-Forwarded-For': '203.0.113.5'}
        self.assertEqual(self.gateway.client_address(headers, '127.0.0.1'), '203.0.113.5')
        self.assertEqual(self.gateway.client_address({'CF-Connecting-IP': 'bad'}, '127.0.0.1'),
                         '127.0.0.1')


if __name__ == '__main__':
    unittest.main()
