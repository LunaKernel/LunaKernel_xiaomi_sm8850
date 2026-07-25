[English](README_EN.md)

# Luna Kernel

Luna Kernel 是面向小米 17（设备代号 `pudding`）的 Android 16、Linux 6.12.23、4 KiB GKI 内核。

“Luna”取月亮小巧、安静、纯净的意境。项目以小米公开内核源码和官方 AOSP GKI 为基线，在保持设备兼容性的同时，加入经过验证的功能、错误修复和轻量性能改进。

## 支持范围

| 项目 | 当前支持 |
| --- | --- |
| 设备 | 小米 17 |
| 代号 | `pudding` |
| Android | Android 16 |
| 内核 | Linux 6.12.23 |
| 页面大小 | 4 KiB |
| boot 分区 | 96 MiB（`100663296` 字节） |

当前仅面向 `pudding`。请勿在其他设备上刷入。

## 上游基线

| 用途 | 官方上游 | 固定版本 |
| --- | --- | --- |
| 小米 SM8850 SoC/vendor 公开基线 | [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) | `popsicle-w-oss` / `45705be1220b4cfa8100516ad86711656c0b634e` |
| GKI Image 源码 | [AOSP kernel/common](https://android.googlesource.com/kernel/common) | `android16-6.12-2025-06_r57` / `a82fc641d6d2c687802606190c0a8c33a4242201` |

最终 `Image` 从 AOSP common 构建；小米公开源码用于 SoC 基线和兼容性校验。

## 已集成功能

| 组件 | 版本与作用 |
| --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | v3.2.5，内置于内核；同时输出官方签名的 Manager APK |
| [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) | v2.2.0，与当前 KernelSU 版本配套 |
| [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard) | 提供基带与关键分区保护；boot/recovery 写保护保持关闭，以兼容正常刷写 |
| [ADIOS](https://github.com/firelzrd/adios) | v3.2.0，可在运行时选择；默认 I/O 调度仍为小米基线的 `none` |
| [TCP Brutal](https://github.com/apernet/tcp-brutal) | 提供运行时可选的拥塞控制；默认仍为 CUBIC |
| IPSet | 完整内核能力，并单独提供 Android arm64 命令和 KernelSU 模块 |

内核还保留 BBR v1、FQ、seccomp、CFI、BPF JIT、module BTF、FUSE BPF 和 Rust 等 Android GKI 能力。

## 修复与改进

Luna 在固定基线上回移了来自官方 AOSP/Linux 的修复，主要包括：

- F2FS 加密写回、inode 生命周期、前台 GC、atomic inode、ACL 与 xattr 边界修复。
- EROFS 目录尾和 ext4 扩展属性边界修复。
- futex PI、timer、eventpoll、cgroup、blk-cgroup、page pool 与 conntrack 并发修复。
- Binder transaction 生命周期、Gunyah 资源清理和 UFS 运行时电源管理错误恢复修复。
- IPv6 MLD 查询和 rtmutex 错误路径修复。
- Unicode 12.1 Default-Ignorable 字符处理修复，并兼容已有 ext4/f2fs casefold 目录。

当前还包含 F2FS 打开与直接 I/O、memcg 统计、TCP 接收时间戳、timer base、EAS CPU mask 和 blk-wbt 等快路径改进。

## 默认行为

- I/O 调度器默认：`none`。ADIOS 仅供用户按需切换。
- TCP 拥塞控制默认：CUBIC。BBR v1 和 TCP Brutal 仅供用户按需切换。
- 非特权 BPF 默认关闭。
- seccomp 内核能力保持启用。KernelSU Manager 或获准 root 进程可能显示 `Seccomp: 0`，这是 KernelSU 的预期行为；普通 Android 应用通常应显示 `2`。

## 安装

刷写前请确认：

1. 设备确实为小米 17（`pudding`）。
2. 已备份原始 boot 镜像，并准备好可用的恢复方式。
3. 下载的文件名符合 `luna-xiaomi17-g<短提交>-YYYYMMDD.zip`。

刷写包基于 [AnyKernel3](https://github.com/osm0sis/AnyKernel3)，仅替换当前槽位 boot 中的 `Image`，不会携带或替换 DTB、DTBO、vendor modules 或 vendor ramdisk。刷写时会核对 boot 分区容量，并在重组镜像超过 96 MiB 时中止。

刷写内核始终存在无法启动或数据丢失风险，请确保能够恢复原始 boot。

## 构建

推荐在 Linux 环境构建。准备 Bash、Git、curl、tar、unzip、7-Zip 和 GNU coreutils 后执行：

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

- `init.sh`：准备并校验固定源码和工具链。
- `patch.sh`：应用 Luna 内核修复与改进。
- `patch_external.sh`：接入固定版本的独立组件。
- `build.sh`：配置、编译、测试并打包产物。

构建产物位于 `kernel_out/`，主要文件名为：

```text
luna-xiaomi17-g<短提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<短提交>-YYYYMMDD
```

构建还会输出 KernelSU Manager、SUSFS 辅助文件和 IPSet KernelSU 模块。内核版本和产物短哈希来自当前项目提交，构建身份固定为 `luna@luna-build`。

## 验证状态

当前功能组合已经通过完整编译、配置检查、Unicode 测试及 ABI/KMI 检查，并已在小米 17 `pudding` 上完成启动和基础功能验证。

## 许可证

本项目由多个具有各自许可证的上游组件组成。公开分发前仍需完成统一的许可证兼容性审计；各组件继续受其原始许可证约束。
