#!/usr/bin/env python3
"""Rebuild Xiaomi 17 HyperOS 4 / Android 17 stock-module KMI evidence."""

import argparse
import hashlib
import os
import re
import struct
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path, PurePosixPath


BOOT_SHA256 = "af83b83f63ae833b05d69b87b8e216c3a0bace798699080e799cd8fff344248b"
BOOT_KERNEL_SHA256 = "574006dc475adc70dac65ec8cf8fcbbf0b18b0c31584a84702257788964c8ec2"
VENDOR_BOOT_SHA256 = "54a2e92fadcd28dd77a90aaf6fdb61e920f6f4913bb7597cedf0714350dee4c7"
VENDOR_RAMDISK_SHA256 = "d283d7a22a71bdaad22fa8f57dba4ceff0562fdbcea38574323908349702d020"
VENDOR_DTB_SHA256 = "0182b665c5e611eb1db3febff0fb503738c454ed77eb18d64daab8d6cd555876"
VENDOR_DTB_SIZE = 6_557_303
VENDOR_DLKM_SHA256 = "fc29237d2be2be5fca809d05fa735d1120493b9c0f85d70ed8a6fe286dee5b74"
SYSTEM_DLKM_SHA256 = "7918f34b6ae9210b8470abbe1ee52f2fc72da04bfa241627ab0c66f340ab9816"
SYSTEM_DLKM_SIZE = 17_281_024
STOCK_RELEASE = "6.12.69-android16-6-gb1493ec68d4a-abogki514973465-4k"
STOCK_VERMAGIC = "6.12.69-android16-6-4k SMP preempt mod_unload modversions aarch64"
STOCK_SYSTEM_VERMAGIC = f"{STOCK_RELEASE} SMP preempt mod_unload modversions aarch64"
STOCK_IKCONFIG_LINES = 8162
STOCK_IKCONFIG_SHA256 = "eab5ce89b3ef0bc5556d54b73569ddc95bc5d1228ab6460afad4ad398dda94ac"
STOCK_PROVIDER_SUMMARY = "NETFS_SUPPORT=m RFKILL=m CRYPTO_LIB_ARC4=m CIFS=n BLK_WBT_MQ=y"
VENDOR_BOOTCONFIG_SHA256 = "bad92331bd65be0207c84a855cb0b9580a504acd89684e3222007b20b683805f"

SYSTEM_BUILD_PROP_SHA256 = "ea28f88efe59ec6d674fbf674066096c76163ef496c63fb1f5c5099142bc996f"
SYSTEM_BUILD_FINGERPRINT = (
    "Xiaomi/pudding/pudding:16/BQ2A.260225.001-BP2A.250705.008/"
    "OS4.0.0.8.XPCCN:user/release-keys"
)
SYSTEM_MODULES_ORDER_SHA256 = "5a1d93ff892637622f8c85ed8f6527868c03ddf734e724dce7bbd24db1dd96de"
SYSTEM_NORMALIZED_MODULES_ORDER_SHA256 = (
    "23542e351835f1dca3b80cbaa975f86d7144a32c329d42efa7b502a8ca5033fb"
)
SYSTEM_MODULES_LOAD_SHA256 = "c4eb311fd8a040a6add5dce16c8b7ab332c7e3263aed45205c496d51b0b7b3fa"
SYSTEM_MODULES_DEP_SHA256 = "4f5a8fce2d09734963345dd46a7404166fd7916ab78289014e276e0a75d19e81"

RUST_BINDER_MODULE = "rust_binder.ko"
RUST_BINDER_SHA256 = "95c081b5718657f2411d7e644b5dc9dea6b952ef3b4a7bb55fc35c7568922154"
RUST_BINDER_REQUIREMENTS = 234
RUST_BINDER_REQUIREMENTS_SHA256 = (
    "e268bb37f03f15b038a81640de1cefdaa77f3339a79d9a4cbf04a4ae88d746bb"
)
RUST_BINDER_MATCHING_VMLINUX = 167
RUST_BINDER_MISSING = 67
RUST_BINDER_MISSING_SHA256 = (
    "d818ef38463e2942d19c1a4b27c7e14f90ec858b4f5266a13099ab41b8b3e3d4"
)

COMMON_TAG = "android16-6.12-2026-06_r8"
COMMON_COMMIT = "82a2ca6cbee492b7812547877238bc89e4968da4"
QCOM_SYMBOL_LIST_SHA256 = "b2f04ad0a4f6cae89c159f5fb9ce2c853ed83aebcf389c30ada575b5effade73"
XIAOMI_SYMBOL_LIST_SHA256 = "207cc3d776ab6201a5180d33b60134c12fb314a987aad4fd710742b08dc5c3a6"

FSCK_EROFS_SHA256 = "8e2308fa022c6d20e7ca6ac59634a0755f73269e8614ee0a288749929e111bae"
KMOD_SHA256 = "f2a05ab58cd6ff5a3fd05d24895a2971af831ae7789fd2f1ac10203ae4958c1c"
UNPACK_BOOTIMG_SHA256 = "06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e"
BSDTAR_SHA256 = "3d4f952dc8b77a993fa28355ce4eb402aea1966d1c85d60bbe1db76a3a4e0afc"
EXTRACT_IKCONFIG_SHA256 = "070020a9c5a0b9e6f7e24f5728073e8e62155be49133a9f3f37e8fc19230a9b1"

EXPECTED_VENDOR_DLKM_MODULES = 404
EXPECTED_VENDOR_BOOT_MODULES = 466
EXPECTED_IDENTICAL_OVERLAP = 295
EXPECTED_UNION_MODULES = 575
EXPECTED_REQUIREMENT_RECORDS = 33146
EXPECTED_REQUIREMENTS = 5672
EXPECTED_EXPORTS = 4364
EXPECTED_VENDOR_PROVIDED = 2264
EXPECTED_VENDOR_COMMON_REQUIRED = 3408
EXPECTED_VENDOR_COMMON_SHA256 = "ed614c4a7d72bb3ca09aed633f9fb41d96548033ead1dc0164e48fb396d49e72"

EXPECTED_SYSTEM_MODULES = 103
EXPECTED_SYSTEM_LOADED_MODULES = 82
EXPECTED_SYSTEM_REQUIREMENT_RECORDS = 5816
EXPECTED_SYSTEM_REQUIREMENTS = 1978
EXPECTED_SYSTEM_EXPORTS = 481
EXPECTED_SYSTEM_HARD_REQUIREMENT_RECORDS = 5582
EXPECTED_SYSTEM_HARD_REQUIREMENTS = 1839
EXPECTED_SYSTEM_PROVIDED = 296
EXPECTED_SYSTEM_COMMON_REQUIRED = 1543
EXPECTED_SYSTEM_COMMON_SHA256 = "669bcb5efed2e5b33dfb698fb8db9ff81bbfa4f6acab61b14ced076fc120a139"
EXPECTED_COMBINED_MODULES = 678
EXPECTED_COMBINED_REQUIREMENT_RECORDS = 38728
EXPECTED_COMBINED_EXPORTS = 4834
EXPECTED_DOMAIN_COMMON_REQUIRED = 4093
EXPECTED_CROSS_DOMAIN_PROVIDED = 10
EXPECTED_CROSS_DOMAIN_PROVIDED_SHA256 = (
    "0a5777e0cfedfbeec87bc83116431110316e03d06b97b22800a7d3c10faf1c4c"
)
EXPECTED_CROSS_DOMAIN_MODULE_NAMES = frozenset({"zram", "zsmalloc"})
EXPECTED_COMBINED_COMMON_REQUIRED = 4083
EXPECTED_COMBINED_OFFICIAL_SUBSET = 3440

