"""Tests for workspace snapshot privacy exclusions."""
import io
import tarfile
import tempfile
from pathlib import Path
import unittest

from cryptography.fernet import Fernet
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'src'))
from workspace_sync import WorkspaceSync, build_snapshot, excluded


class WorkspaceSnapshotTest(unittest.TestCase):
    def test_secret_files_are_excluded(self):
        for name in ('.env', '.env.local', 'server.key', 'credentials.json',
                     'secrets.yaml', 'known_hosts', '.ssh', 'id_ed25519', 'id_rsa.pub'):
            self.assertTrue(excluded(name), name)
        for name in ('README.md', 'app.py', 'src'):
            self.assertFalse(excluded(name), name)

    def test_snapshot_does_not_include_secret_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'app.py').write_text('print("ok")\n', encoding='utf-8')
            (root / '.env').write_text('TOKEN=secret\n', encoding='utf-8')
            (root / 'server.key').write_text('secret\n', encoding='utf-8')
            key = Fernet.generate_key()
            payload, _digest = build_snapshot(root, key)
            raw = Fernet(key).decrypt(payload)
            with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
                names = set(archive.getnames())
        self.assertIn('app.py', names)
        self.assertNotIn('.env', names)
        self.assertNotIn('server.key', names)


class MemoryStore:
    def __init__(self, payload):
        self.payload = payload
        self.saved = []

    def initialize(self):
        return self.payload

    def save(self, payload):
        self.saved.append(payload)


class WorkspaceSyncStartTest(unittest.TestCase):
    def test_existing_workspace_is_not_overwritten_by_restore(self):
        with tempfile.TemporaryDirectory() as source_dir, \
                tempfile.TemporaryDirectory() as target_parent, \
                tempfile.TemporaryDirectory() as state_dir:
            source = Path(source_dir)
            (source / 'snapshot.txt').write_text('snapshot\n', encoding='utf-8')
            key = Fernet.generate_key()
            payload, _digest = build_snapshot(source, key)

            root = Path(target_parent) / 'workspace'
            root.mkdir()
            (root / 'current.txt').write_text('current\n', encoding='utf-8')
            store = MemoryStore(payload)
            worker = WorkspaceSync(
                root,
                key,
                store,
                status=Path(state_dir) / 'status.json',
                ready=Path(state_dir) / 'ready',
            )
            worker.start()

            self.assertEqual((root / 'current.txt').read_text(encoding='utf-8'), 'current\n')
            self.assertFalse((root / 'snapshot.txt').exists())
            self.assertTrue((Path(state_dir) / 'ready').exists())
            self.assertEqual(len(store.saved), 1)

    def test_empty_workspace_restores_snapshot(self):
        with tempfile.TemporaryDirectory() as source_dir, \
                tempfile.TemporaryDirectory() as target_parent, \
                tempfile.TemporaryDirectory() as state_dir:
            source = Path(source_dir)
            (source / 'snapshot.txt').write_text('snapshot\n', encoding='utf-8')
            key = Fernet.generate_key()
            payload, _digest = build_snapshot(source, key)

            root = Path(target_parent) / 'workspace'
            root.mkdir()
            store = MemoryStore(payload)
            worker = WorkspaceSync(
                root,
                key,
                store,
                status=Path(state_dir) / 'status.json',
                ready=Path(state_dir) / 'ready',
            )
            worker.start()

            self.assertEqual((root / 'snapshot.txt').read_text(encoding='utf-8'), 'snapshot\n')
            self.assertTrue((Path(state_dir) / 'ready').exists())


if __name__ == '__main__':
    unittest.main()