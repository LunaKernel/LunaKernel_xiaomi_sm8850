# Luna Kernel

Luna Kernel 是为小米 17（`pudding`）HyperOS 4 / Android 17 打造的 4 KiB GKI 内核。

项目以小米官方公开源码和 AOSP GKI 为基线，集成可追溯修复、KernelSU/SUSFS 与 SM8850 编译优化，保留目标系统模块兼容性检查。

## 支持范围

| 项目 | 版本 |
| --- | --- |
| 设备 | 小米 17（`pudding`） |
| 实机验收系统 | HyperOS 4 `OS4.0.6.0.XPCCNXM` / Android 17 |
| 静态模块闭包 | `OS4.0.6.0.XPCCNXM` |
| 内核 | Linux 6.12.92、4 KiB |
| AOSP 基线 | `android16-6.12-2026-09_r11` / KMI generation 6 |
| 安装方式 | AnyKernel3，仅替换 boot 中的 `Image` |

已验收 Image 与系统版本见[验证记录](docs/VALIDATION.md)。刷写前请备份当前 boot，并确保能够进入 Fastboot 或 Recovery 恢复。

## 上游

- 小米 SoC/vendor 公开基线：[MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource)，`popsicle-w-oss`。
- 实际 GKI Image 源码：[AOSP kernel/common](https://android.googlesource.com/kernel/common)，`android16-6.12-2026-09_r11`。

`android16` 是 GKI/KMI 分支名；目标 ROM 为 Android 17。源码、组件与工具链的完整提交和摘要统一固定于 [`.env`](.env)。

## 功能与改进

- KernelSU 内置，version code 32712 / UAPI 6；每次交付配套官方 CI Manager APK。
- SUSFS v2.3.0；`OPEN_REDIRECT` 未编译，调试日志默认关闭。
- Baseband Guard，保护基带及关键块设备写入口。
- IPSet 7.24 内核支持与独立 KernelSU 用户态模块。
- Rust Binder 内置，屏蔽 ROM 同名模块；保留 seccomp、CFI、BPF JIT、FUSE BPF、pKVM guest、BBR v1 与 FQ 等能力。
- Oryon-1 调度、固定 SM8850 ISA、AutoFDO 与仅对有 profile 函数启用的 ExtTSP；保持 O2 和 `LTO_NONE`。
- 回移 AOSP、Linux stable 和 mainline 中当前基线仍缺少的文件系统、内存、调度、块层、网络与安全修复。

完整回移来源与顺序见 [`patches/backports/`](patches/backports/)；独立回移可单独审计和回退。

## 构建

按 [构建说明](docs/BUILDING.md) 依次执行 `init.sh`、`patch.sh`、`patch_external.sh`、`build.sh`。固定依赖由 [ci-dependencies](https://github.com/LunaKernel/ci-dependencies) 制作与托管。通过内容、模块闭包与发布检查后，交付 Image、AnyKernel3 ZIP、官方 Manager APK、IPSet 组件和构建审计。

## 验证状态

`6.12.92-android16-luna-g1d3c30f1-4k` 已在 `OS4.0.6.0.XPCCNXM` 完成实机验收，并通过同一 OTA 的静态模块闭包核对；具体范围见 [验证记录](docs/VALIDATION.md)。

## 文档

- [构建环境、输入与验证方法](docs/BUILDING.md)
- [验证记录](docs/VALIDATION.md)
- [贡献与回移维护](CONTRIBUTING.md)
- [安全问题](SECURITY.md)

## 许可证

项目自有脚本与补丁按 [GPL-2.0-only](LICENSE) 发布。集成组件继续受各自许可证约束。
