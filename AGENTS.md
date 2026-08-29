# Luna Kernel 协作约束

本文是当前仓库的最高优先级项目约束。所有人工修改、自动化代理、构建与评审都必须遵守。`MUST` 表示不可跳过，`MUST NOT` 表示明确禁止。

## 1. 项目与基线

Luna Kernel 面向小米 17（当前真机代号 `pudding`），从小米官方 SM8850 `popsicle` 公开源码与官方 AOSP Android 16 GKI common 构建 4 KiB `Image`。月亮小巧、克制、纯净；项目也坚持最小改动、来源清晰和可验证，不以堆叠功能为目标。

内核发布字符串必须由干净的项目提交派生：

```text
6.12.23-android16-luna-g<项目提交前8位>-4k
```

两个基线仓库 MUST 独立存在、独立校验，禁止互相覆盖：

| 职责 | 项目内路径 | 上游 | 分支 | 固定提交 |
| --- | --- | --- | --- | --- |
| 小米 SoC/vendor 公开基线与完整性元数据 | `sources/xiaomi_sm8850_soc/` | `https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git` | `popsicle-w-oss` | `45705be1220b4cfa8100516ad86711656c0b634e` |
| 实际 GKI Image 源码 | `sources/aosp_common_6.12.23_r57/` | `https://android.googlesource.com/kernel/common` | `android16-6.12-2025-06_r57` | `a82fc641d6d2c687802606190c0a8c33a4242201` |

小米仓库 `android/ACK_SHA` 中的 r8 / `f1bdb13583da85a47fcf1632a78ef52d6e6da651` 只用于完整性检查，不是 Image 构建源。MUST 从 AOSP common 构建，MUST NOT 用小米仓库同名目录覆盖 common，也不得复制目录伪造单仓源码树。

## 2. 来源与改动边界

取证优先级为：固定的小米与 AOSP 上游、官方 AOSP/Linux 历史与 KMI 清单、已验证产物和真机日志。不得从无关整树内核复制实现，不得保留无关作者或项目品牌。实际集成的独立组件必须保留准确来源、固定提交及许可证信息。

当前固定组件：

- KernelSU v3.2.5：`b0bc817b4e966aa6aa830834eaf6ef765d821d40`，built-in，version code `32525`。
- SUSFS v2.2.0：`d9a486dc7197800149c31fe35a77997ea0ddaa83`；KernelSU 兼容补丁 `ef69c8322232340f43c78c7fc491b32cb9f7da86`。
- Baseband Guard：`1c664957da7539de860503940ee73c7447f1dfaf`，boot/recovery 分区保护关闭，其余能力启用。
- ADIOS 3.2.0：`08bf078aac99075a0bef73c2b2497574a82e4c41`，built-in 供运行时选择，不得应用其强制默认补丁；小米 17 多硬件队列存储保持基线默认的 `none`。
- TCP Brutal：`f11e52d88c7ad2285896de018c2d96d4687f0ab6`，仅提供运行时选择，CUBIC 保持默认。
- IPSet 7.24、libmnl 1.0.5 与 Android NDK r29：固定归档摘要和解压树摘要。

已授权的内核直接修复仅包括 `patch.sh` 可精确证明的 AOSP/Linux 官方修复、Unicode default-ignorable 兼容补丁及其测试。新增候选 MUST 先证明当前路径可达、问题真实、修复稳定且收益足够；理论优化、来源不清或无法单独验证的改动一律拒绝。

TCP Brutal 上游采用 GPL-3.0，而内核主体为 GPL-2.0-only。当前 built-in 产物仅用于授权测试；公开分发前 MUST 完成专项许可证兼容审查。

## 3. ABI/KMI 绝对红线

任何后续修复或改进都 MUST 同时保持：

- `vmlinux` 导出数：`18137`
- 完整 CRC 摘要：`65a6a73e3a16ff05c41dfe3d6916438200d8dde03a50fa9198bcd7301c893db3`
- QCOM/Xiaomi 4517 项 vendor KMI 摘要：`5980570208c7617a89e50f3b1cdf2fcd981f777cd249338fd2bec0071be8935b`
- 18137 项导出的 STG 类型图摘要：`ce67a05c7c522f62122c1322ebe65aced724dcf355ba42774144e5529fc2bc46`

导出集合、任一 CRC、类型图、UAPI、syscall、配置或模块矩阵发生变化即触发红线，MUST 拒绝，安全性或性能收益不能豁免。禁止伪造导出、硬编码跳过或以空模块掩盖失败。

## 4. 脚本职责

标准流程：

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

