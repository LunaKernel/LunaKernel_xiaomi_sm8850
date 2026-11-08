#!/usr/bin/env python3
"""Prepare and check the pinned official KernelSU Manager without building it."""
import argparse
import csv
import hashlib
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pins_from_environment():
    formats = {
        'KSU_COMMIT': r'[0-9a-f]{40}',
        'KSU_UAPI_VERSION': r'[1-9][0-9]*',
        'KSU_MANAGER_COMMIT': r'[0-9a-f]{40}',
        'KSU_MANAGER_RUN_ID': r'[1-9][0-9]*',
        'KSU_MANAGER_ARTIFACT_ID': r'[1-9][0-9]*',
        'KSU_MANAGER_ARCHIVE_SHA256': r'[0-9a-f]{64}',
        'KSU_MANAGER_APK_SHA256': r'[0-9a-f]{64}',
        'KSU_MANAGER_CERT_SHA256': r'[0-9a-f]{64}',
        'KSU_MANAGER_VERSION_CODE': r'[1-9][0-9]*',
        'KSU_MANAGER_UAPI_VERSION': r'[1-9][0-9]*',
        'KSU_MANAGER_CERT_SIZE': r'[1-9][0-9]*',
        'KSU_MANAGER_APK_NAME': r'KernelSU_[A-Za-z0-9.+-]+_[0-9]+-release\.apk',
    }
    pins = {}
    for name, pattern in formats.items():
        value = os.environ.get(name, '')
        require(re.fullmatch(pattern, value), 'missing or invalid exported pin: ' + name)
        pins[name.removeprefix('KSU_MANAGER_')] = value
    require(pins['KSU_UAPI_VERSION'] == pins['UAPI_VERSION'], 'kernel and Manager UAPI pins differ')
    require(pins['APK_NAME'].rsplit('_', 1)[1] == pins['VERSION_CODE'] + '-release.apk',
            'Manager filename and version code pins differ')
    return pins


def git(repo, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_NO_LAZY_FETCH='1', GIT_NO_REPLACE_OBJECTS='1',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-C', str(repo), *args],
                            env=env, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0,
            'local KSU Git object unavailable or invalid; run patches/init.sh: ' + result.stderr.strip())
    return result.stdout.strip()


def verify_sources(repo, pins):
    kernel, manager = pins['KSU_COMMIT'], pins['COMMIT']
    for commit in (kernel, manager):
        require(git(repo, 'cat-file', '-t', commit) == 'commit', 'KSU pin is not a commit')
    # kernel/include/uapi is a symlink; compare its actual root uapi tree too.
    paths = ('manager', 'userspace', 'uapi', 'kernel/include/uapi', 'Cargo.toml', 'Cargo.lock')
    for path in paths:
        require(git(repo, 'rev-parse', kernel + ':' + path) ==
                git(repo, 'rev-parse', manager + ':' + path),
                'Manager and kernel source mismatch: ' + path)
    for commit in (kernel, manager):
        header = git(repo, 'show', commit + ':uapi/supercall.h')
        version = re.search(r'KERNEL_SU_UAPI_VERSION\s*=\s*([0-9]+)\s*;', header)
        require(version and version[1] == pins['UAPI_VERSION'], 'KSU UAPI pin mismatch')
    gradle = git(repo, 'show', manager + ':manager/build.gradle.kts')
    sdk = re.search(r'extra\["androidMinSdkVersion"\]\s*=\s*([0-9]+)', gradle)
    require(sdk is not None, 'cannot determine fixed Manager minimum SDK')
    return int(sdk[1])


def number(data, offset, fmt='<I'):
    require(0 <= offset <= len(data) - struct.calcsize(fmt), 'binary field out of bounds')
    return struct.unpack_from(fmt, data, offset)[0]


def length_prefixed(data, offset=0):
    end = offset + 4 + number(data, offset)
    require(end <= len(data), 'length-prefixed field out of bounds')
    return data[offset + 4:end], end


