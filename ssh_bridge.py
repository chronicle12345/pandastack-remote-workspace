"""SSH ProxyCommand over authenticated WebSocket; never changes VPN routing."""
import argparse
import getpass
import json
import os
from pathlib import Path
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'websocket_client-1.9.2-py3-none-any.whl'))
import websocket


def validate_origin(value):
    if not isinstance(value, str) or not value or any(character.isspace() for character in value):
        raise ValueError('Use an HTTPS App origin without a path')
    parsed = urllib.parse.urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        raise ValueError('Use an HTTPS App origin without a path') from None
    if (parsed.scheme != 'https' or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment
            or '?' in value or '#' in value or parsed.netloc.endswith(':')
            or port is not None and not 1 <= port <= 65535):
        raise ValueError('Use an HTTPS App origin without a path')
    return value.rstrip('/')


def proxy_options(proxy, host):
    if not proxy:
        return {'http_no_proxy': [host]}
    parsed = urllib.parse.urlsplit(proxy)
    try:
        port = parsed.port
    except ValueError:
        raise ValueError('Proxy must be http://host:port') from None
    if (parsed.scheme != 'http' or not parsed.hostname or not port
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment):
        raise ValueError('Proxy must be http://host:port')
    result = {'http_proxy_host': parsed.hostname, 'http_proxy_port': parsed.port,
              'proxy_type': 'http', 'http_no_proxy': ['unused.invalid']}
    if parsed.username:
        result['http_proxy_auth'] = (urllib.parse.unquote(parsed.username),
                                     urllib.parse.unquote(parsed.password or ''))
    return result


def login(url, proxy, session_path):
    proxy_options(proxy, urllib.parse.urlsplit(url).hostname)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': proxy, 'https': proxy} if proxy else {}))
    password = os.environ.get('BROWSER_PASSWORD') or getpass.getpass('Browser access password: ')
    request = urllib.request.Request(url + '/login', data=urllib.parse.urlencode(
        {'username': 'browser', 'password': password}).encode(), method='POST',
        headers={
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                          '(KHTML, like Gecko) Chrome/131.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Content-Type': 'application/x-www-form-urlencoded',
        })
    # Capture the secure cookie before following the login redirect.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener.add_handler(NoRedirect())
    try:
        response = opener.open(request, timeout=20)
    except urllib.error.HTTPError as error:
        if error.code != 303:
            raise RuntimeError('Login rejected') from None
        response = error
    cookie = response.headers.get('Set-Cookie', '').split(';', 1)[0]
    if not cookie.startswith('__Host-browser_session='):
        raise RuntimeError('Login did not return a session cookie')
    session_path.write_text(json.dumps({'url': url, 'cookie': cookie, 'proxy': proxy}),
                            encoding='utf-8')
    session_path.chmod(0o600)
    print('Signed in. The saved session is ready.', file=sys.stderr)


def connect(url, proxy, session_path, probe=False):
    session = json.loads(session_path.read_text(encoding='utf-8'))
    if session['url'] != url:
        raise RuntimeError('Session belongs to a different App')
    proxy = proxy or session.get('proxy')
    parsed = urllib.parse.urlsplit(url)
    ws = websocket.create_connection('wss://' + parsed.netloc + '/ssh',
        cookie=session['cookie'], origin=url, subprotocols=['binary'],
        timeout=20, **proxy_options(proxy, parsed.hostname))
    if probe:
        banner = ws.recv()
        ws.close()
        if not isinstance(banner, bytes) or not banner.startswith(b'SSH-2.0-'):
            raise RuntimeError('SSH banner missing')
        print('SSH handshake reached the remote OpenSSH server.', file=sys.stderr)
        return
    ws.settimeout(None)
    if os.name == 'nt':
        import msvcrt
        msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    def send_input():
        try:
            while chunk := os.read(sys.stdin.fileno(), 65536):
                ws.send_binary(chunk)
        except (OSError, websocket.WebSocketException):
            pass
        finally:
            ws.close()
    threading.Thread(target=send_input, daemon=True).start()
    try:
        while True:
            chunk = ws.recv()
            if not chunk:
                break
            if not isinstance(chunk, bytes):
                raise RuntimeError('Unexpected text frame')
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    finally:
        ws.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['login', 'connect', 'probe'])
    parser.add_argument('--url', required=True)
    parser.add_argument('--proxy', help='Explicit HTTP proxy; failure never falls back to direct')
    parser.add_argument('--session', type=Path, default=HERE / '.ssh-session.json')
    args = parser.parse_args()
    try:
        url = validate_origin(args.url)
    except ValueError:
        parser.error('Use an HTTPS App origin without a path')
    try:
        if args.action == 'login':
            login(url, args.proxy, args.session)
        else:
            connect(url, args.proxy, args.session, args.action == 'probe')
    except Exception as error:
        # Never include cookies, passwords or proxy credentials in error output.
        print('Connection failed (' + type(error).__name__ + '). Check login, App and proxy.',
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
