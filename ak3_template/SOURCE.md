# AnyKernel3 source record

The flashable package is assembled from a fixed upstream AnyKernel3 script
snapshot and a reviewable Luna patch. No prebuilt template archive is stored in
this repository.

- Script upstream: `https://github.com/osm0sis/AnyKernel3.git`
- Script commit: `41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1`
- arm64 tools commit: `cc7d2cee9b1b4298f6ab8666eb4486dea342748c`
- Luna delta: `luna.patch`
- AnyKernel3 license: `LICENSE`

The build downloads the arm64 BusyBox binary from the fixed tools commit and
extracts arm64 MagiskBoot from the fixed official Magisk APK. Both files are
verified by SHA-256 before use. Their original licenses and source locations are
provided by their respective upstream projects.
