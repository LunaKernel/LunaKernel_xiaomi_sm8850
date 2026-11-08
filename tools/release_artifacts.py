#!/usr/bin/env python3
"""Verify, transfer and rotate Luna build records."""

import argparse
import datetime
import hashlib
import re
import shutil
import tarfile
import tempfile
from pathlib import Path


BUILD_ID = re.compile(r"luna-xiaomi17-g([0-9a-f]{8})-([0-9]{8})-([0-9]{4})")
RECORD = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)")


def release_directories(build_id):
    match = BUILD_ID.fullmatch(build_id)
    if not match:
        raise ValueError("非法构建目录名: " + build_id)
    datetime.datetime.strptime(match[2] + match[3], "%Y%m%d%H%M")
    return ["kernel_out/" + build_id, "work/audit/" + build_id,
            "work/components/" + build_id]


def checked_path(root, relative):
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("非法相对路径: " + relative)
    path = root
    for part in parts:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", part):
            raise ValueError("非法路径分量: " + relative)
        path = path / part
        if path.is_symlink():
            raise ValueError("路径不得经过符号链接: " + relative)
    return path


def allowed_file(relative, directories):
    return any(relative.startswith(directory + "/") and
               "/" not in relative[len(directory) + 1:]
               for directory in directories)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prune_work_history(root, keep):
    if keep < 1:
        raise ValueError("工作记录保留份数必须大于零")
    groups = {}
    for relative in ("work/audit", "work/components"):
        parent = checked_path(root, relative)
        if not parent.exists():
            continue
        if not parent.is_dir():
            raise ValueError("工作记录路径不是目录: " + relative)
        for entry in parent.iterdir():
            build = BUILD_ID.fullmatch(entry.name)
            if not build:
                # Only rotate known project output names, never arbitrary directories.
                continue
            timestamp = datetime.datetime.strptime(build[2] + build[3], "%Y%m%d%H%M")
            path = checked_path(root, relative + "/" + entry.name)
            if not path.is_dir():
                raise ValueError("工作记录不是普通目录: " + str(path))
            groups.setdefault(relative, []).append((timestamp, entry.name, path))
    # Validate every family before deleting anything; commit hashes and archive
    # mtimes are not chronological build identities.
    removals = []
    for entries in groups.values():
        removals.extend(path for _, _, path in sorted(entries, reverse=True)[keep:])
    for path in removals:
        checked_path(root, path.relative_to(root).as_posix())
        shutil.rmtree(path)
        print("[CLEAN] " + path.relative_to(root).as_posix())
    return len(removals)


