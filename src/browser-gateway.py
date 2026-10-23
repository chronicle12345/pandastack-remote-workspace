import hmac
import ipaddress
import json
import os
import posixpath
import socket
import subprocess
from http.cookies import SimpleCookie
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from websockify.websocketproxy import WebSocketProxy, ProxyRequestHandler
from websockify.auth_plugins import AuthenticationError

from session_auth import (SESSION_SECONDS, SESSION_TTL_MINUTES, issue_session, session_csrf,
                          session_expiry, validate_session)
from login_limiter import LoginLimiter

PASSWORD = os.environ['BROWSER_PASSWORD']
COOKIE_NAME = '__Host-browser_session'
NOVNC_DIR = Path('/usr/share/novnc')
DESKTOP_ACTIONS = {'terminal', 'browser', 'windows'}
PROTECTED_PAGES = {'/desktop.html', '/desktop.js', '/vnc.html', '/vnc_lite.html'}
LOGIN_LIMITER = LoginLimiter(Path('/run/browser-login-attempts.json'),
                              max_failures=5, window_seconds=900)
GLOBAL_LOGIN_LIMITER = LoginLimiter(Path('/run/browser-login-global.json'),
                                    max_failures=100, window_seconds=900)
DESKTOP_ENVIRONMENT = {
    'DISPLAY': ':1',
    'HOME': '/root',
    'USER': 'root',
    'LOGNAME': 'root',
    'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    'BROWSER': '/usr/local/bin/pds-open-browser',
}

LOGIN_HTML = '''<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>浏览器登录</title>
<body style="font:16px sans-serif;max-width:360px;margin:15vh auto;padding:24px">
<h2>远端浏览器</h2>
<form method="post" action="/login">
<label>用户名<input name="username" value="browser" autocomplete="username" required style="display:block;width:100%;margin:12px 0;padding:10px;box-sizing:border-box"></label>
<label>访问密码<input name="password" type="password" autocomplete="current-password" required style="display:block;width:100%;margin:12px 0;padding:10px;box-sizing:border-box"></label>
<button style="padding:10px 24px">登录</button>
</form>
</body>
</html>'''


def client_address(headers, fallback):
    for name in ('CF-Connecting-IP', 'X-Forwarded-For'):
        value = headers.get(name, '')
        if value:
            candidate = value.split(',', 1)[0].strip()
            try:
                return str(ipaddress.ip_address(candidate))
            except ValueError:
                continue
    return str(fallback)[:64]


def protected_path(path):
    normalized = posixpath.normpath(unquote(path))
    return (normalized in PROTECTED_PAGES or normalized == '/app'
            or normalized.startswith('/app/'))


def cookie_token(headers):
    cookie = SimpleCookie()
    try:
        cookie.load(headers.get('Cookie', ''))
    except Exception:
        return None
    morsel = cookie.get(COOKIE_NAME)
    return morsel.value if morsel else None


def authenticated(headers):
    return validate_session(cookie_token(headers), PASSWORD)


def csrf_valid(headers):
    expected = session_csrf(cookie_token(headers), PASSWORD)
    supplied = headers.get('X-CSRF-Token', '').strip()
    return bool(expected and supplied and len(supplied) <= 128
                and hmac.compare_digest(supplied, expected))


def run_desktop_action(action):
    if action not in DESKTOP_ACTIONS:
        raise ValueError('Unknown desktop action')
    environment = dict(DESKTOP_ENVIRONMENT)
    for name in ('LANG', 'LC_ALL', 'TZ'):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    command = ['/usr/local/bin/pds-desktop-actions', action]
    result = subprocess.run(command, capture_output=True, text=True, timeout=8,
                            env=environment)
    detail = (result.stdout + result.stderr).strip()[:500]
    return result.returncode == 0, detail


class CookieAuth:
    def authenticate(self, headers, target_host, target_port):
        if not authenticated(headers):
            raise AuthenticationError(
                response_code=303,
                response_headers={'Location': '/login', 'Cache-Control': 'no-store'},
            )