def verify_certificate(data, pins):
    eocd = data.rfind(b'PK\x05\x06', max(0, len(data) - 65557))
    require(eocd >= 0 and eocd + 22 + number(data, eocd + 20, '<H') == len(data),
            'invalid APK end-of-central-directory record')
    cd = number(data, eocd + 16)
    require(cd + number(data, eocd + 12) == eocd and cd >= 32, 'invalid APK central directory')
    require(data[cd - 16:cd] == b'APK Sig Block 42', 'APK signing block missing')
    size = number(data, cd - 24, '<Q')
    start = cd - size - 8
    require(start >= 0 and number(data, start, '<Q') == size, 'APK signing block size mismatch')
    position, v2 = start + 8, None
    while position < cd - 24:
        size = number(data, position, '<Q')
        position += 8
        require(size >= 4 and position + size <= cd - 24, 'invalid APK signing pair')
        ident = number(data, position)
        require(ident in (0x7109871a, 0x42726577), 'signing block rejected by current KSU kernel')
        if ident == 0x7109871a:
            require(v2 is None, 'duplicate APK v2 signing block')
            v2 = data[position + 4:position + size]
        position += size
    require(position == cd - 24 and v2 is not None, 'APK v2 signing block missing')
    signers, end = length_prefixed(v2)
    require(end == len(v2), 'invalid APK v2 signer sequence')
    signer, _ = length_prefixed(signers)
    signed, _ = length_prefixed(signer)
    _, offset = length_prefixed(signed)
    certificates, _ = length_prefixed(signed, offset)
    certificate, _ = length_prefixed(certificates)
    require(len(certificate) == int(pins['CERT_SIZE']) and
            hashlib.sha256(certificate).hexdigest() == pins['CERT_SHA256'],
            'Manager signing certificate does not match the kernel pin')


def manifest_values(data):
    require(number(data, 0, '<H') == 3 and number(data, 4) == len(data), 'invalid binary manifest')
    position, strings, result = number(data, 2, '<H'), None, {}
    while position < len(data):
        kind = number(data, position, '<H')
        header, size = number(data, position + 2, '<H'), number(data, position + 4)
        require(size >= header >= 8 and position + size <= len(data), 'manifest chunk out of bounds')
        chunk = data[position:position + size]
        if kind == 1:
            count, flags, start = number(chunk, 8), number(chunk, 16), number(chunk, 20)
            require(header + count * 4 <= start <= size, 'invalid manifest string table')
            strings = []
            for index in range(count):
                offset = start + number(chunk, header + index * 4)
                utf8 = bool(flags & 0x100)
                def string_length(offset):
                    width, mask, fmt = (1, 0x80, '<B') if utf8 else (2, 0x8000, '<H')
                    value = number(chunk, offset, fmt)
                    offset += width
                    if value & mask:
                        value = ((value & (mask - 1)) << (width * 8)) | number(chunk, offset, fmt)
                        offset += width
                    return value, offset
                length, offset = string_length(offset)
                if utf8:
                    length, offset = string_length(offset)
                length *= 1 if utf8 else 2
                require(offset + length + (1 if utf8 else 2) <= size, 'manifest string out of bounds')
                strings.append(chunk[offset:offset + length].decode('utf-8' if utf8 else 'utf-16le'))
        elif kind == 0x102:
            require(strings is not None and header + 20 <= size, 'invalid manifest element')
            tag = strings[number(chunk, header + 4)]
            start, width, count = (number(chunk, header + offset, '<H') for offset in (8, 10, 12))
            require(width >= 20 and header + start + width * count <= size, 'manifest attributes out of bounds')
            attributes = {}
            for index in range(count):
                offset = header + start + index * width
                name, raw = number(chunk, offset + 4), number(chunk, offset + 8)
                value_type, value = number(chunk, offset + 15, '<B'), number(chunk, offset + 16)
                require(number(chunk, offset + 12, '<H') == 8, 'invalid manifest typed value')
                if raw != 0xffffffff:
                    value = strings[raw]
                elif value_type == 3:
                    value = strings[value]
                elif value_type == 0x12:
                    value = bool(value)
                attributes[strings[name]] = value
            if tag in ('manifest', 'uses-sdk', 'application'):
                require(tag not in result, 'duplicate manifest element: ' + tag)
                result[tag] = attributes
        position += size
    return result


def verify_elf(data, name):
    require(len(data) >= 64 and data[:6] == b'\x7fELF\x02\x01', name + ': not ELF64 little-endian')
    require(number(data, 18, '<H') == 183 and number(data, 16, '<H') in (2, 3),
            name + ': not an AArch64 executable/shared ELF')
    start, width, count = number(data, 32, '<Q'), number(data, 54, '<H'), number(data, 56, '<H')
    require(width >= 56 and count > 0 and start + width * count <= len(data), name + ': truncated ELF headers')
    for index in range(count):
        offset = start + width * index
        require(number(data, offset + 8, '<Q') + number(data, offset + 32, '<Q') <= len(data),
                name + ': truncated ELF segment')