def verify(root, build_id):
    directories = release_directories(build_id)
    manifest_name = directories[1] + "/.build-artifacts"
    manifest = checked_path(root, manifest_name)
    if not manifest.is_file():
        raise ValueError("当前构建产物清单缺失: " + manifest_name)
    records = {}
    for line in manifest.read_text().splitlines():
        match = RECORD.fullmatch(line)
        if not match:
            raise ValueError("非法产物摘要记录: " + line)
        digest, relative = match.groups()
        if (not allowed_file(relative, directories) or relative in records or
                Path(relative).name in (".build-artifacts", "release.tsv")):
            raise ValueError("非法或重复产物路径: " + relative)
        path = checked_path(root, relative)
        if not path.is_file() or sha256(path) != digest:
            raise ValueError("产物缺失或摘要不匹配: " + relative)
        records[relative] = digest
    match = BUILD_ID.fullmatch(build_id)
    stem = "luna-xiaomi17-g" + match[1] + "-" + match[2]
    required = {directories[0] + "/Image-" + stem,
                directories[0] + "/" + stem + ".zip",
                directories[1] + "/" + stem + "-audit.zip"}
    if not required <= records.keys():
        raise ValueError("发布清单缺少 Image、刷机包或完整审计归档")
    state_name = directories[1] + "/release.tsv"
    state_path = checked_path(root, state_name)
    if not state_path.is_file():
        raise ValueError("发布状态缺失: " + state_name)
    lines = state_path.read_text().splitlines()
    if not lines or lines[0] != "field\tvalue":
        raise ValueError("发布状态格式错误")
    state = {}
    for line in lines[1:]:
        key, value = line.split("\t", 1)
        if key in state:
            raise ValueError("发布状态字段重复: " + key)
        state[key] = value
    commit = state.get("project_commit", "")
    if (state.get("build_id") != build_id or
            not re.fullmatch(r"[0-9a-f]{40}", commit) or commit[:8] != match[1] or
            state.get("validation_status") not in ("accepted", "awaiting-device")):
        raise ValueError("发布身份或验收状态错误")
    if "ksu_manager_apk" in state:
        manager = state["ksu_manager_apk"]
        if not re.fullmatch(r"KernelSU_[A-Za-z0-9][A-Za-z0-9._-]*\.apk", manager):
            raise ValueError("非法 KernelSU Manager APK 文件名: " + manager)
        manager_path = directories[0] + "/" + manager
        if manager_path not in records:
            raise ValueError("发布清单缺少 KernelSU Manager APK")
        required.add(manager_path)
    kernel_files = {name for name in records if name.startswith(directories[0] + "/")}
    if kernel_files != {name for name in required if name.startswith(directories[0] + "/")}:
        raise ValueError("kernel_out 含未声明的交付文件")
    actual_kernel_files = {path.name for path in checked_path(root, directories[0]).iterdir()}
    if actual_kernel_files != {Path(name).name for name in kernel_files}:
        raise ValueError("内核产物目录含清单外文件")
    # The manifest is the completion marker and must be copied last.
    return list(records) + [state_name, manifest_name]


def copy_release(source, target, build_id):
    names = verify(source, build_id)
    for relative in release_directories(build_id):
        if checked_path(target, relative).exists():
            raise ValueError("拒绝覆盖已有发布目录: " + relative)
    marker = checked_path(target, "work/audit/" + build_id + "/.build-artifacts")
    try:
        for relative in names:
            destination = checked_path(target, relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(checked_path(source, relative), destination)
        verify(target, build_id)
    except Exception:
        marker.unlink(missing_ok=True)
        raise


def import_archive(archive, target, build_id):
    directories = release_directories(build_id)
    parent = checked_path(target, "work/tmp")
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="release-import.", dir=parent) as staging:
        staging = Path(staging)
        files = set()
        seen = set()
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            # Reject links, special files and traversal before writing anything.
            for member in members:
                name = member.name.rstrip("/")
                checked_path(staging, name)
                if name in seen:
                    raise ValueError("归档路径重复: " + name)
                seen.add(name)
                if member.isdir():
                    if not any(directory == name or directory.startswith(name + "/")
                               for directory in directories):
                        raise ValueError("归档目录不属于本次发布: " + name)
                elif member.isfile() and allowed_file(name, directories):
                    files.add(name)
                else:
                    raise ValueError("归档含链接、特殊文件或清单外路径: " + name)
            for member in members:
                if member.isfile():
                    destination = checked_path(staging, member.name)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.extractfile(member) as source, destination.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    destination.chmod(member.mode & 0o777)
        names = verify(staging, build_id)
        if files != set(names):
            raise ValueError("归档包含清单外文件")
        copy_release(staging, target, build_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    child = commands.add_parser("check")
    child.add_argument("workspace", type=Path)
    child.add_argument("build_id")
    child = commands.add_parser("prune-work")
    child.add_argument("workspace", type=Path)
    child.add_argument("--keep", type=int, required=True)
    args = parser.parse_args()
    try:
        workspace = args.workspace.resolve(strict=True)
        if args.command == "prune-work":
            removed = prune_work_history(workspace, args.keep)
            print(f"[OK] 工作审计与组件按类别保留最新 {args.keep} 份，清理 {removed} 个旧目录")
            return
        verify(workspace, args.build_id)
    except (OSError, ValueError, tarfile.TarError) as error:
        raise SystemExit("[FAIL] " + str(error))
    print("[OK] 发布产物身份、相对路径和摘要校验通过: " + args.build_id)


if __name__ == "__main__":
    main()
