[中文](README.md)

# Luna Kernel — HyperOS 3 legacy branch

This is Luna Kernel's historical maintenance branch for the Xiaomi 17 (`pudding`) running HyperOS 3 / Android 16.

| Item | Pinned version |
| --- | --- |
| Device | Xiaomi 17 (`pudding`) |
| OS | HyperOS 3 / Android 16 |
| Kernel | Linux 6.12.23, 4 KiB |
| AOSP GKI | `android16-6.12-2025-06_r57` @ `a82fc641d6d2c687802606190c0a8c33a4242201` |
| Xiaomi public baseline | `popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e` |

The branch preserves its KernelSU, SUSFS, Baseband Guard, ADIOS, TCP Brutal, IPSet, and reviewed AOSP/Linux backports for legacy-system maintenance. Current HyperOS 4 / Android 17 development lives on `main`.

## Build

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

The AnyKernel3 installer is rebuilt from fixed official scripts and the branch-specific Luna patch. It replaces only the boot `Image`. Verify the exact device and OS version and back up the original boot image before flashing.

## Status

The original OS3 kernel combination completed build, boot, and basic functionality validation on a Xiaomi 17. Public-history cleanup changes the project hash and packaging source, so the new archive tip does not inherit the release identity of old artifacts and is not the currently recommended version.

## License

Project-authored scripts and patches are released under [GPL-2.0-only](LICENSE). Third-party components retain their original licenses.