SAFE_ENV = {
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_KEY_0": "core.hooksPath",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_VALUE_0": "/dev/null",
    "GIT_NO_LAZY_FETCH": "1",
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_PAGER": "cat",
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
}
RECORD_RE = re.compile(r"^(0x[0-9a-f]{8})\t([!-~]+)$")
MODULE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
SYMBOL_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def die(message: str) -> None:
    raise SystemExit(f"error: {message}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checked_file(path: Path, expected: str, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        die(f"missing or unsafe {label}: {path}")
    actual = sha256_file(path)
    if actual != expected:
        die(f"{label} SHA-256 mismatch: {actual} != {expected}")


def run(argv: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        check=False,
        capture_output=True,
        text=True,
        encoding="ascii",
        errors="strict",
        env=SAFE_ENV,
    )
    if check and result.returncode:
        detail = (result.stdout + result.stderr).strip()
        die(f"command failed ({result.returncode}): {argv[0]}: {detail}")
    return result


def parse_boot_image(path: Path) -> str:
    data = path.read_bytes()
    if len(data) < 4096 or data[:8] != b"ANDROID!":
        die("boot.img is not an Android boot image")
    kernel_size, ramdisk_size, _, header_size = struct.unpack_from("<IIII", data, 8)
    header_version = struct.unpack_from("<I", data, 40)[0]
    if (header_version, header_size, ramdisk_size) != (4, 1584, 0):
        die("unexpected boot.img v4 header")
    kernel_end = 4096 + kernel_size
    if kernel_end > len(data):
        die("boot kernel exceeds boot.img")
    kernel = data[4096:kernel_end]
    digest = hashlib.sha256(kernel).hexdigest()
    if digest != BOOT_KERNEL_SHA256:
        die(f"boot kernel SHA-256 mismatch: {digest}")
    releases = {
        value.decode("ascii")
        for value in re.findall(rb"Linux version ([^ \x00]+) ", kernel)
    }
    if releases != {STOCK_RELEASE}:
        die(f"unexpected stock release set: {sorted(releases)}")
    return digest


def vendor_boot_cmdline(path: Path) -> str:
    data = path.read_bytes()
    if len(data) < 4096 or data[:8] != b"VNDRBOOT":
        die("vendor_boot.img is not an Android vendor boot image")
    header_version = struct.unpack_from("<I", data, 8)[0]
    if header_version != 4:
        die(f"unexpected vendor_boot header version: {header_version}")
    raw = data[28 : 28 + 2048]
    command_line, separator, padding = raw.partition(b"\0")
    if not separator or padding.strip(b"\0"):
        die("malformed vendor_boot command line")
    try:
        return command_line.decode("ascii")
    except UnicodeDecodeError:
        die("vendor_boot command line is not ASCII")


def official_symbols(repo: Path, path: str, expected_sha256: str) -> set[str]:
    content = run(["git", "-C", str(repo), "show", f"{COMMON_COMMIT}:{path}"]).stdout
    actual_sha256 = hashlib.sha256(content.encode("ascii")).hexdigest()
    if actual_sha256 != expected_sha256:
        die(f"{path} SHA-256 mismatch: {actual_sha256}")
    symbols = set()
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if not RECORD_RE.fullmatch(f"0x00000000\t{line}"):
            die(f"invalid official symbol-list entry: {line!r}")
        symbols.add(line)
    return symbols


def verify_stock_ikconfig(extractor: Path, boot_image: Path) -> None:
    config = run([str(extractor), str(boot_image)]).stdout
    lines = config.splitlines()
    digest = hashlib.sha256(config.encode("ascii")).hexdigest()
    if len(lines) != STOCK_IKCONFIG_LINES or digest != STOCK_IKCONFIG_SHA256:
        die(f"stock IKCONFIG mismatch: lines={len(lines)} sha256={digest}")
    expected = {
        "CONFIG_NETFS_SUPPORT=m",
        "CONFIG_RFKILL=m",
        "CONFIG_CRYPTO_LIB_ARC4=m",
        "# CONFIG_CIFS is not set",
        "CONFIG_BLK_WBT_MQ=y",
        "CONFIG_ANDROID_BINDER_IPC=y",
        "CONFIG_ANDROID_BINDERFS=y",
        "CONFIG_ANDROID_BINDER_IPC_RUST=m",
    }
    if not expected <= set(lines):
        die("stock IKCONFIG provider or Binder configuration changed")


def module_files(root: Path, expected_count: int, label: str) -> dict[str, Path]:
    module_root = root / "lib/modules"
    if not module_root.is_dir() or module_root.is_symlink():
        die(f"{label} is missing lib/modules")
    if any(path.is_symlink() for path in module_root.rglob("*")):
        die(f"{label} lib/modules contains a symlink")
    paths = sorted(module_root.rglob("*.ko"), key=lambda path: path.as_posix())
    if len(paths) != expected_count or any(path.parent != module_root for path in paths):
        die(f"unexpected {label} module layout/count: {len(paths)}")
    modules = {path.name: path for path in paths}
    if len(modules) != len(paths):
        die(f"{label} contains duplicate module basenames")
    return modules


def section_data(data: bytes, section: tuple[int, int, int], label: str) -> bytes:
    section_type, offset, size = section
    if section_type != 1:
        die(f"{label} is not an ELF PROGBITS section")
    if offset > len(data) or size > len(data) - offset:
        die(f"{label} exceeds its ELF file")
    return data[offset : offset + size]


def elf_sections(path: Path) -> dict[str, tuple[int, int, int]]:
    data = path.read_bytes()
    if len(data) < 64:
        die(f"truncated ELF module: {path.name}")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    ident = header[0]
    if ident[:7] != b"\x7fELF\x02\x01\x01" or ident[7:] != b"\0" * 9:
        die(f"unexpected ELF identity: {path.name}")
    (
        elf_type,
        machine,
        version,
        _entry,
        _program_offset,
        section_offset,
        _flags,
        header_size,
        _program_entry_size,
        _program_count,
        section_entry_size,
        section_count,
        string_index,
    ) = header[1:]
    if (elf_type, machine, version, header_size, section_entry_size) != (1, 183, 1, 64, 64):
        die(f"unexpected ELF64/AArch64 module header: {path.name}")
    if not section_count or string_index >= section_count:
        die(f"unsupported ELF section numbering: {path.name}")
    if section_offset > len(data) or section_count > (len(data) - section_offset) // 64:
        die(f"ELF section table exceeds module: {path.name}")

    raw_sections = []
    for index in range(section_count):
        raw = struct.unpack_from("<IIQQQQIIQQ", data, section_offset + index * 64)
        raw_sections.append(raw)
    string_section = raw_sections[string_index]
    if string_section[1] != 3:
        die(f"ELF section-name table is not STRTAB: {path.name}")
    names_offset, names_size = string_section[4], string_section[5]
    if names_offset > len(data) or names_size > len(data) - names_offset:
        die(f"ELF section-name table exceeds module: {path.name}")
    names = data[names_offset : names_offset + names_size]

    wanted = {"__versions", "__version_ext_crcs", "__version_ext_names"}
    result: dict[str, tuple[int, int, int]] = {}
    for raw in raw_sections:
        name_offset = raw[0]
        if name_offset >= len(names):
            die(f"ELF section name exceeds string table: {path.name}")
        name_end = names.find(b"\0", name_offset)
        if name_end < 0:
            die(f"unterminated ELF section name: {path.name}")
        try:
            name = names[name_offset:name_end].decode("ascii")
        except UnicodeDecodeError:
            die(f"non-ASCII ELF section name: {path.name}")
        if name not in wanted:
            continue
        if name in result:
            die(f"duplicate ELF section {name}: {path.name}")
        if raw[2] & 0x800:
            die(f"compressed modversion section {name}: {path.name}")
        result[name] = (raw[1], raw[4], raw[5])
    return result


def parse_basic_modversions(data: bytes, path: Path) -> list[tuple[str, int]]:
    record_size = 64
    if len(data) % record_size:
        die(f"malformed __versions size: {path.name}")
    records = []
    for offset in range(0, len(data), record_size):
        crc = struct.unpack_from("<Q", data, offset)[0]
        if crc > 0xFFFFFFFF:
            die(f"non-u32 basic modversion CRC: {path.name}")
        raw_name = data[offset + 8 : offset + record_size]
        name, separator, padding = raw_name.partition(b"\0")
        if not separator or padding.strip(b"\0"):
            die(f"malformed basic modversion name: {path.name}")
        try:
            symbol = name.decode("ascii")
        except UnicodeDecodeError:
            die(f"non-ASCII basic modversion name: {path.name}")
        if not SYMBOL_NAME_RE.fullmatch(symbol):
            die(f"invalid basic modversion symbol: {path.name}: {symbol!r}")
        records.append((symbol, crc))
    return records


def parse_extended_modversions(
    crc_data: bytes, name_data: bytes, path: Path
) -> list[tuple[str, int]]:
    if len(crc_data) % 4:
        die(f"malformed __version_ext_crcs size: {path.name}")
    crcs = struct.unpack(f"<{len(crc_data) // 4}I", crc_data)
    records = []
    offset = 0
    for crc in crcs:
        end = name_data.find(b"\0", offset)
        if end < 0:
            die(f"fewer extended names than CRCs: {path.name}")
        try:
            symbol = name_data[offset:end].decode("ascii")
        except UnicodeDecodeError:
            die(f"non-ASCII extended modversion name: {path.name}")
        if not SYMBOL_NAME_RE.fullmatch(symbol):
            die(f"invalid extended modversion symbol: {path.name}: {symbol!r}")
        records.append((symbol, crc))
        offset = end + 1
    # modpost emits an explicit NUL per name plus the C string's final NUL.
    if name_data[offset:] != b"\0":
        die(f"unexpected trailing extended modversion names: {path.name}")
    return records


def module_import_records(path: Path) -> list[tuple[str, int]]:
    data = path.read_bytes()
    sections = elf_sections(path)
    basic_section = sections.get("__versions")
    crc_section = sections.get("__version_ext_crcs")
    name_section = sections.get("__version_ext_names")
    if (crc_section is None) != (name_section is None):
        die(f"unpaired extended modversion sections: {path.name}")
    basic = (
        parse_basic_modversions(section_data(data, basic_section, "__versions"), path)
        if basic_section is not None
        else []
    )
    if crc_section is None:
        if not basic_section:
            die(f"module has no modversion records: {path.name}")
        records = basic
    else:
        records = parse_extended_modversions(
            section_data(data, crc_section, "__version_ext_crcs"),
            section_data(data, name_section, "__version_ext_names"),
            path,
        )
        expected_basic = [record for record in records if len(record[0]) < 56]
        if basic != expected_basic:
            die(f"basic/extended modversion tables disagree: {path.name}")
    if len({symbol for symbol, _ in records}) != len(records):
        die(f"duplicate imported symbol in module: {path.name}")
    return records


def parse_modules_dep(root: Path, modules: set[str], label: str) -> dict[str, set[str]]:
    path = root / "lib/modules/modules.dep"
    if not path.is_file() or path.is_symlink():
        die(f"{label} is missing modules.dep")
    dependencies: dict[str, set[str]] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        left, separator, right = line.partition(":")
        if not separator:
            die(f"malformed {label} modules.dep")
        module = PurePosixPath(left).name
        if module in dependencies:
            die(f"duplicate {label} modules.dep entry: {module}")
        dependencies[module] = {PurePosixPath(value).name for value in right.split()}
    if set(dependencies) != modules:
        die(f"{label} modules.dep does not cover its exact module set")
    unknown = set().union(*dependencies.values()) - modules
    if unknown:
        die(f"{label} modules.dep names missing modules: {sorted(unknown)}")
    return dependencies


def checked_load_file(
    root: Path,
    filename: str,
    modules: set[str],
    expected_lines: int,
    expected_unique: int,
) -> list[str]:
    return checked_module_list(
        root / f"lib/modules/{filename}", modules, expected_lines, expected_unique
    )


def checked_module_list(
    path: Path,
    modules: set[str],
    expected_lines: int,
    expected_unique: int,
) -> list[str]:
    if not path.is_file() or path.is_symlink():
        die(f"missing or unsafe module list: {path}")
    names = [
        PurePosixPath(line.strip()).name
        for line in path.read_text(encoding="ascii").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(names) != expected_lines or len(set(names)) != expected_unique:
        die(f"unexpected {path.name} line/unique count")
    if not set(names) <= modules:
        die(f"{path.name} names modules absent from its image")
    return names


def system_module_files(root: Path) -> tuple[dict[str, Path], Path]:
    release_parent = root / "lib/modules"
    releases = sorted(path for path in release_parent.iterdir()) if release_parent.is_dir() else []
    if len(releases) != 1 or not releases[0].is_dir() or releases[0].is_symlink():
        die("system_dlkm must contain exactly one safe lib/modules release")
    release_root = releases[0]
    if release_root.name != STOCK_RELEASE:
        die(f"unexpected system_dlkm release directory: {release_root.name}")

    order_path = release_root / "modules.order"
    checked_file(order_path, SYSTEM_MODULES_ORDER_SHA256, "system_dlkm modules.order")
    try:
        order_lines = order_path.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError:
        die("system_dlkm modules.order is not ASCII")
    if len(order_lines) != EXPECTED_SYSTEM_MODULES or len(set(order_lines)) != len(order_lines):
        die(f"unexpected system_dlkm modules.order count: {len(order_lines)}")

    ordered: dict[str, Path] = {}
    normalized = bytearray()
    for line in order_lines:
        path = PurePosixPath(line)
        if (
            not line.startswith("kernel/")
            or path.is_absolute()
            or any(part in ("", ".", "..") for part in path.parts)
            or path.suffix != ".ko"
        ):
            die(f"unsafe system_dlkm modules.order entry: {line!r}")
        basename = path.name
        if basename in ordered:
            die(f"duplicate system_dlkm module basename: {basename}")
        ordered[basename] = release_root / Path(*path.parts)
        normalized.extend(f"{line[7:-3]}.o\n".encode("ascii"))
    for path in ordered.values():
        if not path.is_file() or path.is_symlink():
            die(f"missing or unsafe ordered system module: {path}")
    actual_full = {
        path.resolve()
        for path in (release_root / "kernel").rglob("*.ko")
        if path.is_file() and not path.is_symlink()
    }
    if actual_full != {path.resolve() for path in ordered.values()}:
        die("system_dlkm full module tree differs from modules.order")
    if sha256_bytes(bytes(normalized)) != SYSTEM_NORMALIZED_MODULES_ORDER_SHA256:
        die("normalized system_dlkm modules.order SHA-256 mismatch")

    flatten_root = root / "flatten"
    flattened = module_files(flatten_root, EXPECTED_SYSTEM_MODULES, "system_dlkm flatten")
    if set(flattened) != set(ordered):
        die("system_dlkm full and flatten module sets differ")
    differing = sorted(
        name for name in flattened if sha256_file(flattened[name]) != sha256_file(ordered[name])
    )
    if differing:
        die(f"system_dlkm full/flatten module bytes differ: {differing}")
    return flattened, release_root


def verify_system_properties(root: Path) -> str:
    path = root / "etc/build.prop"
    checked_file(path, SYSTEM_BUILD_PROP_SHA256, "system_dlkm build.prop")
    properties: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or key in properties:
            die(f"malformed system_dlkm build.prop line {line_number}")
        properties[key] = value
    fingerprint = properties.get("ro.system_dlkm.build.fingerprint")
    if fingerprint != SYSTEM_BUILD_FINGERPRINT:
        die(f"unexpected system_dlkm fingerprint: {fingerprint!r}")
    return fingerprint


def kmod_records(modprobe: Path, flag: str, module: Path) -> list[tuple[str, int]]:
    result = run([str(modprobe), flag, str(module)], check=False)
    if result.returncode:
        if result.stdout or not result.stderr.rstrip().endswith(": No data available"):
            die(f"kmod failed for {module.name} {flag}: {result.stderr.strip()}")
        return []
    records = []
    for line in result.stdout.splitlines():
        match = RECORD_RE.fullmatch(line)
        if not match:
            die(f"malformed kmod record for {module.name}: {line!r}")
        records.append((match.group(2), int(match.group(1), 16)))
    return records


def modinfo_values(modinfo: Path, field: str, module: Path) -> list[str]:
    result = run([str(modinfo), "-F", field, str(module)])
    return result.stdout.rstrip("\n").splitlines()


def parse_symvers(path: Path) -> dict[str, list[tuple[int, str]]]:
    records: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for line_number, line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        fields = line.split()
        if len(fields) < 4 or not re.fullmatch(r"0x[0-9a-fA-F]{8}", fields[0]):
            die(f"malformed Module.symvers line {line_number}")
        records[fields[1]].append((int(fields[0], 16), fields[2]))
    return records


def prove_module_providers(
    requirements: dict[str, set[int]],
    requirement_owners: dict[str, set[tuple[str, str]]],
    exports: dict[str, set[int]],
    export_owners: dict[str, set[tuple[str, str]]],
    module_names: dict[tuple[str, str], str],
    module_dependencies: dict[tuple[str, str], set[str]],
    dep_maps: list[tuple[set[tuple[str, str]], dict[str, set[str]]]],
    label: str,
) -> set[str]:
    provided = set()
    for symbol in sorted(set(requirements) & set(exports)):
        if requirements[symbol] != exports[symbol]:
            die(f"{label} import/export CRC mismatch for {symbol}")
        providers = export_owners[symbol]
        if len(providers) != 1:
            die(f"{label} has ambiguous providers for {symbol}")
        provider = next(iter(providers))
        provider_name = module_names[provider]
        for importer in requirement_owners[symbol]:
            if importer != provider and provider_name not in module_dependencies[importer]:
                die(f"unproven {label} provider for {symbol}: {importer} -> {provider}")
            for image_modules, dependencies in dep_maps:
                if importer == provider or importer not in image_modules or provider not in image_modules:
                    continue
                if provider[1] not in dependencies[importer[1]]:
                    die(f"modules.dep omits provider for {symbol}: {importer} -> {provider}")
        provided.add(symbol)
    return provided


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--boot-image", type=Path, default=Path("tmp/os4/boot.img"))
    parser.add_argument("--vendor-boot-image", type=Path, default=Path("tmp/os4/vendor_boot.img"))
    parser.add_argument("--vendor-dlkm-image", type=Path, default=Path("tmp/os4/vendor_dlkm.img"))
    parser.add_argument("--system-dlkm-image", type=Path, default=Path("tmp/os4/system_dlkm.img"))
    parser.add_argument(
        "--common-repo",
        type=Path,
        default=Path("sources/aosp_common_backport_audit"),
        help="fixed official AOSP audit repository prepared by init.sh",
    )
    parser.add_argument("--fsck-erofs", type=Path, default=Path("environment/toolchain/ci-sm8850-r536225/build-tools/bin/fsck.erofs"))
    parser.add_argument("--kmod", type=Path, default=Path("environment/toolchain/ci-sm8850-r536225/build-tools/bin/depmod"))
    parser.add_argument("--unpack-bootimg", type=Path, default=Path("/usr/bin/unpack_bootimg"))
    parser.add_argument("--bsdtar", type=Path, default=Path("/usr/bin/bsdtar"))
    parser.add_argument(
        "--extract-ikconfig",
        type=Path,
        default=Path("sources/aosp_common_6.12.69_kmi6_r63/scripts/extract-ikconfig"),
    )
    parser.add_argument("--module-symvers", type=Path, required=True)
    args = parser.parse_args()

    if args.output.exists():
        die(f"refusing to overwrite output: {args.output}")
    for path, expected, label in (
        (args.boot_image, BOOT_SHA256, "boot.img"),
        (args.vendor_boot_image, VENDOR_BOOT_SHA256, "vendor_boot.img"),
        (args.vendor_dlkm_image, VENDOR_DLKM_SHA256, "vendor_dlkm.img"),
        (args.system_dlkm_image, SYSTEM_DLKM_SHA256, "system_dlkm.img"),
        (args.fsck_erofs, FSCK_EROFS_SHA256, "fsck.erofs"),
        (args.kmod, KMOD_SHA256, "AOSP build-tools kmod"),
        (args.unpack_bootimg, UNPACK_BOOTIMG_SHA256, "AOSP unpack_bootimg"),
        (args.bsdtar, BSDTAR_SHA256, "bsdtar"),
        (args.extract_ikconfig, EXTRACT_IKCONFIG_SHA256, "extract-ikconfig"),
    ):
        checked_file(path, expected, label)
    if args.system_dlkm_image.stat().st_size != SYSTEM_DLKM_SIZE:
        die(
            "system_dlkm.img size mismatch: "
            f"{args.system_dlkm_image.stat().st_size} != {SYSTEM_DLKM_SIZE}"
        )
    kernel_digest = parse_boot_image(args.boot_image)
    verify_stock_ikconfig(args.extract_ikconfig, args.boot_image)
    if "binder.impl=rust" in vendor_boot_cmdline(args.vendor_boot_image).split():
        die("stock vendor command line selects Rust Binder")

    common_commit = run(
        ["git", "-C", str(args.common_repo), "rev-parse", f"{COMMON_COMMIT}^{{commit}}"]
    ).stdout.strip()
    if common_commit != COMMON_COMMIT:
        die(f"unexpected classification common commit: {common_commit}")
    audit_ref = f"refs/backport-audit/aosp/{COMMON_TAG}^{{commit}}"
    ref_commit = run(["git", "-C", str(args.common_repo), "rev-parse", audit_ref]).stdout.strip()
    if ref_commit != COMMON_COMMIT:
        die(f"fixed audit ref {COMMON_TAG} does not resolve to {COMMON_COMMIT}")
    qcom = official_symbols(
        args.common_repo, "gki/aarch64/symbols/qcom", QCOM_SYMBOL_LIST_SHA256
    )
    xiaomi = official_symbols(
        args.common_repo, "gki/aarch64/symbols/xiaomi", XIAOMI_SYMBOL_LIST_SHA256
    )
    official_union = qcom | xiaomi
    if (len(qcom), len(xiaomi), len(official_union)) != (4192, 573, 4719):
        die("official QCOM/Xiaomi symbol-list counts changed")

    domain_requirements: dict[str, dict[str, set[int]]] = {
        "vendor": defaultdict(set),
        "system": defaultdict(set),
    }
    domain_exports: dict[str, dict[str, set[int]]] = {
        "vendor": defaultdict(set),
        "system": defaultdict(set),
    }
    domain_requirement_owners: dict[str, dict[str, set[tuple[str, str]]]] = {
        "vendor": defaultdict(set),
        "system": defaultdict(set),
    }
    domain_export_owners: dict[str, dict[str, set[tuple[str, str]]]] = {
        "vendor": defaultdict(set),
        "system": defaultdict(set),
    }
    module_dependencies: dict[tuple[str, str], set[str]] = {}
    module_names: dict[tuple[str, str], str] = {}
    domain_requirement_records = {"vendor": 0, "system": 0}
    rust_binder_requirements: list[tuple[str, int]] = []

    with tempfile.TemporaryDirectory(prefix="luna-stock-kmi-v4-") as temporary:
        temporary_path = Path(temporary)
        dlkm_root = temporary_path / "vendor_dlkm"
        dlkm_root.mkdir()
        run([str(args.fsck_erofs), f"--extract={dlkm_root}", "--no-preserve", str(args.vendor_dlkm_image)])

        system_root = temporary_path / "system_dlkm"
        system_root.mkdir()
        run(
            [
                str(args.fsck_erofs),
                f"--extract={system_root}",
                "--no-preserve",
                str(args.system_dlkm_image),
            ]
        )
        system_fingerprint = verify_system_properties(system_root)
        system_modules, system_release_root = system_module_files(system_root)

        unpacked_boot = temporary_path / "vendor_boot"
        run([str(args.unpack_bootimg), "--boot_img", str(args.vendor_boot_image), "--out", str(unpacked_boot)])
        extracted_names = {path.name for path in unpacked_boot.iterdir() if path.is_file()}
        if extracted_names != {"bootconfig", "dtb", "vendor_ramdisk00"}:
            die(f"unexpected vendor_boot extraction: {sorted(extracted_names)}")
        bootconfig = unpacked_boot / "bootconfig"
        checked_file(bootconfig, VENDOR_BOOTCONFIG_SHA256, "vendor_boot bootconfig")
        bootconfig_text = bootconfig.read_text(encoding="ascii")
        if any(word == "binder.impl=rust" for word in bootconfig_text.split()):
            die("stock bootconfig selects Rust Binder")
        dtb = unpacked_boot / "dtb"
        checked_file(dtb, VENDOR_DTB_SHA256, "vendor_boot concatenated DTB")
        if dtb.stat().st_size != VENDOR_DTB_SIZE:
            die(f"unexpected vendor_boot concatenated DTB size: {dtb.stat().st_size}")
        if b"binder.impl=rust" in dtb.read_bytes():
            die("stock vendor_boot DTB selects Rust Binder")
        vendor_ramdisk = unpacked_boot / "vendor_ramdisk00"
        checked_file(vendor_ramdisk, VENDOR_RAMDISK_SHA256, "vendor_boot ramdisk")
        boot_root = temporary_path / "vendor_boot_ramdisk"
        boot_root.mkdir()
        run([str(args.bsdtar), "-xf", str(vendor_ramdisk), "-C", str(boot_root), "lib/modules"])

        dlkm_modules = module_files(dlkm_root, EXPECTED_VENDOR_DLKM_MODULES, "vendor_dlkm")
        boot_modules = module_files(boot_root, EXPECTED_VENDOR_BOOT_MODULES, "vendor_boot")
        overlap = set(dlkm_modules) & set(boot_modules)
        if len(overlap) != EXPECTED_IDENTICAL_OVERLAP:
            die(f"unexpected vendor module overlap: {len(overlap)}")
        for name in overlap:
            if sha256_file(dlkm_modules[name]) != sha256_file(boot_modules[name]):
                die(f"vendor module differs between images: {name}")
        vendor_modules = dict(boot_modules)
        vendor_modules.update(dlkm_modules)
        if len(vendor_modules) != EXPECTED_UNION_MODULES:
            die(f"unexpected unique vendor module count: {len(vendor_modules)}")

        vendor_dep_maps = [
            (
                {("vendor", name) for name in dlkm_modules},
                parse_modules_dep(dlkm_root, set(dlkm_modules), "vendor_dlkm"),
            ),
            (
                {("vendor", name) for name in boot_modules},
                parse_modules_dep(boot_root, set(boot_modules), "vendor_boot"),
            ),
        ]
        checked_load_file(dlkm_root, "modules.load", set(dlkm_modules), 667, 404)
        checked_load_file(boot_root, "modules.load", set(boot_modules), 175, 172)
        checked_load_file(boot_root, "modules.load.recovery", set(boot_modules), 471, 460)

        flatten_root = system_root / "flatten/lib/modules"
        checked_file(
            flatten_root / "modules.load", SYSTEM_MODULES_LOAD_SHA256, "system_dlkm modules.load"
        )
        checked_file(
            flatten_root / "modules.dep", SYSTEM_MODULES_DEP_SHA256, "system_dlkm modules.dep"
        )
        flat_load = checked_load_file(
            system_root / "flatten",
            "modules.load",
            set(system_modules),
            EXPECTED_SYSTEM_LOADED_MODULES,
            EXPECTED_SYSTEM_LOADED_MODULES,
        )
        full_load = checked_module_list(
            system_release_root / "modules.load",
            set(system_modules),
            EXPECTED_SYSTEM_LOADED_MODULES,
            EXPECTED_SYSTEM_LOADED_MODULES,
        )
        if full_load != flat_load:
            die("system_dlkm full and flatten modules.load orders differ")
        if flat_load.count(RUST_BINDER_MODULE) != 1:
            die("system_dlkm modules.load must contain rust_binder.ko exactly once")
        system_dep_maps = [
            (
                {("system", name) for name in system_modules},
                parse_modules_dep(
                    system_root / "flatten", set(system_modules), "system_dlkm flatten"
                ),
            )
        ]

        multicall = args.kmod.resolve()
        modprobe = temporary_path / "modprobe"
        modinfo = temporary_path / "modinfo"
        os.symlink(multicall, modprobe)
        os.symlink(multicall, modinfo)

        modules = {
            **{("vendor", name): path for name, path in vendor_modules.items()},
            **{("system", name): path for name, path in system_modules.items()},
        }
        if len(modules) != EXPECTED_COMBINED_MODULES:
            die(f"unexpected combined stock module count: {len(modules)}")

        vermagics = {"vendor": set(), "system": set()}
        normalized_names = {"vendor": set(), "system": set()}
        for module_id, module in sorted(modules.items()):
            domain, filename = module_id
            imports = module_import_records(module)
            exports_for_module = kmod_records(modprobe, "--show-exports", module)
            vermagic_values = modinfo_values(modinfo, "vermagic", module)
            name_values = modinfo_values(modinfo, "name", module)
            if len(vermagic_values) != 1 or len(name_values) != 1:
                die(f"{filename}: expected one vermagic and module name")
            vermagics[domain].add(vermagic_values[0])
            name = name_values[0]
            if not MODULE_NAME_RE.fullmatch(name):
                die(f"{filename}: invalid module name: {name!r}")
            normalized = name.replace("-", "_")
            if normalized in normalized_names[domain]:
                die(f"duplicate normalized {domain} module name: {normalized}")
            normalized_names[domain].add(normalized)
            module_names[module_id] = normalized
            dependency_values = modinfo_values(modinfo, "depends", module)
            module_dependencies[module_id] = {
                value.replace("-", "_")
                for line in dependency_values
                for value in line.split(",")
                if value
            }
            domain_requirement_records[domain] += len(imports)
            if module_id == ("system", RUST_BINDER_MODULE):
                rust_binder_requirements = imports
                if exports_for_module or module_dependencies[module_id]:
                    die("rust_binder exception unexpectedly exports symbols or depends on a module")
                continue
            for symbol, crc in imports:
                domain_requirements[domain][symbol].add(crc)
                domain_requirement_owners[domain][symbol].add(module_id)
            for symbol, crc in exports_for_module:
                domain_exports[domain][symbol].add(crc)
                domain_export_owners[domain][symbol].add(module_id)

        rust_binder_id = ("system", RUST_BINDER_MODULE)
        if module_names.get(rust_binder_id) != "rust_binder":
            die("rust_binder exception module name changed")
        rust_binder_dependents = sorted(
            module_id
            for module_id, dependencies in module_dependencies.items()
            if module_id != rust_binder_id and "rust_binder" in dependencies
        )
        if rust_binder_dependents:
            die(f"stock modules depend on rust_binder exception: {rust_binder_dependents}")

        cross_domain_module_names = normalized_names["vendor"] & normalized_names["system"]
        if cross_domain_module_names != EXPECTED_CROSS_DOMAIN_MODULE_NAMES:
            die(
                "cross-domain module-name shadow set changed: "
                f"{sorted(cross_domain_module_names)}"
            )

        if vermagics["vendor"] != {STOCK_VERMAGIC}:
            die(f"unexpected vendor vermagic set: {sorted(vermagics['vendor'])}")
        if vermagics["system"] != {STOCK_SYSTEM_VERMAGIC}:
            die(f"unexpected system vermagic set: {sorted(vermagics['system'])}")
        if (
            domain_requirement_records["vendor"] != EXPECTED_REQUIREMENT_RECORDS
            or len(domain_requirements["vendor"]) != EXPECTED_REQUIREMENTS
        ):
            die(
                "vendor requirement snapshot changed: "
                f"records={domain_requirement_records['vendor']} "
                f"symbols={len(domain_requirements['vendor'])}"
            )
        if (
            domain_requirement_records["system"] != EXPECTED_SYSTEM_REQUIREMENT_RECORDS
            or len(domain_requirements["system"]) != EXPECTED_SYSTEM_HARD_REQUIREMENTS
        ):
            die(
                "system requirement snapshot changed: "
                f"records={domain_requirement_records['system']} "
                f"hard_symbols={len(domain_requirements['system'])}"
            )
        if (
            domain_requirement_records["system"] - len(rust_binder_requirements)
            != EXPECTED_SYSTEM_HARD_REQUIREMENT_RECORDS
            or domain_requirement_records["vendor"]
            + domain_requirement_records["system"]
            - len(rust_binder_requirements)
            != EXPECTED_COMBINED_REQUIREMENT_RECORDS
        ):
            die("combined hard requirement record count changed")
        system_all_requirements: dict[str, set[int]] = defaultdict(set)
        for symbol, values in domain_requirements["system"].items():
            system_all_requirements[symbol].update(values)
        for symbol, crc in rust_binder_requirements:
            system_all_requirements[symbol].add(crc)
        if (
            len(system_all_requirements) != EXPECTED_SYSTEM_REQUIREMENTS
            or any(len(values) != 1 for values in system_all_requirements.values())
        ):
            die("complete system requirement snapshot changed")
        if len(domain_exports["vendor"]) != EXPECTED_EXPORTS:
            die(f"vendor export snapshot changed: {len(domain_exports['vendor'])}")
        if len(domain_exports["system"]) != EXPECTED_SYSTEM_EXPORTS:
            die(f"system export snapshot changed: {len(domain_exports['system'])}")
        if (
            len(set(domain_exports["vendor"]) | set(domain_exports["system"]))
            != EXPECTED_COMBINED_EXPORTS
        ):
            die("combined export-name snapshot changed")
        if any(len(values) != 1 for values in domain_requirements["vendor"].values()):
            die("vendor modules disagree on a required symbol CRC")
        if any(len(values) != 1 for values in domain_exports["vendor"].values()):
            die("vendor modules disagree on an exported symbol CRC")
        if any(len(values) != 1 for values in domain_export_owners["vendor"].values()):
            die("multiple vendor modules export the same symbol")
        if any(len(values) != 1 for values in domain_requirements["system"].values()):
            die("system modules disagree on a required symbol CRC")
        if any(len(values) != 1 for values in domain_exports["system"].values()):
            die("system modules disagree on an exported symbol CRC")
        if any(len(values) != 1 for values in domain_export_owners["system"].values()):
            die("multiple system modules export the same symbol")

        vendor_provided = prove_module_providers(
            domain_requirements["vendor"],
            domain_requirement_owners["vendor"],
            domain_exports["vendor"],
            domain_export_owners["vendor"],
            module_names,
            module_dependencies,
            vendor_dep_maps,
            "vendor",
        )
        if len(vendor_provided) != EXPECTED_VENDOR_PROVIDED:
            die(f"vendor-provided symbol count changed: {len(vendor_provided)}")
        system_provided = prove_module_providers(
            domain_requirements["system"],
            domain_requirement_owners["system"],
            domain_exports["system"],
            domain_export_owners["system"],
            module_names,
            module_dependencies,
            system_dep_maps,
            "system",
        )
        if len(system_provided) != EXPECTED_SYSTEM_PROVIDED:
            die(f"system-provided symbol count changed: {len(system_provided)}")

        domain_residual: dict[str, list[tuple[str, int]]] = {}
        for domain, provided in (("vendor", vendor_provided), ("system", system_provided)):
            records = [
                (symbol, next(iter(domain_requirements[domain][symbol])))
                for symbol in sorted(domain_requirements[domain])
                if symbol not in provided
            ]
            body = b"".join(
                f"0x{crc:08x}\t{symbol}\n".encode("ascii") for symbol, crc in records
            )
            expected_count, expected_sha256 = {
                "vendor": (EXPECTED_VENDOR_COMMON_REQUIRED, EXPECTED_VENDOR_COMMON_SHA256),
                "system": (EXPECTED_SYSTEM_COMMON_REQUIRED, EXPECTED_SYSTEM_COMMON_SHA256),
            }[domain]
            if len(records) != expected_count or sha256_bytes(body) != expected_sha256:
                die(
                    f"{domain} residual requirement snapshot changed: "
                    f"count={len(records)} sha256={sha256_bytes(body)}"
                )
            domain_residual[domain] = records

        domain_common: dict[str, tuple[int, set[tuple[str, str]]]] = {}
        for domain in ("vendor", "system"):
            for symbol, crc in domain_residual[domain]:
                if symbol in domain_common and domain_common[symbol][0] != crc:
                    die(f"vendor/system common requirement CRC conflict for {symbol}")
                owners = set(domain_requirement_owners[domain][symbol])
                if symbol in domain_common:
                    owners |= domain_common[symbol][1]
                domain_common[symbol] = (crc, owners)
        if len(domain_common) != EXPECTED_DOMAIN_COMMON_REQUIRED:
            die(f"domain common requirement count changed: {len(domain_common)}")

        all_export_owners: dict[str, set[tuple[str, str]]] = defaultdict(set)
        all_export_crcs: dict[str, dict[tuple[str, str], int]] = defaultdict(dict)
        for domain in ("vendor", "system"):
            for symbol, owners in domain_export_owners[domain].items():
                crc = next(iter(domain_exports[domain][symbol]))
                all_export_owners[symbol].update(owners)
                for owner in owners:
                    all_export_crcs[symbol][owner] = crc

        cross_providers: dict[str, tuple[str, str]] = {}
        for symbol, (crc, importers) in sorted(domain_common.items()):
            if symbol not in all_export_owners:
                continue
            proven = True
            providers_for_importers: set[tuple[str, str]] = set()
            for importer in importers:
                candidates = {
                    provider
                    for provider in all_export_owners[symbol]
                    if provider[0] != importer[0]
                    and all_export_crcs[symbol][provider] == crc
                    and module_names[provider] in module_dependencies[importer]
                }
                if len(candidates) != 1:
                    proven = False
                    break
                providers_for_importers.update(candidates)
            if proven:
                if len(providers_for_importers) != 1:
                    die(f"cross-domain provider identity differs between importers: {symbol}")
                provider = next(iter(providers_for_importers))
                if module_names[provider] in cross_domain_module_names:
                    die(f"cross-domain provider is shadowed by module name: {symbol} -> {provider}")
                cross_providers[symbol] = provider
        cross_body = b"".join(
            f"0x{domain_common[symbol][0]:08x}\t{symbol}\t{provider[0]}:{provider[1]}\n".encode(
                "ascii"
            )
            for symbol, provider in sorted(cross_providers.items())
        )
        if (
            len(cross_providers) != EXPECTED_CROSS_DOMAIN_PROVIDED
            or sha256_bytes(cross_body) != EXPECTED_CROSS_DOMAIN_PROVIDED_SHA256
        ):
            die(
                "cross-domain provider snapshot changed: "
                f"count={len(cross_providers)} sha256={sha256_bytes(cross_body)}"
            )

        common_required = [
            (symbol, crc)
            for symbol, (crc, _owners) in sorted(domain_common.items())
            if symbol not in cross_providers
        ]
        if len(common_required) != EXPECTED_COMBINED_COMMON_REQUIRED:
            die(f"stock-required vmlinux KMI count changed: {len(common_required)}")
        official_subset = sum(symbol in official_union for symbol, _ in common_required)
        if official_subset != EXPECTED_COMBINED_OFFICIAL_SUBSET:
            die(f"stock-required official-list subset changed: {official_subset}")

        if sha256_file(system_modules[RUST_BINDER_MODULE]) != RUST_BINDER_SHA256:
            die("stock rust_binder.ko SHA-256 mismatch")
        rust_records = sorted(rust_binder_requirements, key=lambda record: record[0].encode("ascii"))
        rust_body = b"".join(
            f"0x{crc:08x}\t{symbol}\n".encode("ascii") for symbol, crc in rust_records
        )
        if (
            len(rust_records) != RUST_BINDER_REQUIREMENTS
            or sha256_bytes(rust_body) != RUST_BINDER_REQUIREMENTS_SHA256
        ):
            die("stock rust_binder extended requirement snapshot changed")

    if not args.module_symvers.is_file() or args.module_symvers.is_symlink():
        die(f"missing or unsafe Module.symvers: {args.module_symvers}")
    symvers = parse_symvers(args.module_symvers)
    duplicate_symvers = sorted(symbol for symbol, records in symvers.items() if len(records) != 1)
    if duplicate_symvers:
        die(f"Module.symvers contains duplicate symbols: {duplicate_symvers[:20]}")
    missing = []
    mismatched = []
    non_vmlinux = []
    for symbol, crc in common_required:
        records = symvers.get(symbol, [])
        if not records:
            missing.append(symbol)
        elif records[0][0] != crc:
            mismatched.append(symbol)
        elif records[0][1] != "vmlinux":
            non_vmlinux.append(symbol)
    if missing or mismatched or non_vmlinux:
        die(
            "Module.symvers vmlinux mismatch: "
            f"missing={len(missing)} crc={len(mismatched)} provider={len(non_vmlinux)}"
        )

    rust_matching = []
    rust_missing = []
    rust_mismatched = []
    rust_non_vmlinux = []
    for symbol, crc in rust_records:
        records = symvers.get(symbol, [])
        if not records:
            rust_missing.append((symbol, crc))
        elif records[0][0] != crc:
            rust_mismatched.append(symbol)
        elif records[0][1] != "vmlinux":
            rust_non_vmlinux.append(symbol)
        else:
            rust_matching.append(symbol)
    rust_gap = b"".join(
        f"0x{crc:08x}\t{symbol}\n".encode("ascii") for symbol, crc in rust_missing
    )
    if (
        len(rust_matching) != RUST_BINDER_MATCHING_VMLINUX
        or len(rust_missing) != RUST_BINDER_MISSING
        or rust_mismatched
        or rust_non_vmlinux
        or sha256_bytes(rust_gap) != RUST_BINDER_MISSING_SHA256
    ):
        die(
            "rust_binder exception changed: "
            f"match={len(rust_matching)} missing={len(rust_missing)} "
            f"crc={len(rust_mismatched)} provider={len(rust_non_vmlinux)}"
        )

    rust_gap_comments = "".join(
        f"# rust_binder-missing\t0x{crc:08x}\t{symbol}\n"
        for symbol, crc in rust_missing
    )
    rust_requirement_comments = "".join(
        f"# rust_binder-requirement\t0x{crc:08x}\t{symbol}\n"
        for symbol, crc in rust_records
    )
    header = (
        "# Luna Kernel Xiaomi 17 Android 17 stock-common ABI evidence v5\n"
        f"# boot.img sha256: {BOOT_SHA256}\n"
        f"# boot kernel Image sha256: {kernel_digest}\n"
        f"# stock kernel release: {STOCK_RELEASE}\n"
        f"# stock IKCONFIG: lines={STOCK_IKCONFIG_LINES} sha256:{STOCK_IKCONFIG_SHA256}\n"
        f"# stock common providers: {STOCK_PROVIDER_SUMMARY}\n"
        f"# vendor_boot.img sha256: {VENDOR_BOOT_SHA256}\n"
        f"# vendor_boot bootconfig sha256: {VENDOR_BOOTCONFIG_SHA256}; binder.impl=rust absent\n"
        f"# vendor_boot concatenated DTB: bytes={VENDOR_DTB_SIZE} sha256:{VENDOR_DTB_SHA256}; "
        "binder.impl=rust absent\n"
        f"# vendor_boot ramdisk sha256: {VENDOR_RAMDISK_SHA256}\n"
        f"# vendor_dlkm.img sha256: {VENDOR_DLKM_SHA256}\n"
        f"# system_dlkm.img: bytes={SYSTEM_DLKM_SIZE} sha256:{SYSTEM_DLKM_SHA256}\n"
        f"# system_dlkm fingerprint: {system_fingerprint}\n"
        f"# system_dlkm build.prop sha256: {SYSTEM_BUILD_PROP_SHA256}\n"
        f"# system_dlkm unique release: {STOCK_RELEASE}\n"
        f"# system_dlkm modules: order={EXPECTED_SYSTEM_MODULES} loaded={EXPECTED_SYSTEM_LOADED_MODULES} "
        f"order-sha256:{SYSTEM_MODULES_ORDER_SHA256} load-sha256:{SYSTEM_MODULES_LOAD_SHA256}\n"
        f"# normalized stock modules.order: entries={EXPECTED_SYSTEM_MODULES} "
        f"sha256:{SYSTEM_NORMALIZED_MODULES_ORDER_SHA256}; target module matrix is not frozen\n"
        f"# stock modules: vendor_boot={EXPECTED_VENDOR_BOOT_MODULES} "
        f"vendor_dlkm={EXPECTED_VENDOR_DLKM_MODULES} "
        f"identical-overlap={EXPECTED_IDENTICAL_OVERLAP} "
        f"vendor-union={EXPECTED_UNION_MODULES} system={EXPECTED_SYSTEM_MODULES} "
        f"combined={EXPECTED_COMBINED_MODULES}\n"
        f"# vendor module vermagic: {STOCK_VERMAGIC}\n"
        f"# system module vermagic: {STOCK_SYSTEM_VERMAGIC}\n"
        "# stock Binder configuration: C Binder/BinderFS built-in; Rust Binder module\n"
        f"# official-list classification source only, not target baseline: {COMMON_TAG} @ {COMMON_COMMIT}\n"
        f"# classification qcom symbol list sha256: {QCOM_SYMBOL_LIST_SHA256}\n"
        f"# classification xiaomi symbol list sha256: {XIAOMI_SYMBOL_LIST_SHA256}\n"
        f"# extraction tools: fsck.erofs sha256:{FSCK_EROFS_SHA256} unpack_bootimg sha256:{UNPACK_BOOTIMG_SHA256} bsdtar sha256:{BSDTAR_SHA256}\n"
        "# import parser: strict ELF64/AArch64 __version_ext_crcs+__version_ext_names; "
        "EXTENDED is authoritative and __versions must be its exact short-name projection\n"
        f"# export/metadata parser: AOSP build-tools kmod sha256:{KMOD_SHA256}; exports, name, vermagic and depends\n"
        f"# import records: vendor={EXPECTED_REQUIREMENT_RECORDS} system={EXPECTED_SYSTEM_REQUIREMENT_RECORDS} "
        f"hard-total={EXPECTED_COMBINED_REQUIREMENT_RECORDS}\n"
        f"# domain residual: vendor={EXPECTED_VENDOR_COMMON_REQUIRED} "
        f"sha256:{EXPECTED_VENDOR_COMMON_SHA256}; system={EXPECTED_SYSTEM_COMMON_REQUIRED} "
        f"sha256:{EXPECTED_SYSTEM_COMMON_SHA256}\n"
        f"# cross-domain module-name shadows: {','.join(sorted(EXPECTED_CROSS_DOMAIN_MODULE_NAMES))}\n"
        "# provider closure: vendor and system are first resolved independently; "
        f"cross-partition providers={EXPECTED_CROSS_DOMAIN_PROVIDED} "
        f"sha256:{EXPECTED_CROSS_DOMAIN_PROVIDED_SHA256}; residual provider must be vmlinux\n"
        f"# official-list subset: {EXPECTED_COMBINED_OFFICIAL_SUBSET}; outside official lists: "
        f"{EXPECTED_COMBINED_COMMON_REQUIRED - EXPECTED_COMBINED_OFFICIAL_SUBSET}\n"
        f"# rust_binder exception module: {RUST_BINDER_MODULE} sha256:{RUST_BINDER_SHA256}\n"
        f"# rust_binder extended requirements: entries={RUST_BINDER_REQUIREMENTS} "
        f"sha256:{RUST_BINDER_REQUIREMENTS_SHA256}\n"
        f"{rust_requirement_comments}"
        f"# rust_binder target result: vmlinux-match={RUST_BINDER_MATCHING_VMLINUX} "
        f"missing={RUST_BINDER_MISSING} crc-mismatch=0 non-vmlinux=0 "
        f"missing-sha256:{RUST_BINDER_MISSING_SHA256}\n"
        "# rust_binder is not ABI-compatible and is excluded only because the fixed boot inputs "
        "do not select Rust Binder; this exception must never cover another module or CRC mismatch\n"
        f"{rust_gap_comments}"
        "# order: ASCII symbol byte order; data format: 0xCRC<TAB>symbol\n"
        f"# entries: {EXPECTED_COMBINED_COMMON_REQUIRED}\n"
    )
    body = "".join(f"0x{crc:08x}\t{symbol}\n" for symbol, crc in common_required)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="ascii", newline="\n") as stream:
        stream.write(header)
        stream.write(body)

    print(f"output={args.output}")
    print(f"entries={len(common_required)}")
    print(f"lines={len((header + body).splitlines())}")
    print(f"sha256={sha256_file(args.output)}")
    print("module_symvers_missing=0")
    print("module_symvers_crc_mismatch=0")
    print("module_symvers_non_vmlinux=0")
    print(f"rust_binder_matching={len(rust_matching)}")
    print(f"rust_binder_missing={len(rust_missing)}")
    print(f"rust_binder_missing_sha256={sha256_bytes(rust_gap)}")


if __name__ == "__main__":
    main()
