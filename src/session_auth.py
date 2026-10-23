"""Signed browser sessions that remain valid across gateway restarts."""
import hashlib
import hmac
import os
import time

DEFAULT_SESSION_TTL_MINUTES = 180
MIN_SESSION_TTL_MINUTES = 1
MAX_SESSION_TTL_MINUTES = 10080
_MAX_TOKEN_LENGTH = 128


def _load_session_ttl_minutes():
    raw = os.environ.get('SESSION_TTL_MINUTES', str(DEFAULT_SESSION_TTL_MINUTES)).strip()
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ValueError('SESSION_TTL_MINUTES must be an integer') from None
    if not MIN_SESSION_TTL_MINUTES <= value <= MAX_SESSION_TTL_MINUTES:
        raise ValueError(
            'SESSION_TTL_MINUTES must be between '
            + str(MIN_SESSION_TTL_MINUTES) + ' and ' + str(MAX_SESSION_TTL_MINUTES)
        )
    return value


SESSION_TTL_MINUTES = _load_session_ttl_minutes()
SESSION_SECONDS = SESSION_TTL_MINUTES * 60


def _key(password):
    if not isinstance(password, str) or not password:
        raise ValueError('A non-empty browser password is required')
    return hashlib.sha256(
        b'pandastack-browser-session-v1\0' + password.encode('utf-8')
    ).digest()


def _signature(password, issued_at):
    message = ('v1:' + str(issued_at)).encode('ascii')
    return hmac.new(_key(password), message, hashlib.sha256).hexdigest()


def issue_session(password, now=None):
    issued_at = int(time.time() if now is None else now)
    return _signature(password, issued_at) + '.' + str(issued_at)


def validate_session(token, password, now=None):
    if not isinstance(token, str) or not token or len(token) > _MAX_TOKEN_LENGTH:
        return False
    try:
        signature, issued_text = token.rsplit('.', 1)
        issued_at = int(issued_text)
        expected = _signature(password, issued_at)
    except (TypeError, ValueError):
        return False
    if issued_at < 0:
        return False
    current = int(time.time() if now is None else now)
    if issued_at > current or current - issued_at >= SESSION_SECONDS:
        return False
    return hmac.compare_digest(signature, expected)


def session_expiry(token, password, now=None):
    if not validate_session(token, password, now):
        return None
    return int(token.rsplit('.', 1)[1]) + SESSION_SECONDS


def session_csrf(token, password, now=None):
    """Return a CSRF token bound to a valid browser session."""
    if not validate_session(token, password, now):
        return None
    message = b'csrf-v1\0' + token.encode('ascii')
    return hmac.new(_key(password), message, hashlib.sha256).hexdigest()