class LoginHandler(ProxyRequestHandler):
    def respond(self, status, body=b'', headers=None, content_type='text/html; charset=utf-8'):
        self.send_response(status)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Frame-Options', 'SAMEORIGIN')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
        self.send_header('X-Robots-Tag', 'noindex, nofollow')
        self.send_header('Strict-Transport-Security', 'max-age=31536000')
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def redirect(self, location):
        self.respond(303, headers={'Location': location})

    def serve_file(self, path, content_type):
        file = Path(path)
        if not file.is_file():
            self.respond(404)
            return
        self.respond(200, file.read_bytes(), content_type=content_type)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/login':
            if authenticated(self.headers):
                self.redirect('/desktop.html')
                return
            self.respond(200, LOGIN_HTML.encode('utf-8'))
            return
        if path in ('', '/', '/index.html'):
            self.redirect('/desktop.html' if authenticated(self.headers) else '/login')
            return
        if protected_path(path) and not authenticated(self.headers):
            self.redirect('/login')
            return
        if path == '/session':
            token = cookie_token(self.headers)
            expiry = session_expiry(token, PASSWORD)
            if expiry is None:
                self.redirect('/login')
                return
            csrf = session_csrf(token, PASSWORD)
            self.respond(200, json.dumps({'expires_at': expiry, 'ttl_minutes': SESSION_TTL_MINUTES, 'csrf': csrf}).encode('utf-8'),
                         content_type='application/json')
            return
        if path == '/status':
            if not authenticated(self.headers):
                self.redirect('/login')
                return
            status_file = Path('/run/workspace-sync.json')
            self.respond(200, status_file.read_bytes() if status_file.exists() else b'{"state":"starting"}',
                         content_type='application/json')
            return
        if path == '/desktop.html':
            self.serve_file(NOVNC_DIR / 'desktop.html', 'text/html; charset=utf-8')
            return
        if path == '/desktop.js':
            self.serve_file(NOVNC_DIR / 'desktop.js', 'application/javascript; charset=utf-8')
            return
        super().do_GET()

    def new_websocket_client(self):
        if urlsplit(self.path).path == '/ssh':
            target = socket.create_connection(('127.0.0.1', 22), timeout=10)
            target.settimeout(None)
            try:
                self.do_proxy(target)
            finally:
                target.close()
        else:
            super().new_websocket_client()

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == '/login':
            self.login()
            return
        if path == '/logout':
            if not authenticated(self.headers):
                self.redirect('/login')
                return
            if not csrf_valid(self.headers):
                self.respond(403, '{"ok":false,"detail":"请刷新页面后重试"}'.encode('utf-8'),
                             content_type='application/json')
                return
            self.respond(303, headers={
                'Location': '/login',
                'Set-Cookie': COOKIE_NAME + '=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0',
            })
            return
        if path == '/desktop/action':
            if not authenticated(self.headers):
                self.respond(401, b'{"ok":false}', content_type='application/json')
                return
            if not csrf_valid(self.headers):
                self.respond(403, '{"ok":false,"detail":"请刷新页面后重试"}'.encode('utf-8'),
                             content_type='application/json')
                return
            self.desktop_action()
            return
        self.respond(404)

    def login(self):
        client = client_address(self.headers, self.client_address[0])
        allowed, retry = LOGIN_LIMITER.allow(client)
        global_allowed, global_retry = GLOBAL_LOGIN_LIMITER.allow('global')
        if not allowed or not global_allowed:
            retry = max(retry, global_retry)
            self.respond(429, '尝试次数过多，请稍后再试。'.encode('utf-8'),
                         headers={'Retry-After': str(retry)})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.respond(400)
            return
        if not 0 < length <= 1024:
            self.respond(400)
            return
        form = parse_qs(self.rfile.read(length).decode('utf-8', 'replace'))
        username = form.get('username', [''])[0]
        password = form.get('password', [''])[0]
        if not (username == 'browser' and hmac.compare_digest(password, PASSWORD)):
            LOGIN_LIMITER.record_failure(client)
            GLOBAL_LOGIN_LIMITER.record_failure('global')
            self.respond(403, '登录失败，请返回重试。'.encode('utf-8'))
            return
        LOGIN_LIMITER.clear(client)
        GLOBAL_LOGIN_LIMITER.clear('global')
        token = issue_session(PASSWORD)
        self.respond(303, headers={
            'Location': '/desktop.html',
            'Set-Cookie': COOKIE_NAME + '=' + token + '; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=' + str(SESSION_SECONDS),
        })

    def desktop_action(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.respond(400, b'{"ok":false}', content_type='application/json')
            return
        if not 0 < length <= 1024:
            self.respond(400, b'{"ok":false}', content_type='application/json')
            return
        try:
            body = json.loads(self.rfile.read(length).decode('utf-8'))
            action = body.get('action')
            ok, detail = run_desktop_action(action)
        except (AttributeError, ValueError, TypeError, json.JSONDecodeError, subprocess.SubprocessError, OSError):
            self.respond(400, b'{"ok":false}', content_type='application/json')
            return
        self.respond(200, json.dumps({'ok': ok, 'action': action, 'detail': detail}).encode('utf-8'),
                     content_type='application/json')


WebSocketProxy(
    RequestHandlerClass=LoginHandler,
    listen_host='0.0.0.0',
    listen_port=int(os.environ.get('PORT', '6080')),
    target_host='127.0.0.1',
    target_port=5900,
    web=str(NOVNC_DIR),
    web_auth=True,
    auth_plugin=CookieAuth(),
    heartbeat=25,
).start_server()
