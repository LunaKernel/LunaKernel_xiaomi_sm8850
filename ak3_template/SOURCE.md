# AnyKernel3 source record

The flashable package is assembled from a fixed upstream AnyKernel3 script
snapshot and a reviewable Luna patch. No prebuilt template archive is stored in
this repository.

- Script upstream: `https://github.com/osm0sis/AnyKernel3.git`
- Script commit: `f63f136037d74f0e6b7eab941eadec5ff30e34c4`
- arm64 tools commit: `e9101f0378055aa844fd80b7d819e0e1b3f59aed`
- Luna delta: `luna.patch`
- AnyKernel3 license: `LICENSE`

The build downloads the arm64 BusyBox binary from the fixed tools commit and
extracts arm64 MagiskBoot from the fixed official Magisk APK. Both files are
verified by SHA-256 before use. Their original licenses and source locations are
provided by their respective upstream projects.
