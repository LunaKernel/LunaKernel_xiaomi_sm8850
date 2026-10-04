[中文](README.md)

# Luna Kernel

Luna Kernel is a 4 KiB GKI kernel for the Xiaomi 17 (`pudding`) running HyperOS 4 / Android 17.

Luna evokes a small, quiet, and clean moon. Built on Xiaomi's official public source and AOSP GKI, the project combines traceable fixes, required features, and lightweight performance improvements while preserving target system module compatibility.

## Support

| Item | Version |
| --- | --- |
| Device | Xiaomi 17 (`pudding`) |
| Target OS | HyperOS 4 `OS4.0.0.9.XPCCNXM` / Android 17 |
| Kernel | Linux 6.12.92, 4 KiB |
| AOSP baseline | `android16-6.12-2026-09` |
| Installation | AnyKernel3, replacing only the boot `Image` |

Only the device and OS version above are supported. Back up the current boot image and keep a working Fastboot or Recovery path before flashing.

## Upstreams

- Xiaomi SM8850 public baseline: [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource), `popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e`
- GKI Image source: [AOSP kernel/common](https://android.googlesource.com/kernel/common), `android16-6.12-2026-09` @ `0316e9866fdf55601aae97b14ee08d1b38a3916c`

`android16` is the GKI/KMI branch name; the target ROM is Android 17.

## Features and improvements

- Built-in KernelSU v3.3.0.
- SUSFS v2.3.0; `OPEN_REDIRECT` is not built and debug logging defaults to off.
- Baseband Guard protection for baseband and critical block-device write paths.
- IPSet 7.24 kernel support plus a separate KernelSU userspace module.
- seccomp, CFI, BPF JIT, FUSE BPF, Rust, pKVM guest, BBR v1, and FQ support.
- Selected filesystem, memory-management, scheduler, block, networking, and security fixes still missing from the baseline, backported from AOSP, Linux stable, and mainline.

Backport sources and order are recorded under [`patches/backports/`](patches/backports/). Independent backports can be audited and reverted separately.

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

## Validation status

The historical r21 tree passed device validation on the fixed OTA. The September KMI6 baseline requires its own device retest before release; see the [migration audit](docs/KMI6-2026-09-MIGRATION.md).

## Documentation

- [Build prerequisites, inputs, and validation](docs/BUILDING.md)
- [Validation records](docs/VALIDATION.md)
- [Maintenance and backports](docs/MAINTENANCE.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

Project-authored scripts and patches are released under [GPL-2.0-only](LICENSE). Integrated components retain their original licenses.
