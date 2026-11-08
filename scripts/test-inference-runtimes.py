#!/usr/bin/env python3
"""Hermetic archive, checksum, and manifest regression checks (no downloads)."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import sys
sys.dont_write_bytecode = True
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-inference-runtimes.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class RuntimeInstallerTests(unittest.TestCase):
    def test_rejects_archive_escape_and_foreign_roots(self):
        for name in ['../escape', '/absolute', 'llama-test/../escape', 'other/server']:
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                installer.validate_archive_member(tarfile.TarInfo(name), 'test')
        link = tarfile.TarInfo('llama-test/link')
        link.type = tarfile.SYMTYPE
        link.linkname = '../../escape'
        with self.assertRaises(RuntimeError):
            installer.validate_archive_member(link, 'test')

    def test_accepts_prism_root_directory_marker(self):
        member = tarfile.TarInfo('.')
        member.type = tarfile.DIRTYPE
        installer.validate_archive_member(member, 'test')

    def test_checksum_failure_leaves_no_installed_runtime(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(installer, 'DEST', Path(temp)), patch.object(installer.urllib.request, 'urlopen', return_value=io.BytesIO(b'corrupt')):
                with self.assertRaisesRegex(RuntimeError, 'checksum'):
                    installer.install_compatibility('llamaCompatibility')
                self.assertEqual(list(Path(temp).iterdir()), [])

    def test_verified_tree_rejects_modified_binary(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            member = tarfile.TarInfo('llama-test/llama-server')
            member.size = 8
            archive.addfile(member, io.BytesIO(b'original'))
        data.seek(0)
        with tempfile.TemporaryDirectory() as temp, tarfile.open(fileobj=data, mode='r:gz') as archive:
            directory = Path(temp)
            (directory / 'llama-test').mkdir()
            binary = directory / 'llama-test/llama-server'
            binary.write_bytes(b'original')
            installer.verify_runtime_tree(archive, directory, 'test')
            binary.write_bytes(b'modified')
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                installer.verify_runtime_tree(archive, directory, 'test')

    def test_compatible_install_preserves_other_entries_and_rollbacks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = {'kind': 'omlx', 'executable': 'old/omlx'}
            rollback = {'kind': 'llamaCompatibility', 'executable': 'old/llama-server'}
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'version': 1, 'runtimes': [original, rollback], 'custom': True}))
            def install(kind, _):
                return {'kind': 'llamaCompatibility', 'executable': kind + '/server'}
            with patch.object(installer, 'DEST', root), patch.object(installer, 'BUILD', root / 'cache'), \
                    patch.object(installer, 'install', side_effect=install), \
                    patch.object(installer.platform, 'system', return_value='Darwin'), \
                    patch.object(installer.platform, 'machine', return_value='arm64'), \
                    patch('sys.argv', ['installer', '--runtime', 'compatible']):
                installer.main()
                installer.main()
            result = json.loads(manifest.read_text())
            self.assertTrue(result['custom'])
            self.assertIn(original, result['runtimes'])
            self.assertIn(rollback, result['runtimes'])
            self.assertEqual(len(result['runtimes']), 4)


if __name__ == '__main__':
    unittest.main()
