# Luna Kernel 协作约束

本仓库最高优先级项目约束，适用于人工修改、自动化代理、构建与评审。`MUST` 表示必须，`MUST NOT` 表示禁止。

## 1. 项目与基线

Luna Kernel 面向小米 17（`pudding`）HyperOS 4（Android 17），以小米官方 SM8850 `popsicle` 为 SoC/vendor 基线，从官方 AOSP `android16-6.12` KMI generation 6 common 构建 4 KiB `Image`。固定 OTA 为 `OS4.0.0.9.XPCCNXM`，metadata `post-build` 为 `Xiaomi/pudding/pudding:17/CP2A.260605.016/17OS4.0.260809.194304611.QCPECN.S:user/release-keys`。`android16` 是 GKI/KMI 名称，不代表目标 Android 版本。该 OTA 复用的 `system_dlkm` fingerprint 含 Android 16 与 `OS4.0.0.8.XPCCN` 原始字段，MUST 保留，不得据此单独否定 OTA 目标版本。

内核发布字符串必须由干净的项目提交派生：

```text
6.12.92-android16-luna-g<项目提交前8位>-4k
```

两个基线仓库 MUST 独立存在、独立校验，禁止互相覆盖：

| 职责 | 项目内路径 | 上游 | 分支 | 固定提交 |
| --- | --- | --- | --- | --- |
| 小米 SoC/vendor 公开基线与完整性元数据 | `sources/xiaomi_sm8850_soc/` | `https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git` | `popsicle-w-oss` | `45705be1220b4cfa8100516ad86711656c0b634e` |
| 实际 GKI Image 源码 | `sources/aosp_common_6.12.92_kmi6_2026-09/` | `https://android.googlesource.com/kernel/common` | `android16-6.12-2026-09` | `0316e9866fdf55601aae97b14ee08d1b38a3916c` |

Image MUST 从 AOSP common 构建。小米仓库 `android/ACK_SHA` 中的 r8 / `f1bdb13583da85a47fcf1632a78ef52d6e6da651` 仅用于完整性检查；不得复制目录伪造单仓源码树。

## 2. 来源与改动边界

取证优先级为：固定的小米与 AOSP 上游、官方 AOSP/Linux 历史与 KMI 清单、已验证产物和真机日志。不得从无关整树内核复制实现，不得保留无关作者或项目品牌。实际集成的独立组件必须保留准确来源、固定提交及许可证信息。

当前固定组件：

- KernelSU v3.3.0：`932014ab5b2c9b74a3d11e2ec4d17dd10fc9442e`，built-in，version code `32601`。此前单独回移的 `e9e5b616` 与 `be53d75f` → `e6cc0ef7` → `aab67974` 修复链已原样进入该 stable，MUST 使用上游实现并删除重复回移层。`c20d48a` 修改的 object 被 SUSFS 官方兼容层从 Kbuild 移除，不得视为当前组合中的有效功能。
- SUSFS v2.3.0：`c7db8cb367ef3ed4126ed7e222d77757ccb5c05b`；KernelSU 官方兼容补丁取自同一提交并原样应用。`OPEN_REDIRECT` MUST 在编译期关闭；内核日志静态键 MUST 默认关闭，仅允许显式运行时启用。
- Baseband Guard：`a54e0dc6cf0aff4dd87fec49644a02d2eb612905`，叠加项目固定的无缓存块设备身份复核、固定上游判定的破坏性 block ioctl 与 UFS BSG 原始命令封堵、`io_uring discard`/共享可写映射入口保护、KernelSU 授权凭据标记与最小限速拒绝日志；boot/recovery 分区保护关闭，其余能力启用。
- IPSet 7.24、libmnl 1.0.5 与 Android NDK r29：固定归档摘要和解压树摘要。

内核直接修复仅授权 `patch.sh` 可精确证明的 AOSP/Linux 官方修复。新增候选 MUST 机制清晰、关联小米 17 实际路径、来自稳定官方历史、无回退或明显回归证据，并通过第 3、5 节硬门禁及完整差异审计；拒绝收益极小、路径无关、来源不清或逻辑证据不足的改动。缺少实机性能数据本身不构成否决，不得将机制不明的猜测视为优化。r21 已原样包含主动回收响应 freezer 的 AOSP 修复 `bee364ffffd30532ef586a10bb42b505ed347988`，不得重复回移。

