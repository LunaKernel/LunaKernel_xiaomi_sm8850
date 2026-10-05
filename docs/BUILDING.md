# 构建 Luna Kernel

## 环境

推荐使用 x86_64 Linux。macOS 会通过已配置的 OrbStack Linux 环境执行相同流程。

主机需要 Bash、Git、curl、tar、bzip2、xz、unzip、7-Zip、patch、Python 3、GNU coreutils 以及常规内核构建依赖。源码、固定工具链和完整输出会占用数十 GiB，建议预留至少 45 GiB 空间。

所有版本、提交和摘要都记录在根目录 [`.env`](../.env)。不要在 `sources/` 或构建输出中手工改文件。

## 目标 OTA 输入

发布构建必须提供目标 OTA 原始文件：

```text
tmp/os4/system_dlkm.img
```

脚本会校验镜像大小、SHA-256、AVB hashtree、EROFS 内容和 stock 模块清单。镜像仅用于兼容性验证，不进入刷机包。

重新生成 [`abi/xiaomi17-android17-stock-common-abi.tsv`](../abi/xiaomi17-android17-stock-common-abi.tsv) 时，需要同一 OTA 的完整四个镜像：

```text
tmp/os4/boot.img
tmp/os4/vendor_boot.img
tmp/os4/vendor_dlkm.img
tmp/os4/system_dlkm.img
```

## 标准流程

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

各脚本职责：

1. `init.sh` 下载或复用固定源码与工具，逐项校验提交、归档和安装树。
2. `patch.sh` 应用项目维护的 AOSP/Linux 官方回移。
3. `patch_external.sh` 接入固定版本的 KernelSU、SUSFS、Baseband Guard 和 IPSet。
4. `build.sh` 生成配置并编译，验证目标 OTA 模块闭包、关键配置和发布输入，再打包产物与审计报告。

`build.sh` 保留构建目录进行增量编译；`.env` 的 `ENABLE_CCACHE=1` 会在主机提供 ccache 时复用编译缓存，仍使用固定 AOSP clang。

当前使用 Clang r596125 / 22.0.2、AOSP Rust 1.97.0-dev、bindgen 0.72.1 和 NDK r30。Clang 与 Rust 的 LLVM 主版本均为 22，保留 Rust inline helpers。SM8850 的 C / Rust 调度使用 `oryon-1`；完整参数、来源和验证边界见 [编译链审计](SM8850-COMPILE-2026-10-06.md)。

重复执行 `patch.sh` 与 `patch_external.sh` 应保持幂等。若固定源码树有无法由脚本精确解释的差异，流程会停止。

## 产物

主要产物默认写入 `kernel_out/sm8850-oryon1-kmi6-2026-09/`：

```text
luna-xiaomi17-g<项目提交前8位>-YYYYMMDD.zip
Image-luna-xiaomi17-g<项目提交前8位>-YYYYMMDD
```

发布闭包还包括完整兼容性审计归档、官方 KernelSU Manager APK，以及独立 IPSet 用户态产物。

AnyKernel3 ZIP 从固定官方脚本、可审查的 [`ak3_template/luna.patch`](../ak3_template/luna.patch)、固定 BusyBox 和 MagiskBoot 重新组装。它只替换 boot 中的 `Image`，不携带 DTB、DTBO、ramdisk、vendor module 或其他分区镜像。

## 提交身份

内核 release 字符串和产物名取自干净项目提交；有未提交更改时，`build.sh` 不会生成可发布闭包。历史整理后的新提交必须完整重建，不能沿用旧提交的产物摘要。

固定 KernelSU 快照的 Manager 使用同提交官方 CI 最终签名 APK，init 按提交复用缓存；首次下载需要已认证的 `gh`。ZIP/工作流来源、APK 摘要与 UAPI 版本均固定在 `.env`，不需要本地 Gradle 构建。配套更新及拒绝项见 [组件审计](COMPONENTS-2026-09-UPDATE.md)。
