#!/usr/bin/env python3
"""固定 CI 依赖的 v1 消费协议与内容校验。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request

from tree_sha256 import tree_sha256

FORMAT = 1
LEGACY = (
    ('stable', 'F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT', 'F2FS_ACL_ENTRY_BOUNDS_FIX'),
    ('stable', 'F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT', 'F2FS_LISTXATTR_BOUNDS_FIX'),
    ('stable', 'BLKCG_RSTAT_RELEASE_STABLE_COMMIT', 'BLKCG_RSTAT_RELEASE_FIX'),
    ('stable', 'F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT', 'F2FS_FOREGROUND_GC_DEADLOCK_FIX'),
    ('stable', 'F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT', 'F2FS_FOREGROUND_GC_DEADLOCK_FIX'),
    ('stable', 'IPV6_MLD_DELAYED_WORK_STABLE_COMMIT', 'IPV6_MLD_DELAYED_WORK_UAF_FIX'),
    ('mainline', 'IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT', 'IPV6_MLD_DELAYED_WORK_UAF_FIX'),
    ('mainline', 'TIMER_BASE_FAST_PATH_COMMIT', 'TIMER_BASE_FAST_PATH'),
    ('aosp', 'F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT', 'F2FS_DIO_OVERWRITE_FAST_PATH'),
    ('aosp', 'BLK_WBT_DONE_FAST_PATH_COMMIT', 'BLK_WBT_DONE_FAST_PATH'),
    ('aosp', 'MEMCG_RSTAT_FAST_PATH_COMMIT', 'MEMCG_RSTAT_FAST_PATH'),
    ('aosp', 'TCP_RECV_MSTAMP_FAST_PATH_COMMIT', 'TCP_RECV_MSTAMP_FAST_PATH'),
    ('aosp', 'IPV6_MLD_UAF_FIX_COMMIT', 'IPV6_MLD_UAF_FIX'),
)
BACKPORT_FAMILIES = ('F2FS_', 'BLKCG_', 'BLK_WBT_', 'MEMCG_RSTAT_', 'TCP_RECV_',
                     'IPV6_MLD_', 'TIMER_BASE_', 'INDEPENDENT_', 'SELECTED_BACKPORT_',
                     'AOSP_BACKPORT_', 'LINUX_STABLE_', 'LINUX_MAINLINE_', 'KBUILD_AUDIT_')
TOOLCHAIN_KEYS = (
    'AOSP_CLANG_REPO', 'AOSP_CLANG_COMMIT', 'CI_CLANG_REVISION', 'CI_CLANG_GIT_TREE',
    'CI_CLANG_LEAF_TREE_SHA256', 'CI_CLANG_VERSION_LINE', 'CI_LLD_VERSION_TEXT',
    'AOSP_RUST_REPO', 'AOSP_RUST_COMMIT', 'CI_RUST_SUBTREE', 'CI_RUST_GIT_TREE',
    'CI_RUST_LEAF_TREE_SHA256', 'CI_RUSTC_COMMIT_HASH', 'CI_RUSTC_RELEASE',
    'CI_RUST_TOOLCHAIN_VERSION', 'AOSP_BUILD_TOOLS_REPO', 'AOSP_BUILD_TOOLS_COMMIT',
    'CI_BUILD_TOOLS_SUBTREE', 'CI_BUILD_TOOLS_GIT_TREE', 'CI_BUILD_TOOLS_LEAF_TREE_SHA256',
    'CI_BINDGEN_URL', 'CI_BINDGEN_GIT_BLOB', 'CI_BINDGEN_SHA256', 'CI_BINDGEN_VERSION',
    'CI_HOST_BC_URL', 'CI_HOST_BC_GIT_BLOB', 'CI_HOST_BC_SHA256', 'CI_TOOLCHAIN_TREE_SHA256',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def digest_pin(name):
    value = os.environ.get(name, '')
    require(re.fullmatch(r'[0-9a-f]{64}', value), '缺少有效依赖摘要: ' + name)
    return value


def local_path(root, relative):
    relative = Path(relative)
    require(not relative.is_absolute() and '..' not in relative.parts, '依赖路径必须位于项目内')
    target = root / relative
    require(not any(path.is_symlink() for path in (target, *target.parents)), '依赖路径经过符号链接')
    return target


def toolchain_path(root):
    name = os.environ['CI_TOOLCHAIN_NAME']
    require(re.fullmatch(r'[A-Za-z0-9._-]+', name), '工具链目录名无效')
    return local_path(root, Path(os.environ['BUILD_ENVIRONMENT_DIR']) / 'toolchain' / name)


def manifest_files(root):
    selected = Path(os.environ['SELECTED_BACKPORT_MANIFEST'])
    files = [selected] if os.environ.get('ENABLE_SELECTED_BACKPORTS') == '1' else []
    files += [path.relative_to(root) for path in
              sorted((root / 'patches/backports/kmi6-2026-09-independent').glob('*.tsv'))]
    return files


def backport_inputs(root):
    # v1 内容身份包含来源目录和历史起点 pin；消费端也必须保留这些字段。
    pins = {key: value for key, value in os.environ.items()
            if key.removeprefix('ENABLE_').startswith(BACKPORT_FAMILIES)}
    for key in ('COMMON_REPO', 'COMMON_COMMIT', 'ENABLE_BACKPORT_AUDIT',
                'ENABLE_SELECTED_BACKPORTS', 'BACKPORT_AUDIT_SNAPSHOT'):
        pins[key] = os.environ[key]
    files = {path.as_posix(): sha256(local_path(root, path)) for path in manifest_files(root)}
    return {'pins': dict(sorted(pins.items())), 'manifests': files}


def needed_commits(root):
    commits = {}
    for relative in manifest_files(root):
        for line in local_path(root, relative).read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            row = line.split('\t')
            require(len(row) == 12, '回移清单字段数量错误')
            commits[row[5]] = row[3]
    for source, key, feature in LEGACY:
        if os.environ.get('ENABLE_' + feature) == '1':
            commits[os.environ[key]] = source
    require(all(re.fullmatch(r'[0-9a-f]{40}', key) for key in commits), '回移提交格式错误')
    return dict(sorted(commits.items()))


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def checked_backports(root, directory=None):
    expected = digest_pin('BACKPORT_BUNDLE_MANIFEST_SHA256')
    directory = directory or local_path(root, 'work/cache/dependencies/backports-' + expected)
    manifest = directory / 'manifest.json'
    require(not directory.is_symlink() and manifest.is_file() and not manifest.is_symlink(), '固定回移包缺失')
    require(sha256(manifest) == expected, '回移包清单摘要不匹配')
    data = json.loads(manifest.read_bytes())
    require(data.get('format') == FORMAT and data.get('kind') == 'backports', '回移包格式不匹配')
    require(data.get('inputs') == backport_inputs(root), '回移包与当前来源 pin 或清单不匹配')
    require({key: value['source'] for key, value in data['commits'].items()} == needed_commits(root),
            '回移包提交集合不完整或来源不匹配')
    actual = set()
    for path in directory.rglob('*'):
        require(not path.is_symlink(), '回移包不得包含符号链接')
        if path.is_file():
            actual.add(path.relative_to(directory).as_posix())
        else:
            require(path.is_dir(), '回移包含特殊文件')
    require(actual == set(data['files']) | {'manifest.json'}, '回移包文件集合不匹配')
    for relative, digest in data['files'].items():
        require(sha256(local_path(directory, relative)) == digest, '回移包文件摘要不匹配: ' + relative)
    for commit, metadata in data['commits'].items():
        require(data['files'].get('patches/' + commit + '.patch') == metadata['sha256'], '回移补丁记录不匹配')
    return directory


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        require(urllib.parse.urlparse(newurl).scheme == 'https', '拒绝非 HTTPS 下载跳转')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def archive_file(root, prefix):
    digest = digest_pin(prefix + '_SHA256')
    directory = local_path(root, 'work/cache/downloads/ci-dependencies')
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / (digest + '.tar')
    if archive.exists():
        require(not archive.is_symlink() and sha256(archive) == digest, '固定依赖归档摘要不匹配')
        return archive
    url = os.environ.get(prefix + '_URL', '')
    require(urllib.parse.urlparse(url).scheme == 'https', '固定依赖下载地址必须使用 HTTPS')
    descriptor, temporary = tempfile.mkstemp(prefix='.download-', dir=directory)
    try:
        opener = urllib.request.build_opener(HTTPSRedirect)
        started = time.monotonic()
        actual = hashlib.sha256()
        with os.fdopen(descriptor, 'wb') as output, opener.open(url, timeout=60) as response:
            while chunk := response.read(4 * 1024 * 1024):
                require(time.monotonic() - started < 600, '固定依赖下载超过十分钟')
                output.write(chunk)
                actual.update(chunk)
        require(actual.hexdigest() == digest, '下载依赖的 SHA-256 不匹配')
        os.rename(temporary, archive)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return archive


def extract_archive(archive, target, *, zstd=False):
    seen = set()

    def checked_member(member, destination):
        path = PurePosixPath(member.name)
        require(not path.is_absolute() and '..' not in path.parts and '\\' not in member.name,
                '依赖归档路径不安全')
        require(member.isfile() or member.isdir() or member.issym(), '依赖归档含不允许的文件类型')
        require(not member.mode & 0o7000, '依赖归档含特殊权限位')
        filtered = tarfile.data_filter(member, destination)
        if member.issym():
            link = Path(destination) / Path(member.name).parent / member.linkname
            require(link.resolve().is_relative_to(Path(destination).resolve()), '依赖归档链接越界')
            filtered.linkname = member.linkname
        else:
            filtered.mode = member.mode
        return filtered

    def unpack(bundle):
        for member in bundle:
            name = PurePosixPath(member.name).as_posix()
            require(name not in seen, '依赖归档有重复成员')
            seen.add(name)
            bundle.extract(member, target, filter=checked_member)
        for path in target.rglob('*'):
            if path.is_symlink():
                require(path.resolve().is_relative_to(target.resolve()), '依赖归档链接越界')

    if zstd:
        with archive.open('rb') as raw:
            process = subprocess.Popen(['zstd', '-q', '-d', '-c'], stdin=raw, stdout=subprocess.PIPE)
            try:
                with tarfile.open(fileobj=process.stdout, mode='r|') as bundle:
                    unpack(bundle)
                require(process.wait(timeout=30) == 0, '固定依赖解压失败')
            finally:
                process.stdout.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
    else:
        with tarfile.open(archive, 'r:*') as bundle:
            unpack(bundle)


def prepare_backports(root):
    expected = digest_pin('BACKPORT_BUNDLE_MANIFEST_SHA256')
    destination = local_path(root, 'work/cache/dependencies/backports-' + expected)
    if destination.exists():
        return checked_backports(root, destination)
    archive = archive_file(root, 'BACKPORT_BUNDLE')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.backports-', dir=destination.parent))
    try:
        extract_archive(archive, staging)
        checked_backports(root, staging)
        os.rename(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return destination


def prepare_toolchain(root):
    destination = toolchain_path(root)
    expected = digest_pin('CI_TOOLCHAIN_TREE_SHA256')
    if destination.exists():
        require(not destination.is_symlink() and tree_sha256(destination) == expected,
                '现有工具链内容与固定摘要不符，拒绝覆盖')
        return destination
    archive = archive_file(root, 'CI_TOOLCHAIN_BUNDLE')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.toolchain-', dir=destination.parent))
    try:
        extract_archive(archive, staging, zstd=True)
        require({path.name for path in staging.iterdir()} == {'payload', 'provenance.json'}, '工具链包成员错误')
        provenance = json.loads((staging / 'provenance.json').read_bytes())
        require(provenance.get('format') == FORMAT and provenance.get('kind') == 'toolchain', '工具链包格式不匹配')
        require(provenance.get('inputs') == {key: os.environ[key] for key in TOOLCHAIN_KEYS}, '工具链包来源身份不匹配')
        require(tree_sha256(staging / 'payload') == expected, '工具链包安装树摘要不匹配')
        os.rename(staging / 'payload', destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('backports-check', 'prepare-backports', 'prepare-toolchain'))
    parser.add_argument('--workspace', required=True, type=Path)
    args = parser.parse_args()
    root = args.workspace.resolve()
    if args.command == 'backports-check':
        print(checked_backports(root))
    elif args.command == 'prepare-backports':
        print(prepare_backports(root))
    elif args.command == 'prepare-toolchain':
        print(prepare_toolchain(root))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit('[FAIL] ' + str(error))
