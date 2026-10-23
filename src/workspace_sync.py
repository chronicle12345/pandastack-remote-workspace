"""Encrypted, single-workspace snapshots. Never scans the user's home directory."""
import argparse
import gzip
import hashlib
import io
import json
import os
import stat
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

from cryptography.fernet import Fernet

MAX_BYTES = 25 * 1024 * 1024
EXCLUDED = {
    '.git', 'node_modules', '.venv', 'venv', '__pycache__', '.claude', '.config',
    '.cache', '.ssh', '.aws', '.gnupg', 'chromium', 'chrome', 'google-chrome',
    'browser', 'browser-profile', 'browser-data', 'chrome-profile',
    'chromium-profile', 'firefox', '.mozilla', 'workspace-sync.json',
    'workspace-sync.ready', '.npmrc', '.pypirc', '.netrc', '.git-credentials',
    '.gitconfig', '.bash_history', '.zsh_history', '.python_history',
    'known_hosts', 'known_hosts.old', 'workspace-recovery-key.txt',
}
EXCLUDED_SUFFIXES = (
    '.key', '.pem', '.p12', '.pfx', '.jks', '.keystore', '.ppk', '.crt',
    '.cer', '.der', '.csr', '.ovpn', '.kdbx', '.token', '.secret', '.pub',
)


def excluded(name):
    lower = name.lower()
    return (lower in EXCLUDED or lower.startswith('.env')
            or lower.endswith(EXCLUDED_SUFFIXES)
            or lower.startswith(('credentials', 'secrets', 'id_rsa', 'id_dsa',
                                 'id_ecdsa', 'id_ed25519')))


def build_snapshot(root, key, max_bytes=MAX_BYTES):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Workspace must be a real directory')
    total = 0
    count = 0
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode='wb', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w|') as archive:
            for folder, dirs, files in os.walk(root, followlinks=False):
                dirs[:] = sorted(d for d in dirs if not excluded(d)
                                 and not (Path(folder) / d).is_symlink())
                for name in sorted(dirs + files):
                    path = Path(folder) / name
                    if excluded(name) or path.is_symlink():
                        continue
                    metadata = path.stat(follow_symlinks=False)
                    if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
                        continue
                    count += 1
                    if count > 100000:
                        raise ValueError('Too many workspace entries')
                    info = tarfile.TarInfo(path.relative_to(root).as_posix())
                    info.mode = metadata.st_mode & 0o777
                    if stat.S_ISDIR(metadata.st_mode):
                        info.type = tarfile.DIRTYPE
                        archive.addfile(info)
                        continue
                    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
                    with os.fdopen(os.open(path, flags), 'rb') as source:
                        before = os.fstat(source.fileno())
                        if not stat.S_ISREG(before.st_mode):
                            raise ValueError('Workspace changed while reading')
                        data = source.read(max_bytes - total + 1)
                        after = os.fstat(source.fileno())
                    total += len(data)
                    if total > max_bytes:
                        raise ValueError('Workspace exceeds 25 MiB snapshot limit')
                    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise ValueError('Workspace changed while reading')
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
    raw = buffer.getvalue()
    return Fernet(key).encrypt(raw), hashlib.sha256(raw).hexdigest()


def restore_snapshot(payload, root, key, max_bytes=MAX_BYTES):
    root = Path(root)
    if root.is_symlink() or (root.exists() and (not root.is_dir() or any(root.iterdir()))):
        raise ValueError('Refusing to restore into a nonempty or linked workspace')
    if len(payload) > (max_bytes + 64 * 1024 * 1024) * 2:
        raise ValueError('Snapshot payload too large')
    raw = Fernet(key).decrypt(bytes(payload))
    # Validate all headers before creating any restored file.
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        members = []
        total = 0
        seen = set()
        for entry in archive:
            path = PurePosixPath(entry.name)
            if (not entry.name or '\\' in entry.name or ':' in entry.name
                    or path.is_absolute() or '..' in path.parts
                    or not path.parts or any(excluded(part) for part in path.parts)
                    or not (entry.isfile() or entry.isdir()) or entry.name in seen):
                raise ValueError('Unsafe snapshot entry')
            total += entry.size
            if total > max_bytes or len(members) >= 100000:
                raise ValueError('Snapshot exceeds restore limit')
            seen.add(entry.name)
            members.append(entry)
        root.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.workspace-restore-', dir=root.parent) as staging:
            stage = Path(staging)
            for entry in members:
                dest = stage.joinpath(*PurePosixPath(entry.name).parts)
                if entry.isdir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(entry) as source, dest.open('xb') as output:
                        while block := source.read(1024 * 1024):
                            output.write(block)
                    dest.chmod((entry.mode & 0o777) | 0o600)
            if root.exists():
                if root.is_symlink() or any(root.iterdir()):
                    raise ValueError('Workspace became nonempty during restore')
                root.rmdir()
            stage.rename(root)


