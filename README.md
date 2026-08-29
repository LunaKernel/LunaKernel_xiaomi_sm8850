[English](README_EN.md)

# Luna Kernel

Luna Kernel 是面向小米 17（设备代号 `pudding`）HyperOS 4（Android 17）ROM 的 Linux 6.12.81、4 KiB GKI 内核。

“Luna”取月亮小巧、安静、纯净的意境。项目以小米公开内核源码和官方 AOSP GKI 为基线，加入有明确来源并经过门禁验证的功能、错误修复与轻量性能改进。

> 当前 HyperOS 4 / Android 17 分支仍在适配验证中。`OS4.0.0.9.XPCCNXM` 的同 OTA 模块闭包已经完成，可生成仅替换 `Image` 的候选测试包；小米 17 真机启动、功能和稳定性仍待验证，因此尚不作为正式版本发布。

## 支持范围

| 项目 | 当前状态 |
| --- | --- |
| 设备 | 小米 17 |
| 代号 | `pudding` |
| 系统 | HyperOS 4 / Android 17（适配验证中） |
| 内核 | Linux 6.12.81 |
| 页面大小 | 4 KiB |
| boot 分区 | 96 MiB（`100663296` 字节） |

当前只面向 `pudding`，不得外推到其他设备。

## 上游基线

| 用途 | 官方上游 | 固定版本 |
| --- | --- | --- |
| 小米 SM8850 SoC/vendor 公开基线 | [MiCode/Xiaomi_Kernel_OpenSource](https://github.com/MiCode/Xiaomi_Kernel_OpenSource) | `popsicle-w-oss` / `45705be1220b4cfa8100516ad86711656c0b634e` |
| GKI Image 源码 | [AOSP kernel/common](https://android.googlesource.com/kernel/common) | `android16-6.12-2026-06_r21` / `0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28` |

最终 `Image` 从 AOSP common 构建；小米公开源码提供 SoC 基线和兼容性元数据。AOSP 分支名中的 `android16` 是 GKI/KMI 名称，不代表目标系统仍是 Android 16。

固定目标 OTA 为 `OS4.0.0.9.XPCCNXM`。其中复用的 `system_dlkm` 构建指纹仍保留 Android 16 和 `OS4.0.0.8.XPCCN` 字段；这是该官方分区的原始元数据，项目会如实校验，不会将它改写成 Android 17。

## 已接入组件

| 组件 | 版本与作用 |
| --- | --- |
| [KernelSU](https://github.com/tiann/KernelSU) | v3.2.5，内置于内核并选择性回移已审查的官方修复；正式发布构建将配套上游官方 Manager APK |
| [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) | v2.2.0，与当前 KernelSU 版本配套；不编译 `OPEN_REDIRECT`，调试日志默认关闭、可按需启用 |
| [Baseband Guard](https://github.com/vc-teahouse/Baseband-guard) | 限制 KernelSU 授权进程直接写入基带与关键分区；boot/recovery 写保护保持关闭，以兼容正常刷写 |
| IPSet | 完整内核能力；正式发布时单独提供 Android arm64 命令与 KernelSU 模块 |

内核同时保留 BBR v1、FQ、seccomp、CFI、BPF JIT、module BTF、FUSE BPF、Rust 与 pKVM guest 能力。

## 修复与改进

Luna 使用更新的官方 r21 基线，并只回移该基线仍缺少、来自官方 AOSP/Linux 历史的改动，主要包括：

- F2FS 前台 GC、ACL/xattr，以及 EROFS、ext4 边界错误修复。
- futex PI、blk-cgroup、IPv6 MLD 与 KVM compound-page pin 等并发、边界和生命周期修复；新版 Binder、UFS、IDLETIMER 与主动回收 freezer 修复由 r21 基线直接提供。
- KernelSU Manager 身份校验、低内存失败路径，以及 Baseband Guard 设备身份复核与写入口修复。
- 回移 Linux/AOSP 已合入的 F2FS/UFS、块层与内存管理、BPF、TCP/IPv6 和 IPSet 并发及生命周期修复。
- timer base、F2FS 直接 I/O、EAS cpumask、blk-wbt、memcg rstat 与 TCP 接收时间戳快路径改进。

## 默认行为

- I/O 调度器使用小米基线的 `none`。
- TCP 拥塞控制默认使用 CUBIC，BBR v1 可按需选择。
- 非特权 BPF 默认关闭。
- seccomp 内核能力保持启用。KernelSU Manager 或获准 root 进程可能显示 `Seccomp: 0`；普通 Android 应用通常应显示 `2`。

## 构建

推荐在 Linux 环境准备 Bash、Git、curl、tar、unzip、7-Zip 和 GNU coreutils，然后执行：

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

- `init.sh`：准备并校验固定源码和工具链。
- `patch.sh`：应用 Luna 的官方回移修复与改进。
- `patch_external.sh`：接入固定版本的独立组件。
- `build.sh`：配置、编译，验证同 OTA 启动所需模块闭包，并生成配置、模块和 ABI/KMI 差异报告。

当前分支的构建输出目录为 `kernel_out/android17-r21/`。只有提供固定同 OTA `tmp/os4/system_dlkm.img`，通过身份、完整性和模块闭包门禁，并处理完参考快照漂移后，才会生成候选 ZIP、`Image`、完整兼容性审计归档、Manager APK 与 IPSet 产物。

重建 stock ABI 清单需要 `tmp/os4/` 中同一 OTA 的 `boot.img`、`vendor_boot.img`、`vendor_dlkm.img` 和 `system_dlkm.img`，以及提取脚本校验过的工具。`system_dlkm.img` 只用于兼容性验证，不会进入刷机包。

候选产物名称为：

```text
luna-xiaomi17-g<短提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<短提交>-YYYYMMDD
```

AnyKernel3 包只会替换 boot 中的 `Image`，不会携带或修改 DTB、DTBO、vendor modules、ramdisk 或 boot header。内核版本与产物短哈希来自项目提交，构建身份固定为 `luna@luna-build`。

## 验证状态

HyperOS 4 `OS4.0.0.9.XPCCNXM` 的 boot、vendor_boot、vendor_dlkm 与 system_dlkm 模块闭包已经完成。除未被启动参数选择的 `rust_binder.ko` 外，其余模块依赖均严格匹配；该模块缺失仅涉及 Rust 编译上下文符号，默认 C Binder 路径不依赖它。构建会把目标 OTA 模块所需符号、CRC、provider、namespace 和相关类型兼容性作为硬门禁；完整配置、模块矩阵及 ABI/KMI 快照仍会生成差异报告，但不再因为与参考摘要不同而一律拒绝。项目新增模块必须随对应 `Image` 验证加载和完整依赖。

小米 17 真机启动、功能与稳定性仍待验证，因此本分支尚未正式发布。

## 许可证

本项目由多个具有各自许可证的上游组件组成。公开分发前仍需完成统一的许可证兼容性审计；各组件继续受其原始许可证约束。
