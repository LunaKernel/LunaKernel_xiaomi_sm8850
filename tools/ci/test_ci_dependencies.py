#!/usr/bin/env python3
"""用离线小包验证固定依赖的身份、内容和解包边界。"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_dependencies as dependencies


class DependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='luna-dependency-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.commit = 'a' * 40
        self.env = {
            'COMMON_REPO': 'https://official.invalid/common', 'COMMON_COMMIT': 'b' * 40,
            'ENABLE_BACKPORT_AUDIT': '1', 'ENABLE_SELECTED_BACKPORTS': '1',
            'BACKPORT_AUDIT_SNAPSHOT': '2026-08-28',
            'SELECTED_BACKPORT_MANIFEST': 'patches/selected.tsv',
            'BUILD_ENVIRONMENT_DIR': 'work/tools', 'CI_TOOLCHAIN_NAME': 'fixed-test',
        }
        self.environment = mock.patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        manifest = self.root / 'patches/selected.tsv'
        manifest.parent.mkdir()
        manifest.write_text('\t'.join(('1', 'fixture', 'direct', 'mainline', 'snapshot',
                                      self.commit, '2026-01-01', 'c' * 40, 'file.c', '-', '-', '-')) + '\n')
        self.package = self.root / 'package'
        (self.package / 'patches').mkdir(parents=True)
        patch = self.package / 'patches' / (self.commit + '.patch')
        patch.write_bytes(b'fixed official patch bytes\n')
        self.data = {
            'format': 1, 'kind': 'backports', 'inputs': dependencies.backport_inputs(self.root),
            'files': {'patches/' + patch.name: dependencies.sha256(patch)},
            'commits': {self.commit: {'source': 'mainline', 'sha256': dependencies.sha256(patch)}},
        }
        self.repin_manifest()

    def repin_manifest(self):
        (self.package / 'manifest.json').write_bytes(dependencies.json_bytes(self.data))
        os.environ['BACKPORT_BUNDLE_MANIFEST_SHA256'] = dependencies.sha256(self.package / 'manifest.json')

    def test_fixed_contents_validate_without_audit_repositories(self):
        self.assertEqual(dependencies.checked_backports(self.root, self.package), self.package)
        self.assertFalse((self.root / 'sources').exists())

    def test_corrupt_missing_and_extra_contents_fail(self):
        patch = self.package / 'patches' / (self.commit + '.patch')
        original = patch.read_bytes()
        patch.write_bytes(original + b'changed')
        with self.assertRaisesRegex(ValueError, '文件摘要'):
            dependencies.checked_backports(self.root, self.package)
        patch.unlink()
        with self.assertRaisesRegex(ValueError, '文件集合'):
            dependencies.checked_backports(self.root, self.package)
        patch.write_bytes(original)
        (self.package / 'unexpected').write_text('extra')
        with self.assertRaisesRegex(ValueError, '文件集合'):
            dependencies.checked_backports(self.root, self.package)

    def test_current_pins_and_manifest_bytes_are_bound(self):
        os.environ['COMMON_COMMIT'] = 'd' * 40
        with self.assertRaisesRegex(ValueError, '当前来源'):
            dependencies.checked_backports(self.root, self.package)
        os.environ['COMMON_COMMIT'] = self.env['COMMON_COMMIT']
        with (self.root / 'patches/selected.tsv').open('a') as stream:
            stream.write('# changed manifest\n')
        with self.assertRaisesRegex(ValueError, '当前来源'):
            dependencies.checked_backports(self.root, self.package)

    def test_build_path_resolution_preserves_exported_backport_pins(self):
        os.environ['F2FS_FOREGROUND_GC_PATCH'] = 'patches/backports/gc.patch'
        os.environ['F2FS_FOREGROUND_GC_PATCH_SHA256'] = 'e' * 64
        self.data['inputs'] = dependencies.backport_inputs(self.root)
        self.repin_manifest()
        build = Path(__file__).resolve().parents[2] / 'build.sh'
        assignments = '\n'.join(line for line in build.read_text().splitlines()
                                if line.startswith('F2FS_FOREGROUND_GC_PATCH'))
        result = subprocess.run(['bash', '-c', 'set -eu\nHOST_WORKSPACE_DIR="$1"\n'
                                 + assignments + '\nenv -0', 'test', str(self.root)],
                                check=True, capture_output=True, timeout=10)
        environment = dict(entry.split('=', 1) for entry in result.stdout.decode().split('\0') if entry)
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(dependencies.checked_backports(self.root, self.package), self.package)

    def test_manifest_and_commit_membership_are_bound(self):
        with (self.package / 'manifest.json').open('a') as stream:
            stream.write(' ')
        with self.assertRaisesRegex(ValueError, '清单摘要'):
            dependencies.checked_backports(self.root, self.package)
        self.data['commits'] = {}
        self.repin_manifest()
        with self.assertRaisesRegex(ValueError, '提交集合'):
            dependencies.checked_backports(self.root, self.package)

    def test_backport_archive_is_reproducible_and_prepares_offline(self):
        first = self.root / 'one.tar.gz'
        second = self.root / 'two.tar.gz'
        self.assertEqual(dependencies.write_archive(self.package, first),
                         dependencies.write_archive(self.package, second))
        with mock.patch.object(dependencies, 'archive_file', return_value=first) as fetch:
            directory = dependencies.prepare_backports(self.root)
            self.assertEqual(dependencies.checked_backports(self.root), directory)
            dependencies.prepare_backports(self.root)
            fetch.assert_called_once()

    def test_extraction_preserves_pinned_modes_and_safe_links(self):
        payload = self.package / 'executable'
        payload.write_text('fixture')
        payload.chmod(0o775)
        (self.package / 'alias').symlink_to('executable')
        (self.package / 'dir').mkdir()
        (self.package / 'nested-alias').symlink_to('dir/../executable')
        archive = self.root / 'mode.tar.gz'
        dependencies.write_archive(self.package, archive)
        target = self.root / 'extracted'
        target.mkdir()
        dependencies.extract_archive(archive, target)
        self.assertEqual((target / 'executable').stat().st_mode & 0o777, 0o775)
        self.assertEqual(os.readlink(target / 'alias'), 'executable')
        self.assertEqual(os.readlink(target / 'nested-alias'), 'dir/../executable')
        self.assertEqual(dependencies.tree_sha256(target), dependencies.tree_sha256(self.package))

    def test_toolchain_export_requires_official_audit_before_provenance(self):
        failure = subprocess.CalledProcessError(7, ['bash', 'init.sh', '--prepare-dependencies'])
        with mock.patch.object(dependencies.subprocess, 'run', side_effect=failure) as audit:
            with self.assertRaises(subprocess.CalledProcessError):
                dependencies.export_toolchain(self.root, self.root / 'export.tar.zst')
        self.assertEqual(audit.call_args.args[0], ['bash', 'init.sh', '--prepare-dependencies'])
        self.assertEqual(audit.call_args.kwargs['env']['BACKPORT_SOURCE_AUDIT'], '1')
        self.assertFalse((self.root / 'export.tar.zst').exists())

    def test_unsafe_archive_members_fail_without_writing_outside(self):
        for name, link in (('../escaped', None), ('/absolute', None), ('link', '../escaped')):
            with self.subTest(name=name, link=link):
                archive = self.root / 'unsafe.tar'
                with tarfile.open(archive, 'w') as bundle:
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = link
                        bundle.addfile(member)
                    else:
                        member.size = 1
                        bundle.addfile(member, io.BytesIO(b'x'))
                target = self.root / 'unsafe-output'
                target.mkdir(exist_ok=True)
                with self.assertRaises((ValueError, tarfile.FilterError)):
                    dependencies.extract_archive(archive, target)
        self.assertFalse((self.root / 'escaped').exists())

    def test_download_cache_requires_actual_hash_and_https(self):
        digest = 'e' * 64
        os.environ['BACKPORT_BUNDLE_SHA256'] = digest
        os.environ['BACKPORT_BUNDLE_URL'] = 'http://untrusted.invalid/package'
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            dependencies.archive_file(self.root, 'BACKPORT_BUNDLE')
        directory = self.root / 'work/cache/downloads/ci-dependencies'
        (directory / (digest + '.tar')).write_bytes(b'wrong cache bytes')
        with self.assertRaisesRegex(ValueError, '归档摘要'):
            dependencies.archive_file(self.root, 'BACKPORT_BUNDLE')

    def test_toolchain_install_and_reuse_verify_real_tree(self):
        for key in dependencies.TOOLCHAIN_KEYS:
            os.environ[key] = 'fixture'
        source = self.root / 'toolchain-package'
        (source / 'payload/bin').mkdir(parents=True)
        (source / 'payload/bin/clang').write_text('fixed compiler fixture\n')
        digest = dependencies.tree_sha256(source / 'payload')
        os.environ['CI_TOOLCHAIN_TREE_SHA256'] = digest
        (source / 'provenance.json').write_bytes(dependencies.json_bytes({
            'format': 1, 'kind': 'toolchain',
            'inputs': {key: os.environ[key] for key in dependencies.TOOLCHAIN_KEYS},
        }))
        archive = self.root / 'toolchain.tar.zst'
        dependencies.write_archive(source, archive, zstd=True)
        with mock.patch.object(dependencies, 'archive_file', return_value=archive) as fetch:
            installed = dependencies.prepare_toolchain(self.root)
            self.assertEqual(dependencies.tree_sha256(installed), digest)
            self.assertEqual(dependencies.prepare_toolchain(self.root), installed)
            fetch.assert_called_once()
            (installed / 'bin/clang').write_text('changed compiler')
            with self.assertRaisesRegex(ValueError, '拒绝覆盖'):
                dependencies.prepare_toolchain(self.root)


if __name__ == '__main__':
    unittest.main()