九月回移集合 `patches/backports/kmi6-2026-09-selected-backports.tsv` 有序且不可拆分：19 项逻辑修复、23 个应用提交。r21 中已被新基线吸收的层及普通 F2FS write-end 上下文适配已删除，逐项证据见 `patches/backports/kmi6-2026-09-absorption.tsv`。新增高置信回移 MUST 置于 `patches/backports/kmi6-2026-09-independent/`（当前 31 个可独立回退逻辑项），每个清单仅含一个逻辑项，不可拆的官方前置/补修链必须同清单。每个清单必须独立 pin SHA-256，并通过临时 Git index 证明可从固定基础差异单独应用、撤销及按固定顺序完整重放。授权不含清单外提交；触及配置、UAPI、syscall、ABI 或 KMI 的候选必须逐项说明影响，不得破坏目标 OTA 模块闭包、关键启动配置或既有用户态语义。

r21 对 `struct tegra_mc` 的私有类型重构使固定 OTA 实际消费的 `devm_tegra_memory_controller_get` 与 `tegra_mc_probe_device` 产生 CRC 漂移。`patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch` 只使用 `ANDROID_KABI_TYPE_STRING` 固定这两个不透明指针接口的版本字符串，不改变函数机器 ABI、运行时代码或结构体布局；该窄兼容补丁及其 SHA-256、patch-id MUST 固定并纳入源码差异门禁。

## 3. 小米 17 可启动兼容性硬门禁

ABI/KMI 硬门禁仅针对固定小米 17 同一 OTA 模块闭包实际消费的接口及相关类型兼容性。待放行版本 MUST 同时满足：

- 覆盖固定 OTA 的 `boot`、`vendor_boot`、`vendor_dlkm`、`system_dlkm` 中全部实际使用及可能按硬件、服务或运行时路径加载的内核模块，不限于单次启动已加载子集。
- 对上述目标模块闭包中的每个依赖，验证符号存在、CRC、provider、导出类型、namespace、依赖顺序、vermagic 和相关 ABI 类型兼容；不得出现 unknown symbol、CRC disagreement、namespace 拒绝、vermagic/CFI/BTF 不兼容或伪造 provider。
- 保持 arm64、4 KiB、对应 GKI/KMI generation、模块版本机制以及启动、存储、显示、Binder、SELinux/LSM、seccomp、BPF 和设备安全路径所需的关键配置与语义。
- 项目新增的 built-in 能力或 `.ko` 不得破坏 stock 闭包；新增 `.ko` 必须随对应 `Image` 同次构建，并独立证明可加载、依赖完整及功能正常。
- 真机完成启动、全部预期模块加载、关键硬件和项目功能验证，并排除 panic、Oops、watchdog、关键模块加载失败及持续性严重错误。

目标闭包符号删除、CRC/provider/namespace/相关类型不兼容或关键启动配置破坏均为绝对拒绝项，安全性或性能收益不能豁免。禁止删除验证对象、伪造导出、硬编码跳过、扩大例外或以空模块掩盖失败；唯一固定 `rust_binder.ko` 例外见第 5 节。

全量导出、STG 类型图、配置和模块矩阵是参考快照：哈希、项目数或顺序变化本身不是 ABI/KMI 硬失败或补丁拒绝理由。构建 MUST 报告参考值与本次值、生成结构化漂移摘要并保留本次完整快照。r21 历史参考值如下（新基线构建漂移须逐项审查后更新）（配置与模块清单见第 5 节）：

- 完整 `Module.symvers`：`19703` 项，五列摘要 `a43d640d6146385d8d71f6e38d2e84487d9f47d15ff5418b78764accc477bb09`
- `vmlinux`：`19105` 项导出，CRC 摘要 `aa089112cbed9f681b329520cb01f0f2ec6fc50a51399c3e7a39ab26026ec91b`
- QCOM/Xiaomi vendor KMI 并集：`4723` 项，摘要 `f60e16b2517ba1be4cafc1855688d26ac6c8ef6b7fea848a08de552627a70664`
- 上述 `19105` 项导出的完整 STG 类型图摘要：`d8176f381baff13ba86271412ff76712c749432c8e039feb68cf3be4a35c0073`

