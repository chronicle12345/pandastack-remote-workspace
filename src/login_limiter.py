"""File-backed login failure limits shared by forked gateway processes."""
import json
import os
from pathlib import Path
import threading
import time

try:
    import fcntl
except ImportError:  # Windows test runs; production uses Linux.
    fcntl = None

_PROCESS_LOCK = threading.Lock()
_MAX_CLIENTS = 10000


class _Lock:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def __enter__(self):
        if fcntl is None:
            _PROCESS_LOCK.acquire()
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.handle = self.path.open('a+')
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        if fcntl is None:
            _PROCESS_LOCK.release()
        else:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()


class LoginLimiter:
    def __init__(self, path, max_failures=5, window_seconds=900):
        self.path = Path(path)
        self.lock_path = self.path.with_suffix(self.path.suffix + '.lock')
        self.max_failures = max(1, int(max_failures))
        self.window_seconds = max(60, int(window_seconds))

    def _read(self):
        try:
            data = json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError, ValueError, TypeError):
            return {}
        return data if isinstance(data, dict) else {}

    def _write(self, data):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + '.tmp')
        temporary.write_text(json.dumps(data, separators=(',', ':')), encoding='utf-8')
        os.replace(temporary, self.path)

    def _prune(self, data, now):
        cleaned = {}
        for client, failures in data.items():
            if not isinstance(client, str) or not isinstance(failures, list):
                continue
            recent = []
            for value in failures:
                if isinstance(value, (int, float)) and 0 <= now - value < self.window_seconds:
                    recent.append(int(value))
            if recent:
                cleaned[client] = recent
        if len(cleaned) > _MAX_CLIENTS:
            newest = sorted(cleaned, key=lambda key: max(cleaned[key]), reverse=True)
            cleaned = {key: cleaned[key] for key in newest[:_MAX_CLIENTS]}
        return cleaned

    def allow(self, client, now=None):
        now = int(time.time() if now is None else now)
        with _Lock(self.lock_path):
            data = self._prune(self._read(), now)
            failures = data.get(client, [])
            if len(failures) >= self.max_failures:
                retry = self.window_seconds - (now - min(failures))
                return False, max(1, int(retry))
            self._write(data)
            return True, 0

    def record_failure(self, client, now=None):
        now = int(time.time() if now is None else now)
        with _Lock(self.lock_path):
            data = self._prune(self._read(), now)
            failures = data.setdefault(client, [])
            failures.append(now)
            self._write(data)

    def clear(self, client, now=None):
        now = int(time.time() if now is None else now)
        with _Lock(self.lock_path):
            data = self._prune(self._read(), now)
            data.pop(client, None)
            self._write(data)