- `.env`：唯一受版本控制的 pin、构建身份和验证快照来源。
- `init.sh`：准备并校验固定源码、AOSP 官方工具链、Rust、build-tools、NDK 和只读官方审计仓库；不应用补丁、不编译。
- `patch.sh`：仅应用项目维护的直接内核修复；必须幂等。
- `patch_external.sh`：仅接入已准备的外部组件；不得下载。
- `build.sh`：生成配置、编译、执行 ABI/KMI/专项门禁并打包；不得准备源码。

固定源码仓库必须保持干净，或其差异能被补丁脚本用允许路径和 reverse-apply 精确证明。`sources/`、`environment/`、`kernel_out/`、日志、转储和测试包不得提交。不得在输出目录手工修改 `.config`、`Module.symvers` 或包内容绕过守卫。

## 5. 构建与发布门槛

- `bash -n init.sh patch.sh patch_external.sh build.sh tools/backport_audit.sh` 必须通过。
- common 版本必须为 6.12.23，QCOM/Xiaomi symbol list 必须存在。
- 最终配置固定 8132 行，`modules.order` 固定 102 个活动模块；变化必须审查，不得降低门槛放行。
- 4 KiB、SMP、PREEMPT、模块、MODVERSIONS、GENDWARFKSYMS、Android vendor hooks、IKCONFIG、CFI、Rust、BPF JIT、module BTF、FUSE BPF 必须启用。
- 16/64 KiB、`LOCALVERSION_AUTO`、`TRIM_UNUSED_KSYMS`、强制模块签名、Full/Thin LTO 必须关闭；使用 `LTO_NONE`。
- `BPF_UNPRIV_DEFAULT_OFF=y`；DMA-BUF system/CMA heaps 和项目锁定的 SMMU/IOMMU 配置必须保持关闭。
- seccomp 内核能力必须启用。KernelSU Manager 或获准 root 进程因官方 `disable_seccomp()` 显示 `Seccomp: 0` 属于预期；普通 Android 应用应为 `2`。
- Unicode UML 测试必须覆盖 Unicode 12.1 全部 4173 个 Default-Ignorable 码点并精确通过 87668 项。f2fs 使用 `LOOKUP_AUTO`，兼顾现有目录与新语义。
- LSM 展开后的 `MAX_LSM_COUNT` 必须精确为 4。
- 工具链归档必须来自固定 AOSP Gitiles 提交并先校验 SHA-256；重建安装树摘要必须保持 `67da74f00a801440ca7c256b028d94e6c85bf7168fbdecab62c3710384a25d5a`。

发布产物名称：

```text
luna-xiaomi17-g<项目提交前8位>-YYYYMMDD.zip
Image-luna-xiaomi17-g<项目提交前8位>-YYYYMMDD
```

AnyKernel3 只能替换 `Image`，必须含 `kernel.string=Luna Kernel for Xiaomi 17` 与 `do.devicecheck=0`，不得携带或修改 DTB、DTBO、vendor modules、ramdisk 或 boot header。模板必须由 `ak3_template/` 的固定官方脚本与本分支 Luna 差异补丁重新组装；BusyBox 和 MagiskBoot 必须按 `.env` 摘要校验，禁止提交预制模板 ZIP。IPSet 用户态命令继续作为独立 KernelSU 模块交付。

## 6. 真机验证

当前仅确认 `pudding` 范围，不得外推其他设备。发布前必须记录 `uname -a`、`/proc/version`、boot completed、slot/verified boot、cmdline、模块加载、Binder、BPF sysctl、dmesg、logcat 与 pstore，并排除 panic、Oops、watchdog、关键 vendor 模块 ABI 失败以及显示/存储启动故障。

必须分别验证 KernelSU/SUSFS/BBG、SELinux/LSM、IPSet 和 ext4/f2fs casefold 旧目录兼容。Unicode UML 通过不替代真实磁盘目录迁移测试。环境隐藏可使属性显示为 green/locked；验收时必须结合 bootconfig 和测试环境说明，不能把预期隐藏行为误判为内核失败。

## 7. 提交规范

提交标题采用 `<type>: <准确精炼中文描述>`，类型限 `chore`、`feat`、`fix`、`refactor`、`docs`。每个提交只回答一个问题；pin、功能、ABI 守卫、打包和文档应独立审查。提交前执行 `git diff --check`、脚本语法检查和与风险相称的构建验证。

遇到不确定项，先以固定上游、`Module.symvers`、IKCONFIG、已验证 Image 和日志建立证据。任何放宽 ABI 守卫、关闭安全/调试能力、扩大来源或改变 Image-only 边界的动作都必须暂停并向用户说明。