差异审计必须分开记录目标闭包硬门禁与全量快照漂移。目标消费者相关变化须证明完全兼容；无目标消费者的变化须用途明确且无回归。必要配置变化、新增项目模块及其必要导出、模块排序变化均须遵守上述要求，不得绕过关键配置和闭包门禁。出现 `DRIFT` 时必须先保留本次快照、完成影响审查，并在同一变更中更新参考摘要；未确认漂移不得进入发布闭包，也不得放宽 UAPI、syscall 或用户态语义审查。

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
- `build.sh`：生成配置、编译，执行第 3、5 节门禁与快照审计；仅在发布闭包齐全且无未确认漂移后打包，不得准备源码。

固定源码仓库必须保持干净，或其差异能被补丁脚本用允许路径和 reverse-apply 精确证明。`sources/`、`environment/`、`kernel_out/`、日志、转储和测试包不得提交。不得在输出目录手工修改 `.config`、`Module.symvers` 或包内容绕过守卫。

## 5. 构建与发布门槛

- `bash -n init.sh patch.sh patch_external.sh build.sh tools/backport_audit.sh tools/backport_manifest.sh tools/independent_backports.sh` 必须通过。
- common 版本必须为 `.env` 固定的 6.12.92，QCOM/Xiaomi symbol list 必须存在。
- 参考配置：8236 行、摘要 `b35ffd54c23acf009c1819d01614ecc40b53845b1bb3e7b6b7018622e872c935`；参考 `modules.order`：104 个活动模块、摘要 `03c98eead97e20de6f0fb74c8103e1bcde6ffddd254016b49dfd0aa5097d389d`。按第 3 节报告、保留并审查快照。
- 4 KiB、SMP、PREEMPT、模块、MODVERSIONS、BASIC/EXTENDED_MODVERSIONS、GENDWARFKSYMS、Android vendor hooks、IKCONFIG、CFI、Rust、BPF JIT、module BTF、MODULE_ALLOW_BTF_MISMATCH、FUSE BPF、BLK_WBT_MQ 必须启用。
- 16/64 KiB、`LOCALVERSION_AUTO`、`TRIM_UNUSED_KSYMS`、强制模块签名、Full/Thin LTO 必须关闭；使用 `LTO_NONE`。
- `BPF_UNPRIV_DEFAULT_OFF=y`；DMA-BUF system/CMA heaps、GUNYAH_QCOM_PLATFORM、ARM_SMMU、ARM_SMMU_V3、ARM_SMMU_V3_PKVM 与 QCOM_IOMMU 必须保持关闭。ARM_PKVM_GUEST、VFIO_PKVM_IOMMU 与 PKVM_PVIOMMU 必须启用。
- seccomp 内核能力必须启用。KernelSU Manager 或获准 root 进程因官方 `disable_seccomp()` 显示 `Seccomp: 0` 属于预期；普通 Android 应用应为 `2`。
- 保留 AOSP r21 原生 Unicode/casefold 语义，F2FS 使用默认 `LOOKUP_PERF`。
- LSM 展开后的 `MAX_LSM_COUNT` 必须与实际启用的 LSM 数量精确一致；当前参考值为 6，BBG 占 1 槽，KernelSU 不得额外注册 LSM。
- clang 归档必须来自固定 AOSP Gitiles 提交并先校验 SHA-256，Rust 与 build-tools 必须来自固定 Git subtree；完整工具链安装树摘要必须保持 `65644bd77ed4ecde7239e3ce5a4aa53451a28c0a52b12394b88c5bd095517cc0`。
- stock 清单覆盖 HyperOS 4 `OS4.0.0.9.XPCCNXM` 同一 OTA 的 boot/vendor_boot/vendor_dlkm/system_dlkm，可证明 4083 项实际 vmlinux 依赖，v5 清单摘要为 `866afc7ea549ff8aa13a53f28d242396f1a8fa356ead345709cc1b7f7a16136a`；对应五列硬门禁 tuple 摘要为 `d3add92d15233b79b94c354ad6bd74a254c8be94eba2b2c199369dc80f6a6555`。固定 system_dlkm 输入含 103 个 stock 模块，其中 102 个必须严格闭包；固定 `rust_binder.ko` 的 234 项需求必须精确保持 167 项 vmlinux/CRC 匹配、67 项 Rust 构建上下文符号缺失、0 项 CRC 或 provider 异常。该模块仅在固定启动输入未选择 Rust Binder、无导出、无模块依赖且无反向依赖的前提下作为精确例外。例外不得扩大到其他模块或更多缺失项。项目自身新增模块不计入这 103 个 stock 模块，但必须通过第 3 节所述加载与依赖门禁。
- 同 OTA `tmp/os4/system_dlkm.img` 固定为 17281024 字节、SHA-256 `7918f34b6ae9210b8470abbe1ee52f2fc72da04bfa241627ab0c66f340ab9816`。`build.sh` 必须校验整镜像身份、AVB hashtree 自洽、EROFS 完整性以及与 stock 清单绑定关系；镜像缺失或不匹配时 MUST 在打包前失败。重建 stock 清单还需固定的 Xiaomi 四个分区镜像以及脚本校验过的 `unpack_bootimg`、`bsdtar`、kmod 和 EROFS 工具。

