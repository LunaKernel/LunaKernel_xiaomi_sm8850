[中文](README.md)

# Luna Kernel

Luna Kernel is a Linux 6.12.69, 4 KiB GKI kernel for the Xiaomi 17 (`pudding`) HyperOS 4 (Android 17) ROM baseline currently under validation.

The name Luna evokes a small, quiet, and clean moon. The project uses Xiaomi's public kernel sources and the official AOSP GKI as its baseline, then adds features, bug fixes, and lightweight performance improvements with traceable upstream origins and enforced validation gates.

> This HyperOS 4 / Android 17 branch remains under validation. The same-OTA module closure for `OS4.0.0.9.XPCCNXM` is now proven and an Image-only candidate test package can be built; Xiaomi 17 boot, functionality, and stability still require device validation, so this is not yet a formal release.

## Support

| Item | Current status |
| --- | --- |
| Device | Xiaomi 17 |
| Codename | `pudding` |
| OS | HyperOS 4 / Android 17 (validation in progress) |
| Kernel | Linux 6.12.69 |
| Page size | 4 KiB |
| boot partition | 96 MiB (`100663296` bytes) |

Only `pudding` is in scope. Support must not be inferred for other devices.

## Upstream baseline

| Purpose | Official upstream | Pinned revision |
| --- | --- | --- |
| Xiaomi SM8850 SoC/vendor public baseline | [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) | `popsicle-w-oss` / `45705be1220b4cfa8100516ad86711656c0b634e` |
| GKI Image source | [AOSP kernel/common](https://android.googlesource.com/kernel/common) | `android16-6.12-2026-03_r63` / `625bef5cf43deeb3fca2e75202bcf958b6b976e5` |

The final `Image` is built from AOSP common. Xiaomi's public sources provide the SoC baseline and compatibility metadata. The `android16` text in the AOSP branch name identifies the GKI/KMI branch; it does not mean that the target OS is Android 16.

The pinned target OTA is `OS4.0.0.9.XPCCNXM`. Its reused `system_dlkm` build fingerprint still carries Android 16 and `OS4.0.0.8.XPCCN` fields. These are the official partition's original metadata; the project verifies them as-is rather than rewriting them to Android 17.

## Integrated components

| Component | Version and purpose |
| --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | v3.2.5, built into the kernel with selected reviewed upstream fixes; a release build will accompany it with the official upstream Manager APK |
| [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) | v2.2.0, matched to the current KernelSU release; `OPEN_REDIRECT` is not built, while debug logging stays available but defaults to off |
| [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard) | Restricts direct writes by KernelSU-granted processes to baseband and critical partitions; boot/recovery write blocking stays disabled for normal flashing |
| IPSet | Full kernel support; a release will provide the Android arm64 command and KernelSU module separately |

The kernel also retains BBR v1, FQ, seccomp, CFI, BPF JIT, module BTF, FUSE BPF, Rust, and pKVM guest capabilities.

## Fixes and improvements

Luna backports changes from official AOSP/Linux history onto the pinned r63 baseline, primarily covering:

- F2FS foreground GC and ACL/xattr fixes, plus EROFS and ext4 bounds fixes.
- Fixes for futex PI, blk-cgroup, Binder, UFS, IDLETIMER, IPv6 MLD, and KVM compound-page pinning; proactive-reclaim freezer handling is provided by the r63 baseline.
- KernelSU Manager identity verification, low-memory failure paths, and Baseband Guard device-identity and write-path fixes.
- Selected Linux/AOSP fixes for F2FS/UFS, block and memory management, BPF, TCP/IPv6, and IPSet concurrency and lifetime bugs.
- Fast-path improvements for timer bases, F2FS direct I/O, EAS cpumasks, blk-wbt, memcg rstat, and TCP receive timestamps.

## Defaults

- The I/O scheduler remains Xiaomi's baseline `none`.
- CUBIC remains the default TCP congestion control. BBR v1 is available when explicitly selected.
- Unprivileged BPF is disabled by default.
- Kernel seccomp support remains enabled. KernelSU Manager or approved root processes may report `Seccomp: 0`; normal Android applications should usually report `2`.

## Build

Linux is recommended. After installing Bash, Git, curl, tar, unzip, 7-Zip, and GNU coreutils, run:

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

- `init.sh` prepares and verifies pinned sources and toolchains.
- `patch.sh` applies Luna's official backported fixes and improvements.
- `patch_external.sh` integrates pinned independent components.
- `build.sh` configures and builds the kernel, validates the same-OTA boot module closure, and reports configuration, module, and ABI/KMI differences.

The build-output directory for this branch is `kernel_out/android17-r63/`. Candidate ZIP, `Image`, complete compatibility-audit archive, Manager APK, and IPSet artifacts are produced only when the pinned same-OTA `tmp/os4/system_dlkm.img` passes identity, integrity, and module-closure gates and all reference-snapshot drift has been reviewed.

Reproducing the stock ABI manifest requires the same-OTA `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`, and `system_dlkm.img` under `tmp/os4/`, together with the tools verified by the extraction script. `system_dlkm.img` is a compatibility input only and is never included in the flashable package.

Candidate artifact names are:

```text
luna-xiaomi17-g<short-commit>-YYYYMMDD.zip
Image-luna-xiaomi17-g<short-commit>-YYYYMMDD
```

The AnyKernel3 package will replace only the `Image` inside boot. It will not ship or modify DTB, DTBO, vendor modules, the ramdisk, or the boot header. Kernel releases and artifact hashes are derived from the project commit, and the build identity is fixed to `luna@luna-build`.

## Validation status

The HyperOS 4 `OS4.0.0.9.XPCCNXM` boot, vendor_boot, vendor_dlkm, and system_dlkm module closure is complete. Every module dependency matches strictly except `rust_binder.ko`, which is not selected by the boot inputs and differs only in Rust build-context symbols; the default C Binder path does not depend on it. Symbols, CRCs, providers, namespaces, and relevant type compatibility required by the target OTA modules are hard build gates. Full configuration, module-matrix, and ABI/KMI snapshots are still reported, but a difference from the reference snapshot is no longer rejected by itself. Any project-added module must be load-tested with the corresponding `Image` and have a complete dependency closure.

Xiaomi 17 boot, functionality, and stability still require device validation, so this branch has not been formally released.

## License

This project combines upstream components under their respective licenses. A unified license-compatibility audit is still required before public distribution, and every component remains subject to its original license.
