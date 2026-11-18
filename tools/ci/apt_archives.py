#!/usr/bin/env python3
"""从本机 APT 安装计划提取归档身份，并只复制经过校验的普通文件。"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


def package_plan(lines):
    packages = {}
    for line in lines:
        if not line.startswith("'"):
            continue
        match = re.fullmatch(r"'[^\x00'\r\n]+' ([A-Za-z0-9][A-Za-z0-9_.+%~-]*\.deb) ([1-9][0-9]*) SHA256:([0-9a-f]{64})\n?", line)
        if not match or match[1] in packages:
            raise ValueError('APT 安装计划缺少有效且唯一的归档身份')
        packages[match[1]] = (int(match[2]), match[3])
    return packages


def copy_verified(packages, source, target):
    # APT 对已有归档只核对大小；必须验证实际送入安装目录的字节。
    if source.is_symlink() or not source.is_dir():
        return 0
    if target.is_symlink() or not target.is_dir():
        raise ValueError('APT 归档目标目录无效')
    count = 0
    for name, (size, digest) in packages.items():
        try:
            with os.fdopen(os.open(source / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size != size:
                    continue
                data = stream.read(size + 1)
        except OSError:
            continue
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            continue
        with (target / name).open('xb') as stream:
            stream.write(data)
        count += 1
    return count


def main():
    mode, plan, *paths = sys.argv[1:]
    plan = Path(plan)
    if mode == 'plan':
        packages = package_plan(sys.stdin)
        if packages:
            data = json.dumps(packages, sort_keys=True).encode()
            plan.write_bytes(data)
            print('luna-apt-debs-v1-ubuntu24-amd64-' + hashlib.sha256(data).hexdigest())
    else:
        if mode not in ('copy', 'publish') or len(paths) != 2:
            raise ValueError('未知 APT 归档操作')
        packages = json.loads(plan.read_bytes())
        count = copy_verified(packages, *map(Path, paths))
        if mode == 'publish' and count != len(packages):
            raise ValueError('未保留完整 APT 归档集合，不保存缓存')
        print(count)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit('[INFO] ' + str(error))
