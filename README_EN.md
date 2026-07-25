[中文](README.md)

# Luna Kernel

Luna Kernel is an Android 16, Linux 6.12.23, 4 KiB GKI kernel for Xiaomi 17 (`pudding`).

The name Luna evokes a small, quiet, and clean moon. The project uses Xiaomi's public kernel sources and the official AOSP GKI as its baseline, then adds verified features, bug fixes, and lightweight performance improvements while retaining device compatibility.

## Support

| Item | Current support |
| --- | --- |
| Device | Xiaomi 17 |
| Codename | `pudding` |
| Android | Android 16 |
| Kernel | Linux 6.12.23 |
| Page size | 4 KiB |
| boot partition | 96 MiB (`100663296` bytes) |

Only `pudding` is currently supported. Do not flash this kernel on other devices.

## Upstream baseline

| Purpose | Official upstream | Pinned revision |
| --- | --- | --- |
| Xiaomi SM8850 SoC/vendor public baseline | [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) | `popsicle-w-oss` / `45705be1220b4cfa8100516ad86711656c0b634e` |
| GKI Image source | [AOSP kernel/common](https://android.googlesource.com/kernel/common) | `android16-6.12-2025-06_r57` / `a82fc641d6d2c687802606190c0a8c33a4242201` |

The final `Image` is built from AOSP common. Xiaomi's public sources provide the SoC baseline and compatibility metadata.

## Included features

| Component | Version and purpose |
| --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | v3.2.5, built into the kernel; the officially signed Manager APK is also included in the build outputs |
| [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) | v2.2.0, matched to the current KernelSU release |
| [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard) | Protects the baseband and critical partitions; boot/recovery write blocking stays disabled for normal kernel flashing |
| [ADIOS](https://github.com/firelzrd/adios) | v3.2.0, available for runtime selection; the Xiaomi baseline `none` scheduler remains the default |
| [TCP Brutal](https://github.com/apernet/tcp-brutal) | Available for runtime selection; CUBIC remains the default congestion control |
| IPSet | Full kernel support with a separate Android arm64 command and KernelSU module |

The kernel also retains Android GKI capabilities including BBR v1, FQ, seccomp, CFI, BPF JIT, module BTF, FUSE BPF, and Rust.

## Fixes and improvements

Luna backports fixes from official AOSP/Linux history, including:

- F2FS encrypted writeback, inode lifetime, foreground GC, atomic inode, ACL, and xattr fixes.
- EROFS directory-tail and ext4 extended-attribute bounds fixes.
- Concurrency fixes for futex PI, timers, eventpoll, cgroups, blk-cgroup, page pool, and conntrack.
- Binder transaction lifetime, Gunyah resource cleanup, and UFS runtime power-management recovery fixes.
- IPv6 MLD query and rtmutex error-path fixes.
- Unicode 12.1 Default-Ignorable handling with compatibility for existing ext4/f2fs casefold directories.

The current tree also includes fast-path improvements for F2FS open and direct I/O, memcg accounting, TCP receive timestamps, timer bases, EAS CPU masks, and blk-wbt.

## Defaults

- Default I/O scheduler: `none`. ADIOS is available only when explicitly selected.
- Default TCP congestion control: CUBIC. BBR v1 and TCP Brutal are available only when explicitly selected.
- Unprivileged BPF is disabled by default.
- Kernel seccomp support remains enabled. KernelSU Manager or approved root processes may report `Seccomp: 0`; this is expected KernelSU behavior. Normal Android applications should usually report `2`.

## Installation

Before flashing:

1. Confirm that the device is a Xiaomi 17 (`pudding`).
2. Back up the original boot image and prepare a working recovery method.
3. Confirm that the package name matches `luna-xiaomi17-g<short-commit>-YYYYMMDD.zip`.

The package is based on [AnyKernel3](https://github.com/osm0sis/AnyKernel3). It replaces only the `Image` in the current-slot boot partition and does not ship or replace DTB, DTBO, vendor modules, or the vendor ramdisk. The installer checks the boot partition capacity and aborts if the repacked image exceeds 96 MiB.

Flashing a kernel always carries a risk of boot failure or data loss. Make sure the original boot can be restored.

## Build

Linux is recommended. After installing Bash, Git, curl, tar, unzip, 7-Zip, and GNU coreutils, run:

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

- `init.sh` prepares and verifies pinned sources and toolchains.
- `patch.sh` applies Luna kernel fixes and improvements.
- `patch_external.sh` integrates pinned independent components.
- `build.sh` configures, builds, tests, and packages the outputs.

Build outputs are placed in `kernel_out/`. The primary filenames are:

```text
luna-xiaomi17-g<short-commit>-YYYYMMDD.zip
Image-luna-xiaomi17-g<short-commit>-YYYYMMDD
```

The build also outputs KernelSU Manager, SUSFS helpers, and the IPSet KernelSU module. Kernel releases and artifact hashes are derived from the current project commit. The build identity is fixed to `luna@luna-build`.

## Validation status

The current feature set has passed a complete build, configuration checks, Unicode tests, and ABI/KMI checks. It has also completed boot and basic functional validation on Xiaomi 17 `pudding`.

## License

This project combines upstream components under their respective licenses. A unified license-compatibility audit is still required before public distribution, and every component remains subject to its original license.
