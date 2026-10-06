[English](README_EN.md)

# Luna Kernel

Luna Kernel 是为小米 17（`pudding`）HyperOS 4 / Android 17 打造的 4 KiB GKI 内核。

“Luna”取月亮小巧、安静、纯净的意境。项目以小米官方公开源码和 AOSP GKI 为基线，在保持系统模块兼容的前提下，整合来源明确的修复、必要功能与轻量性能改进。

## 支持范围

| 项目 | 版本 |
| --- | --- |
| 设备 | 小米 17（`pudding`） |
| 目标系统 | HyperOS 4 `OS4.0.0.9.XPCCNXM` / Android 17 |
| 内核 | Linux 6.12.92、4 KiB |
| AOSP 基线 | `android16-6.12-2026-09` |
| 安装方式 | AnyKernel3，仅替换 boot 中的 `Image` |

本项目只支持上述设备与系统版本。刷写前请备份当前 boot，并确保能够进入 Fastboot 或 Recovery 恢复。

## 上游

- 小米 SM8850 公开基线：[MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource)，`popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e`
- 实际 GKI Image 源码：[AOSP kernel/common](https://android.googlesource.com/kernel/common)，`android16-6.12-2026-09` @ `0316e9866fdf55601aae97b14ee08d1b38a3916c`

`android16` 是 GKI/KMI 分支名；目标 ROM 为 Android 17。

## 功能与改进

- KernelSU `v3.3.0-50-g623eba3e`（内置，UAPI 4，配套官方 Manager）。
- SUSFS v2.3.0；`OPEN_REDIRECT` 未编译，调试日志默认关闭。
- Baseband Guard，保护基带及关键块设备写入口。
- IPSet 7.24 内核支持与独立 KernelSU 用户态模块。
- 保留 seccomp、CFI、BPF JIT、FUSE BPF、Rust、pKVM guest、BBR v1 与 FQ 等能力。
- 回移 AOSP、Linux stable 和 mainline 中当前基线仍缺少的文件系统、内存、调度、块层、网络与安全修复。

完整回移来源与顺序见 [`patches/backports/`](patches/backports/)；独立回移可单独审计和回退。

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

## 验证状态

当前已验收基准为 `6.12.92-android16-luna-g8eb963eb-4k`，实机为 `.32` OTA，构建兼容性清单仍固定于 `.9` OTA。Rust Binder 加载屏蔽待下次编译和实机验收；目录整理后的新提交不继承旧 Image 的验收身份。详见 [验证记录](docs/VALIDATION.md)。

## 文档

- [构建环境、输入与验证方法](docs/BUILDING.md)
- [验证记录](docs/VALIDATION.md)
- [维护与回移](docs/MAINTENANCE.md)
- [贡献说明](CONTRIBUTING.md)
- [安全问题](SECURITY.md)

## 许可证

项目自有脚本与补丁按 [GPL-2.0-only](LICENSE) 发布。集成组件继续受各自许可证约束。
