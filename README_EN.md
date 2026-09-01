[中文](README.md)

# Luna Kernel

Luna Kernel is a 4 KiB GKI kernel for the Xiaomi 17 (`pudding`) running HyperOS 4 / Android 17.

The name Luna evokes a small, quiet, and clean moon. The project starts from Xiaomi's official public source and AOSP GKI, then integrates traceable fixes, required functionality, and lightweight performance improvements while preserving compatibility with the target system modules.

## Support

| Item | Version |
| --- | --- |
| Device | Xiaomi 17 (`pudding`) |
| Target OS | HyperOS 4 `OS4.0.0.9.XPCCNXM` / Android 17 |
| Kernel | Linux 6.12.81, 4 KiB |
| AOSP baseline | `android16-6.12-2026-06_r21` |
| Installation | AnyKernel3, replacing only the boot `Image` |

Only the device and OS version above are supported. Back up the current boot image and keep a working Fastboot or Recovery path before flashing.

## Upstreams

- Xiaomi SM8850 public baseline: [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource), `popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e`
- GKI Image source: [AOSP kernel/common](https://android.googlesource.com/kernel/common), `android16-6.12-2026-06_r21` @ `0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28`

The `android16` text is the GKI/KMI branch name; the target ROM is Android 17.

## Features and improvements

- Built-in KernelSU v3.3.0.
- SUSFS v2.3.0; `OPEN_REDIRECT` is not built and debug logging defaults to off.
- Baseband Guard protection for baseband and critical block-device write paths.
- IPSet 7.24 kernel support plus a separate KernelSU userspace module.
- seccomp, CFI, BPF JIT, FUSE BPF, Rust, pKVM guest, BBR v1, and FQ support.
- Selected filesystem, memory-management, scheduler, block, networking, and security fixes still missing from the baseline, backported from AOSP, Linux stable, and mainline.

The complete ordered provenance is recorded under [`patches/backports/`](patches/backports/). Each independent backport remains separately auditable and revertible.

## Build

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

The build verifies pinned sources, toolchains, the target OTA module closure, and release inputs, then produces:

```text
luna-xiaomi17-g<short-commit>-YYYYMMDD.zip
Image-luna-xiaomi17-g<short-commit>-YYYYMMDD
```

See [Building](docs/BUILDING.md) for prerequisites, inputs, and validation details.

## Validation status

The r21 kernel tree has completed boot and extended-use validation on a Xiaomi 17 running HyperOS 4 `OS4.0.0.9.XPCCNXM`, and the target OTA module closure passes. The public-history cleanup changes the project commit hash, so the new public tip still requires a clean rebuild and repeat device validation before binary release.

See [Validation](docs/VALIDATION.md) for the recorded evidence.

## Documentation

- [Building](docs/BUILDING.md)
- [Validation](docs/VALIDATION.md)
- [Maintenance and backports](docs/MAINTENANCE.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

Project-authored scripts and patches are released under [GPL-2.0-only](LICENSE). Integrated components retain their original licenses.