发布产物名称：

```text
luna-xiaomi17-g<项目提交前8位>-YYYYMMDD.zip
Image-luna-xiaomi17-g<项目提交前8位>-YYYYMMDD
```

AnyKernel3 只能替换 `Image`，必须含 `kernel.string=Luna Kernel for Xiaomi 17` 与 `do.devicecheck=0`，不得携带或修改 DTB、DTBO、vendor modules、ramdisk 或 boot header。模板必须由 `ak3_template/` 中固定的官方脚本基线与 Luna 差异补丁重新组装；BusyBox 和 MagiskBoot 必须来自 `.env` 固定来源并在使用前校验摘要，禁止重新提交预制模板 ZIP。IPSet 用户态命令继续作为独立 KernelSU 模块交付。

当前 KernelSU 仍为 built-in，本轮不得借门禁重构改变交付边界。若后续经专项审计切换为 LKM，面向用户必须保持单一安装入口，不得要求分别管理或手工刷入两个分区镜像；该专项还必须新增模块交付、逐项依赖与真机加载门禁，不能把 `modules.order` 中存在 `.ko` 当成已完成验证。首次安装后只有在驻留 LKM 与新 `Image` 的完整依赖闭包通过同等硬门禁时，才允许仅更新或直接刷入已组装的 boot 镜像。

## 6. 真机验证

公开历史整理前的 r21 项目提交 `838d2857` 已在 `pudding` 与固定 HyperOS 4 OTA 上完成启动、功能和持续使用验证；对应内核 release 为 `6.12.81-android16-luna-g838d2857-4k`，且未在提供的日志中发现 panic、Oops、watchdog、关键 vendor 模块 ABI 失败或持续性显示/存储错误。该结论不得外推到其他设备、OTA 或因历史整理产生的新项目哈希。公开主分支最终提交在发布前仍 MUST 重新完成同一 OTA 的完整构建、`system_dlkm` 闭包证明和真机复测，并记录 `uname -a`、`/proc/version`、boot completed、slot/verified boot、cmdline、模块加载、Binder、BPF sysctl、dmesg、logcat 与 pstore。

必须分别验证 KernelSU/SUSFS/BBG、SELinux/LSM 和 IPSet。环境隐藏可使属性显示为 green/locked；验收时必须结合 bootconfig 和测试环境说明，不能把预期隐藏行为误判为内核失败。

## 7. 提交规范

提交标题采用 `<type>: <准确精炼中文描述>`，类型限 `chore`、`feat`、`fix`、`refactor`、`docs`。pin、功能、可启动兼容性硬门禁、全量差异审计、打包和文档应独立审查。提交前执行 `git diff --check`、脚本语法检查和与风险相称的构建验证。

不确定项先以固定上游、stock 模块闭包、`Module.symvers`、IKCONFIG、已验证 Image 和日志取证。放宽目标 OTA 可启动闭包硬门禁、关闭安全/调试能力、扩大来源或改变 Image-only 边界前，必须暂停并向用户说明；快照变化按第 3 节完整报告和审查，不得静默接受。