def verify_apk(path, pins, minimum_sdk):
    require(path.is_file() and not path.is_symlink(), 'Manager APK missing or unsafe: ' + str(path))
    data = path.read_bytes()
    require(hashlib.sha256(data).hexdigest() == pins['APK_SHA256'], 'Manager APK SHA-256 mismatch: ' + str(path))
    # The fixed hash identifies the APK whose full v2 signature was verified at pin review.
    verify_certificate(data, pins)
    with zipfile.ZipFile(io.BytesIO(data)) as apk:
        require(len(apk.namelist()) == len(set(apk.namelist())), 'duplicate APK ZIP entries')
        require(apk.testzip() is None, 'APK ZIP integrity failure')
        manifest = manifest_values(apk.read('AndroidManifest.xml'))
        values = manifest['manifest']
        version_name = pins['APK_NAME'].removeprefix('KernelSU_').rsplit('_', 1)[0]
        require(values.get('package') == 'me.weishu.kernelsu', 'Manager package name mismatch')
        require(values.get('versionCode') == int(pins['VERSION_CODE']) and
                values.get('versionName') == version_name, 'Manager version mismatch')
        require(manifest['uses-sdk'].get('minSdkVersion') == minimum_sdk and minimum_sdk <= 37,
                'Manager minimum SDK does not match source or Android 17')
        require(not manifest.get('application', {}).get('debuggable', False), 'debuggable Manager APK')
        for name in ('libksud.so', 'libkernelsu.so'):
            verify_elf(apk.read('lib/arm64-v8a/' + name), name)


def verify_kernel_command(path, pins):
    require(path.is_file() and not path.is_symlink(), 'kernel command file missing or unsafe')
    commands = [line.split(' := ', 1)[1] for line in path.read_text().splitlines()
                if line.startswith(('savedcmd_', 'cmd_')) and ' := ' in line]
    require(len(commands) == 1, 'ambiguous kernel compiler command')
    definitions = {}
    tokens = iter(shlex.split(commands[0]))
    for token in tokens:
        if token in ('-D', '-U'):
            token += next(tokens)
        if token.startswith('-D'):
            name, _, value = token[2:].partition('=')
            definitions[name] = value.strip('"')
        elif token.startswith('-U'):
            definitions.pop(token[2:], None)
    require(definitions.get('EXPECTED_HASH') == pins['CERT_SHA256'] and
            int(definitions.get('EXPECTED_SIZE', '0'), 0) == int(pins['CERT_SIZE']) and
            definitions.get('KSU_PACKAGE_NAME') == 'me.weishu.kernelsu' and
            definitions.get('KSU_IS_PR_BUILD') == '0', 'actual kernel Manager identity does not match pins')


def safe_directory(path, workspace):
    require(path.is_relative_to(workspace), 'path outside workspace')
    for part in reversed((path, *path.parents)):
        if part == workspace or part.is_relative_to(workspace):
            require(not part.is_symlink(), 'symlink in Manager cache path: ' + str(part))
            if part.exists():
                require(part.is_dir(), 'Manager cache path is not a directory: ' + str(part))
            else:
                part.mkdir()


def curl(url, output=None, limit=2 * 1024 * 1024):
    seconds = 180 if output else 30
    command = ['curl', '-q', '--proto', '=https', '--proto-redir', '=https',
               '--fail', '--silent', '--show-error', '--location', '--connect-timeout', '15',
               '--max-time', str(seconds), '--max-filesize', str(limit)]
    if output:
        command += ['--output', str(output)]
    result = subprocess.run(command + [url], capture_output=True, timeout=seconds + 10)
    require(result.returncode == 0, 'official Manager download failed: ' + result.stderr.decode(errors='replace').strip())
    return result.stdout


