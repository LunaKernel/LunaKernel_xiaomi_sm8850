#!/usr/bin/env python3
"""用离线小包验证固定依赖的身份、内容和解包边界。"""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_dependencies as dependencies


def fixture_archive(source, output, *, zstd=False):
    # 测试输入只需标准 tar；制作端的可重现打包不属于消费端职责。
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w') as bundle:
        for path in sorted(source.rglob('*')):
            bundle.add(path, arcname=path.relative_to(source).as_posix(), recursive=False)
    data = raw.getvalue()
    if zstd:
        data = subprocess.run(['zstd', '-q', '-c'], input=data, capture_output=True,
                              check=True, timeout=10).stdout
    output.write_bytes(data)


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
            'AOSP_BACKPORT_AUDIT_SOURCE_DIR': 'sources/aosp-audit',
            'AOSP_BACKPORT_AUDIT_BASE_COMMIT': 'd' * 40,
            'LINUX_STABLE_AUDIT_BASE_COMMIT': 'e' * 40,
            'LINUX_MAINLINE_AUDIT_BASE_COMMIT': 'f' * 40,
            'KBUILD_AUDIT_SOURCE_DIR': 'sources/kbuild-audit',
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
        build = Path(__file__).resolve().parents[2] / 'patches/build.sh'
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

    def test_backport_archive_prepares_and_reuses_offline(self):
        first = self.root / 'one.tar.gz'
        fixture_archive(self.package, first)
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
        fixture_archive(self.package, archive)
        target = self.root / 'extracted'
        target.mkdir()
        dependencies.extract_archive(archive, target)
        self.assertEqual((target / 'executable').stat().st_mode & 0o777, 0o775)
        self.assertEqual(os.readlink(target / 'alias'), 'executable')
        self.assertEqual(os.readlink(target / 'nested-alias'), 'dir/../executable')
        self.assertEqual(dependencies.tree_sha256(target), dependencies.tree_sha256(self.package))

    def test_v1_inputs_keep_audit_directories_and_historical_pins(self):
        for key in ('AOSP_BACKPORT_AUDIT_SOURCE_DIR', 'AOSP_BACKPORT_AUDIT_BASE_COMMIT',
                    'LINUX_STABLE_AUDIT_BASE_COMMIT', 'LINUX_MAINLINE_AUDIT_BASE_COMMIT',
                    'KBUILD_AUDIT_SOURCE_DIR'):
            with self.subTest(key=key):
                self.assertEqual(self.data['inputs']['pins'][key], self.env[key])
                with mock.patch.dict(os.environ, {key: 'changed'}):
                    with self.assertRaisesRegex(ValueError, '当前来源'):
                        dependencies.checked_backports(self.root, self.package)

    def test_consumer_cli_rejects_producer_commands(self):
        for command in ('export-backports', 'pack-backports', 'export-toolchain'):
            result = subprocess.run([sys.executable, dependencies.__file__, command,
                                     '--workspace', str(self.root)], capture_output=True,
                                    text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('invalid choice', result.stderr)

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

    def input_fixture(self):
        source = self.root / 'input-source'
        template = source / 'ak3_template'
        template.mkdir(parents=True)
        (template / 'anykernel.sh').write_bytes(b'fixed source fixture\n')
        archive = self.root / 'ak3.tar'
        fixture_archive(source, archive)
        image = b'fixed OTA image fixture\n'
        os.environ.update({
            'AK3_TEMPLATE_URL': 'https://example.invalid/ak3.tar.gz',
            'AK3_TEMPLATE_SHA256': dependencies.sha256(archive),
            'AK3_TEMPLATE_TREE_SHA256': dependencies.tree_sha256(template),
            'ANDROID17_STOCK_SYSTEM_DLKM_URL': 'https://example.invalid/system_dlkm.img',
            'ANDROID17_STOCK_SYSTEM_DLKM_SHA256': hashlib.sha256(image).hexdigest(),
            'ANDROID17_STOCK_SYSTEM_DLKM_SIZE': str(len(image)),
            'ANDROID17_STOCK_SYSTEM_DLKM_IMAGE': dependencies.STOCK_IMAGE,
        })
        return archive, image

    def test_input_download_install_and_offline_reuse(self):
        archive, image = self.input_fixture()
        responses = [io.BytesIO(image), io.BytesIO(archive.read_bytes())]
        with mock.patch.object(dependencies.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = responses
            template = dependencies.prepare_inputs(self.root)
            self.assertEqual(dependencies.checked_stock_image(self.root).read_bytes(), image)
            self.assertEqual(dependencies.checked_ak3_template(self.root), template)
            self.assertEqual(opener.return_value.open.call_count, 2)
            for call in opener.return_value.open.call_args_list:
                self.assertEqual(call.args[0].get_header('Accept'), 'application/octet-stream')
            opener.reset_mock()
            self.assertEqual(dependencies.prepare_inputs(self.root), template)
            # 仅恢复下载缓存时，模板应可离线重新解包。
            shutil.rmtree(template)
            self.assertEqual(dependencies.prepare_inputs(self.root), template)
            opener.assert_not_called()
            (template / 'anykernel.sh').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, '模板树摘要'):
                dependencies.prepare_inputs(self.root)
            opener.assert_not_called()
        self.assertFalse(list(template.parent.glob('.ak3-*')))
        self.assertFalse(list((self.root / dependencies.STOCK_IMAGE).parent.glob('.download-*')))

    def test_ota_download_and_cached_identity_fail_closed(self):
        _, image = self.input_fixture()
        target = self.root / dependencies.STOCK_IMAGE
        for content, size, message in ((b'x' * len(image), len(image), 'SHA-256'),
                                       (image, len(image) + 1, '大小')):
            with self.subTest(message=message):
                os.environ['ANDROID17_STOCK_SYSTEM_DLKM_SIZE'] = str(size)
                with mock.patch.object(dependencies.urllib.request, 'build_opener') as opener:
                    opener.return_value.open.return_value = io.BytesIO(content)
                    with self.assertRaisesRegex(ValueError, message):
                        dependencies.prepare_inputs(self.root)
                self.assertFalse(target.exists())
                self.assertFalse(list(target.parent.glob('.download-*')))
        os.environ['ANDROID17_STOCK_SYSTEM_DLKM_SIZE'] = str(len(image))
        for content in (b'short', b'x' * len(image)):
            target.write_bytes(content)
            with mock.patch.object(dependencies.urllib.request, 'build_opener') as opener:
                with self.assertRaises(ValueError):
                    dependencies.prepare_inputs(self.root)
                opener.assert_not_called()
            self.assertEqual(target.read_bytes(), content)
        target.unlink()
        target.symlink_to(self.root / 'missing')
        with self.assertRaisesRegex(ValueError, '符号链接'):
            dependencies.prepare_inputs(self.root)

    def test_input_pins_reject_missing_values_without_fetching(self):
        self.input_fixture()
        dependencies.check_input_pins()
        keys = ('AK3_TEMPLATE_URL', 'AK3_TEMPLATE_SHA256', 'AK3_TEMPLATE_TREE_SHA256',
                'ANDROID17_STOCK_SYSTEM_DLKM_URL', 'ANDROID17_STOCK_SYSTEM_DLKM_SHA256',
                'ANDROID17_STOCK_SYSTEM_DLKM_SIZE', 'ANDROID17_STOCK_SYSTEM_DLKM_IMAGE')
        with mock.patch.object(dependencies.urllib.request, 'build_opener') as opener:
            for key in keys:
                with self.subTest(key=key), mock.patch.dict(os.environ, {key: ''}):
                    with self.assertRaises(ValueError):
                        dependencies.prepare_inputs(self.root)
            for key, value in (('AK3_TEMPLATE_URL', 'http://example.invalid/template'),
                               ('AK3_TEMPLATE_TREE_SHA256', '../escape'),
                               ('ANDROID17_STOCK_SYSTEM_DLKM_SIZE', '-1'),
                               ('ANDROID17_STOCK_SYSTEM_DLKM_IMAGE', '../escape')):
                with self.subTest(key=key), mock.patch.dict(os.environ, {key: value}):
                    with self.assertRaises(ValueError):
                        dependencies.check_input_pins()
            opener.assert_not_called()

    def test_ak3_archive_rejects_unsafe_members_wrong_root_and_tree(self):
        archive, _ = self.input_fixture()
        for name in ('../escaped', 'unexpected/file', 'ak3_template/changed'):
            with self.subTest(name=name):
                with tarfile.open(archive, 'w') as bundle:
                    member = tarfile.TarInfo(name)
                    member.size = 1
                    bundle.addfile(member, io.BytesIO(b'x'))
                os.environ['AK3_TEMPLATE_SHA256'] = dependencies.sha256(archive)
                with mock.patch.object(dependencies, 'archive_file', return_value=archive):
                    with self.assertRaises((ValueError, tarfile.FilterError)):
                        dependencies.prepare_ak3_template(self.root)
                self.assertFalse((self.root / 'work/cache/dependencies/escaped').exists())
                self.assertEqual(list((self.root / 'work/cache/dependencies').iterdir()), [])

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
        fixture_archive(source, archive, zstd=True)
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
