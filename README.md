[English](README_EN.md)

# Luna Kernel

Luna Kernel 是为小米 17（`pudding`）HyperOS 4 / Android 17 打造的 4 KiB GKI 内核。

“Luna”取月亮小巧、安静、纯净的意境。项目以小米官方公开源码和 AOSP GKI 为基线，在保持系统模块兼容的前提下，整合来源明确的修复、必要功能与轻量性能改进。

## 支持范围

| 项目 | 版本 |
| --- | --- |
| 设备 | 小米 17（`pudding`） |
| 目标系统 | HyperOS 4 `OS4.0.0.9.XPCCNXM` / Android 17 |
| 内核 | Linux 6.12.81、4 KiB |
| AOSP 基线 | `android16-6.12-2026-06_r21` |
| 安装方式 | AnyKernel3，仅替换 boot 中的 `Image` |

本项目只支持上述设备与系统版本。刷写前请备份当前 boot，并确保能够进入 Fastboot 或 Recovery 恢复。

## 上游

- 小米 SM8850 公开基线：[MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource)，`popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e`
- 实际 GKI Image 源码：[AOSP kernel/common](https://android.googlesource.com/kernel/common)，`android16-6.12-2026-06_r21` @ `0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28`

AOSP 分支名中的 `android16` 是 GKI/KMI 分支名称；目标 ROM 为 Android 17。

## 功能与改进

- KernelSU v3.2.5（内置）及经过审查的官方后续修复。
- SUSFS v2.2.0；`OPEN_REDIRECT` 未编译，调试日志默认关闭。
- Baseband Guard，保护基带及关键块设备写入口。
- IPSet 7.24 内核支持与独立 KernelSU 用户态模块。
- 保留 seccomp、CFI、BPF JIT、FUSE BPF、Rust、pKVM guest、BBR v1 与 FQ 等能力。
- 回移 AOSP、Linux stable 和 mainline 中当前基线仍缺少的文件系统、内存、调度、块层、网络与安全修复。

完整回移来源与顺序记录在 [`patches/backports/`](patches/backports/)；每个独立回移都可以单独审计和回退。

## 构建

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

构建会校验固定源码、工具链、目标 OTA 模块闭包和发布输入，生成：

```text
luna-xiaomi17-g<短提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<短提交>-YYYYMMDD
```

详细环境、输入与验证方法见 [构建文档](docs/BUILDING.md)。

## 验证状态

r21 内核树已在小米 17、HyperOS 4 `OS4.0.0.9.XPCCNXM` 上完成启动和持续使用验证；目标 OTA 的模块闭包也已通过。公开历史整理改变了项目提交哈希，因此新的公开提交仍需重新完整构建并复测后才会发布二进制版本。

详见 [验证记录](docs/VALIDATION.md)。

## 文档

- [构建](docs/BUILDING.md)
- [验证](docs/VALIDATION.md)
- [维护与回移](docs/MAINTENANCE.md)
- [贡献说明](CONTRIBUTING.md)
- [安全问题](SECURITY.md)

## 许可证

项目自有脚本与补丁按 [GPL-2.0-only](LICENSE) 发布。集成组件继续受各自许可证约束。