def download_apk(directory, pins):
    api = 'https://api.github.com/repos/tiann/KernelSU/actions/'
    artifact = json.loads(curl(api + 'artifacts/' + pins['ARTIFACT_ID']))
    run = json.loads(curl(api + 'runs/' + pins['RUN_ID']))
    identity = artifact.get('workflow_run', {})
    require(artifact.get('id') == int(pins['ARTIFACT_ID']) and artifact.get('name') == 'manager' and
            artifact.get('expired') is False and artifact.get('digest') == 'sha256:' + pins['ARCHIVE_SHA256'],
            'official Manager artifact identity, digest or expiry mismatch')
    require(run.get('id') == int(pins['RUN_ID']) and run.get('head_sha') == pins['COMMIT'] and
            run.get('head_branch') == 'main' and identity.get('head_branch') == 'main' and
            run.get('status') == 'completed' and run.get('conclusion') == 'success' and
            run.get('repository', {}).get('full_name') == 'tiann/KernelSU' and
            run.get('head_repository', {}).get('full_name') == 'tiann/KernelSU' and
            identity.get('id') == run['id'] and identity.get('head_sha') == pins['COMMIT'] and
            identity.get('repository_id') == run['repository']['id'] and
            identity.get('head_repository_id') == run['head_repository']['id'],
            'official Manager CI run/source mismatch')
    size = artifact.get('size_in_bytes')
    require(isinstance(size, int) and size > 0, 'invalid artifact size')
    archive = directory / 'manager.zip'
    curl('https://nightly.link/tiann/KernelSU/actions/artifacts/' + pins['ARTIFACT_ID'] + '.zip', archive, size)
    require(archive.stat().st_size == size and hashlib.sha256(archive.read_bytes()).hexdigest() == pins['ARCHIVE_SHA256'],
            'official Manager archive SHA-256 or size mismatch')
    with zipfile.ZipFile(archive) as bundle:
        candidates = []
        for item in bundle.infolist():
            name = pathlib.PurePosixPath(item.filename)
            require(not name.is_absolute() and '..' not in name.parts and '\\' not in item.filename and
                    not stat.S_ISLNK(item.external_attr >> 16), 'unsafe Manager archive member')
            if name.suffix == '.apk':
                candidates.append(item)
        require(len(candidates) == 1 and pathlib.PurePosixPath(candidates[0].filename).name == pins['APK_NAME'],
                'official artifact does not contain exactly the pinned Manager APK')
        target = directory / pins['APK_NAME']
        target.write_bytes(bundle.read(candidates[0]))
    return target


def prepare(workspace, cached, pins, minimum_sdk):
    if cached.exists() or cached.is_symlink():
        return
    safe_directory(cached.parent, workspace)
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=cached.parent) as directory:
        directory = pathlib.Path(directory)
        candidate = None
        outputs = workspace / 'kernel_out'
        require(not outputs.is_symlink(), 'kernel_out must not be a symlink')
        if outputs.is_dir():
            for build in sorted(outputs.iterdir(), reverse=True):
                if not re.fullmatch(r'luna-xiaomi17-g[0-9a-f]{8}-[0-9]{8}-[0-9]{4}', build.name):
                    continue
                if build.is_dir() and not build.is_symlink():
                    source = build / pins['APK_NAME']
                    if source.is_file() and not source.is_symlink() and hashlib.sha256(source.read_bytes()).hexdigest() == pins['APK_SHA256']:
                        candidate = directory / pins['APK_NAME']
                        shutil.copyfile(source, candidate)
                        print('Reusing delivered official Manager APK', file=sys.stderr)
                        break
        if candidate is None:
            print('Downloading fixed official Manager CI artifact', file=sys.stderr)
            candidate = download_apk(directory, pins)
        verify_apk(candidate, pins, minimum_sdk)
        candidate.chmod(0o644)
        os.link(candidate, cached)  # Exclusive publication; never replace an existing cache file.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'check'))
    parser.add_argument('--workspace', required=True, type=pathlib.Path)
    parser.add_argument('--ksu-dir', required=True, type=pathlib.Path)
    parser.add_argument('--kernel-command', type=pathlib.Path)
    parser.add_argument('--audit', type=pathlib.Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve(strict=True)
    repo = args.ksu_dir if args.ksu_dir.is_absolute() else workspace / args.ksu_dir
    pins = pins_from_environment()
    minimum_sdk = verify_sources(repo, pins)
    cached = workspace / 'work/cache/ksu-manager' / pins['COMMIT'] / pins['APK_NAME']
    # check is strictly read-only unless its caller requests an audit record.
    for path in (cached.parent, *cached.parent.parents):
        if path.is_relative_to(workspace):
            require(not path.is_symlink(), 'symlink in Manager cache path: ' + str(path))
    if args.command == 'prepare':
        prepare(workspace, cached, pins, minimum_sdk)
    verify_apk(cached, pins, minimum_sdk)
    if args.kernel_command:
        verify_kernel_command(args.kernel_command, pins)
    if args.audit:
        with args.audit.open('x', newline='') as stream:
            writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
            writer.writerow(['key', 'value'])
            writer.writerows(sorted(pins.items()))
            writer.writerows([['source_subtrees', 'matched'], ['minimum_sdk', minimum_sdk],
                             ['apk_checks', 'sha256,certificate,manifest,zip,arm64-elf'],
                             ['kernel_command', str(args.kernel_command) if args.kernel_command else 'not-requested']])
    print(cached)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError, StopIteration, struct.error,
            subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('KernelSU Manager: ' + str(error), file=sys.stderr)
        sys.exit(1)