class PostgresStore:
    def __init__(self, url, workspace_id):
        self.url = url
        self.workspace_id = workspace_id
        self.connection = None

    def connect(self):
        if self.connection is None or self.connection.closed:
            import psycopg2
            self.connection = psycopg2.connect(self.url, connect_timeout=15,
                                             application_name='pds-workspace-sync')
        return self.connection

    def initialize(self):
        with self.connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute('''CREATE TABLE IF NOT EXISTS pds_workspace_snapshots (
                    workspace_id TEXT PRIMARY KEY, payload BYTEA NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())''')
                cursor.execute('SELECT payload FROM pds_workspace_snapshots WHERE workspace_id=%s',
                               (self.workspace_id,))
                row = cursor.fetchone()
                return bytes(row[0]) if row else None

    def save(self, payload):
        # Commit only the complete, encrypted archive; failures roll back the prior row.
        with self.connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute('''INSERT INTO pds_workspace_snapshots (workspace_id,payload)
                    VALUES (%s,%s) ON CONFLICT (workspace_id) DO UPDATE
                    SET payload=EXCLUDED.payload,updated_at=NOW()''',
                               (self.workspace_id, payload))


class WorkspaceSync:
    def __init__(self, root, key, store, status='/run/workspace-sync.json',
                 ready='/run/workspace-sync.ready'):
        self.root, self.key, self.store = Path(root), key, store
        self.status, self.ready = Path(status), Path(ready)
        self.digest = None
        self.last_saved = None

    def report(self, state, error=None):
        self.status.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.status.with_suffix('.tmp')
        temporary.write_text(json.dumps({'state': state, 'last_saved': self.last_saved,
                                         'error': error}), encoding='utf-8')
        temporary.replace(self.status)

    def start(self):
        self.ready.unlink(missing_ok=True)
        payload = self.store.initialize()
        if self.root.is_symlink() or (self.root.exists() and not self.root.is_dir()):
            raise ValueError('Workspace must be a real directory')
        if payload is not None:
            if self.root.exists() and any(self.root.iterdir()):
                # Keep files already present in this container. The next tick saves them.
                pass
            else:
                restore_snapshot(payload, self.root, self.key)
        else:
            self.root.mkdir(parents=True, exist_ok=True)
        self.tick()
        self.ready.parent.mkdir(parents=True, exist_ok=True)
        self.ready.touch()

    def tick(self):
        payload, digest = build_snapshot(self.root, self.key)
        if digest != self.digest:
            self.store.save(payload)
            self.digest = digest
            self.last_saved = datetime.now(timezone.utc).isoformat()
        self.report('synced')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    worker = None
    try:
        worker = WorkspaceSync(os.environ.get('WORKSPACE_DIR', '/workspace'),
                               os.environ['WORKSPACE_KEY'],
                               PostgresStore(os.environ['DATABASE_URL'],
                                             os.environ.get('WORKSPACE_ID', 'pandastack-workspace')))
        worker.start()
    except Exception as error:
        if worker:
            worker.report('error', type(error).__name__)
        return 1
    if args.once:
        return 0
    while True:
        time.sleep(2)
        try:
            worker.tick()
        except Exception as error:
            # Never print exception strings: drivers can include connection secrets.
            worker.report('error', type(error).__name__)


if __name__ == '__main__':
    raise SystemExit(main())
