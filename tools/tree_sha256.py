#!/usr/bin/env python3
"""Hash paths, file modes/content and symlink targets using the project format."""
import hashlib
import os
import pathlib
import stat
import sys


def fail(error):
    raise error


def tree_sha256(root):
    root = pathlib.Path(root)
    if not root.is_dir():
        raise ValueError('完整性校验目录不存在: ' + str(root))
    paths = []
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        paths.extend(pathlib.Path(directory) / name for name in files)
        paths.extend(pathlib.Path(directory) / name for name in dirs
                     if (pathlib.Path(directory) / name).is_symlink())
    result = hashlib.sha256()
    for path in sorted(paths, key=lambda item: os.fsencode(item.relative_to(root))):
        relative = os.fsencode(path.relative_to(root))
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            # Shell command substitution stripped trailing newlines in the
            # original format. Keep existing pins while rejecting ambiguity.
            target = os.fsencode(os.readlink(path))
            if target.endswith(b'\n'):
                raise ValueError('符号链接目标末尾含换行: ' + str(path))
            record = b'l\0' + relative + b'\0' + target + b'\0'
        elif stat.S_ISREG(mode):
            content = hashlib.sha256()
            with path.open('rb') as stream:
                while chunk := stream.read(4 * 1024 * 1024):
                    content.update(chunk)
            permissions = format(stat.S_IMODE(mode), 'o').encode()
            record = (b'f\0' + relative + b'\0' + permissions + b'\0'
                      + content.hexdigest().encode() + b'\0')
        else:
            raise ValueError('完整性校验目录含特殊文件: ' + str(path))
        result.update(record)
    return result.hexdigest()


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: tree_sha256.py DIRECTORY')
    print(tree_sha256(sys.argv[1]))
