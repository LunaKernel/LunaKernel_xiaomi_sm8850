# Luna Kernel 协作约束

本仓库最高优先级项目约束，适用于人工修改、自动化代理、构建与评审。`MUST` 表示必须，`MUST NOT` 表示禁止。本文中的代码路径均相对于仓库根目录，命令均在仓库根目录执行。

用户已明确授权：本项目根目录 `.env` 在后续项目维护中可按需读取，无需逐次询问。此授权仅覆盖该文件，不扩展到其他 `.env*`、凭据或受限文件，也不授权向外部发送敏感内容。

## 1. 项目与基线

Luna Kernel 面向小米 17（`pudding`）HyperOS 4 / Android 17，以小米 SM8850 `popsicle` 为 SoC/vendor 基线，从官方 AOSP `android16-6.12` KMI generation 6 common 构建 4 KiB `Image`。固定 OTA 为 `OS4.0.6.0.XPCCNXM`，metadata `post-build` 为 `Xiaomi/pudding/pudding:17/CP2A.260605.016/17OS4.0.261026.212859010.QCPECN.S:user/release-keys`。`android16` 是 GKI/KMI 名称；system_dlkm fingerprint 的 Android 16 与 `OS4.0.6.0.XPCCN` 原始字段必须保留，不得据此否定 OTA 的 Android 17 身份。

内核发布字符串必须由干净的项目提交派生：

```text
6.12.92-android16-luna-g<项目提交前8位>-4k
```

两个基线仓库 MUST 独立存在、独立校验，禁止互相覆盖：

| 职责 | 项目内路径 | 上游 | 分支 | 固定提交 |
| --- | --- | --- | --- | --- |
| 小米 SoC/vendor 公开基线与完整性元数据 | `sources/xiaomi_sm8850_soc/` | `https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git` | `popsicle-w-oss` | `45705be1220b4cfa8100516ad86711656c0b634e` |
| 实际 GKI Image 源码 | `sources/aosp_common_6.12.92_kmi6_2026-09/` | `https://android.googlesource.com/kernel/common` | `android16-6.12-2026-09_r11` 发布标签 | `aa556307b679df7ced0cc644068a529280dbc412` |

Image MUST 从 AOSP common 构建。小米仓库 `android/ACK_SHA` 中的 r8 / `f1bdb13583da85a47fcf1632a78ef52d6e6da651` 仅用于完整性检查；不得复制目录伪造单仓源码树。

## 2. 来源与改动边界

取证优先级为：固定的小米与 AOSP 上游、官方 AOSP/Linux 历史与 KMI 清单、已验证产物和真机日志。不得从无关整树内核复制实现，不得保留无关作者或项目品牌。实际集成的独立组件必须保留准确来源、固定提交及许可证信息。

组件版本和全部来源、摘要以 `.env` 为唯一 pin 来源；集成边界如下：

- KernelSU main `51c21786`：built-in，32712 / UAPI 6。精确重放 SUSFS 兼容层，保留新版 SELinux 修复；不得将其等同于 SUSFS 原配旧树，或把被移出 Kbuild 的 syscall_hook_manager object 计作有效功能。已吸收修复使用上游实现、删除重复层。preinit runner 保持启用，按 arm64 静态用户态 ELF 审计并嵌入 Image，不能套用内核参数。
- SUSFS v2.3.0 `6b60a305`：common 与 KernelSU 兼容补丁取自同一提交；内核能力启用，模块 ZIP 和独立 helper 不交付。保留差异及吸收依据见 `patches/susfs/6b60a30-absorption.tsv`，不保留重复补修或无用上下文层。`OPEN_REDIRECT` 因 readlink 返回值及短 buffer 语义缺陷保持编译期关闭，等待完整上游修复，不维护禁用路径的重复代码删除。日志静态键默认关闭，仅允许显式运行时启用。
- Baseband Guard `028ff7fd`：保留无缓存块设备身份复核、固定上游判定的破坏性 ioctl/UFS BSG 封堵、io_uring discard/共享可写映射保护、KernelSU 凭据标记和限速拒绝日志。file_permission/mmap_file/file_mprotect 在凭据检查前排除无关操作和非块设备；仅 boot/recovery 分区保护关闭，其余保护启用。
- IPSet 7.24、libmnl 1.0.5 与 Android NDK r30：固定归档摘要和解压树摘要。

内核直接修复仅授权 `patches/patch.sh` 可精确证明的 AOSP/Linux 官方修复。新增候选 MUST 机制清晰、关联小米 17 实际路径、来自稳定官方历史、无回退或明显回归证据，并通过第 3、5 节门禁与差异审计；拒绝收益极小、路径无关、来源不清或证据不足的改动。缺少实机性能数据本身不构成否决，但不得把猜测视为优化。已被基线吸收的修复不得重复回移。

Kbuild 特例仅授权 `kbuild-next-speedups` 固定快照的 kallsyms token 索引与参数探测缓存链，由独立清单 670、680 固定，来源对象由依赖仓库审计。须证明生成结果、参数顺序等价，保留 6.12 原生 Kconfig 语法、工具链门禁与早期启动严格对齐。

九月 selected 集合有序且不可拆分（19 个逻辑项、23 个应用提交）；总回移 66 个逻辑项，含 36 个独立项和宿主构建回移。来源、吸收/保留理由和质量证据以 `patches/backports/` 固定 TSV 为准。已吸收层、无用上下文适配和无目标代码收益项不得重复保留，未编译路径不得计作有效功能。

新增独立回移置于 `patches/backports/kmi6-2026-09-independent/`：每份清单一个逻辑项，不可拆的官方前置/补修链同清单，独立 SHA-256 pin。用临时 Git index 证明从固定基础差异单项应用、撤销及固定顺序完整重放；授权不含清单外提交。逐项说明配置、UAPI、syscall、ABI/KMI 影响，不得破坏目标闭包、关键启动配置或用户态语义。

`patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch` 仅用 `ANDROID_KABI_TYPE_STRING` 固定 OTA 消费的两个 tegra_mc 不透明指针接口版本字符串；不得改变机器 ABI、运行时代码或布局。补丁 SHA-256、patch-id 及源码差异 MUST 固定校验。

## 3. 小米 17 可启动兼容性硬门禁

启动门禁 MUST 只包含有明确机制或目标 OTA 证据、确实影响基本启动与内核核心功能的最小必要检查。新增启动门禁 MUST 说明其对应的启动链路、核心功能或目标模块加载失败机制；性能优化开关、可选组件、日志策略、普通命令行参数和完整配置快照不得因配置偏好被加入启动门禁。项目功能、编译身份、来源完整性及全量快照审计 MUST 独立检查、独立报告，不得冒充启动必需条件；既有模块闭包、安全能力与发布审计要求仍按各自职责执行。

ABI/KMI 硬门禁仅针对固定小米 17 同一 OTA 模块闭包实际消费的接口及相关类型兼容性。待放行版本 MUST 同时满足：

- 覆盖固定 OTA 的 `boot`、`vendor_boot`、`vendor_dlkm`、`system_dlkm` 中全部实际使用及可能按硬件、服务或运行时路径加载的内核模块，不限于单次启动已加载子集。
- 对上述目标模块闭包中的每个依赖，验证符号存在、CRC、provider、导出类型、namespace、依赖顺序、vermagic 和相关 ABI 类型兼容；不得出现 unknown symbol、CRC disagreement、namespace 拒绝、vermagic/CFI/BTF 不兼容或伪造 provider。
- 保持 arm64、4 KiB、对应 GKI/KMI generation、模块版本机制以及启动、存储、显示、Binder、SELinux/LSM、seccomp、BPF 和设备安全路径所需的关键配置与语义。
- 项目新增的 built-in 能力或 `.ko` 不得破坏 stock 闭包；新增 `.ko` 必须随对应 `Image` 同次构建，并独立证明可加载、依赖完整及功能正常。
- 真机完成启动、全部预期模块加载、关键硬件和项目功能验证，并排除 panic、Oops、watchdog、关键模块加载失败及持续性严重错误。

目标闭包符号删除、CRC/provider/namespace/相关类型不兼容或关键启动配置破坏均为绝对拒绝项，安全性或性能收益不能豁免。禁止删除验证对象、伪造导出、硬编码跳过、扩大例外或以空模块掩盖失败；唯一固定 `rust_binder.ko` 的内置替代策略见第 5 节。

全量导出、STG、配置和模块矩阵是参考快照，数量和摘要以 `.env` 为准；哈希、数量或顺序变化本身不是 ABI/KMI 硬失败或补丁拒绝理由。构建 MUST 报告参考值与本次值、生成结构化漂移摘要并保留完整快照。没有导出和目标消费者的两个 C Binder tracepoint 的参考 CRC 记为 `-`，不得伪造导出。

差异审计必须分开记录目标闭包硬门禁与全量快照漂移。目标消费者相关变化须证明完全兼容；无目标消费者的变化须用途明确且无回归。必要配置变化、新增项目模块及其必要导出、模块排序变化均须遵守上述要求，不得绕过关键配置和闭包门禁。出现 `DRIFT` 时必须先保留本次快照、完成影响审查，并在同一变更中更新参考摘要；未确认漂移不得进入发布闭包，也不得放宽 UAPI、syscall 或用户态语义审查。

## 4. 脚本职责

完整编译 MUST 通过 GitHub Actions 的 `build.yml` 从 main 手动触发。Linux runner 内由 `tools/ci/run_build.sh` 依次调度 `patches/init.sh`、`patches/patch.sh`、`patches/patch_external.sh` 与 `patches/build.sh`。本地开发仅执行轻量检查。

- `.env`：唯一受版本控制的 pin、构建身份和验证快照来源。
- `patches/init.sh`：准备并校验固定源码、依赖包、AK3 模板、OTA 镜像、NDK、stock 工具与官方 CI Manager APK。
- `patches/patch.sh`：应用项目维护的官方内核及宿主构建回移，校验内容包、patch-id、路径、幂等、单项应用/撤销和有序重放。
- `patches/patch_external.sh`：接入已准备的外部组件。
- `patches/build.sh`：生成配置、编译，执行第 3、5 节门禁与快照审计，闭包齐全且漂移审查完成后打包。
- `tools/ci/`：宿主准备、标准流程调度与交付通知。`check.yml` 在 main 的 push/PR 执行轻量检查；`build.yml` 手动执行完整构建，分为 build、notify 两个 job。
- `work/cache/downloads/ota/os4.0.6.0/system_dlkm.img`：CI 构建使用的固定模块闭包输入，由 init 从依赖仓固定 Release 下载，大小和摘要由 `.env` 校验。其他分区镜像与设备证据放在 `evidence/`。

`INIT_FETCH_JOBS` 控制初始化并发，CI 使用 2；独立任务共用槽位，完成后立即补位。

主仓库仅消费 fixed 依赖。五项包 pin（`BACKPORT_BUNDLE_MANIFEST_SHA256`、`BACKPORT_BUNDLE_SHA256`、`BACKPORT_BUNDLE_URL`、`CI_TOOLCHAIN_BUNDLE_SHA256`、`CI_TOOLCHAIN_BUNDLE_URL`）必须完整有效。归档、manifest、实际内容和工具链安装树分别按固定摘要验证。现有 v1 包绑定的来源输入字段保持兼容。AK3 模板归档和原样 OTA 镜像独立发布于 [build-inputs-v1-d082477](https://github.com/LunaKernel/ci-dependencies/releases/tag/build-inputs-v1-d082477)，由 `.env` 固定 URL、SHA-256、模板树摘要和镜像大小。

CI 缓存 ccache、固定下载、Manager APK、干净 common、回移内容目录和工具链安装树；key 绑定内容身份与格式。依赖在 init 校验成功后、patch 前保存；common 必须无已跟踪差异、未跟踪或忽略文件，ccache 使用 `compiler_check=content`。目录与完整流程见 [构建说明](BUILDING.md)。

依赖制作、官方来源审计与候选调查维护于 [LunaKernel/ci-dependencies](https://github.com/LunaKernel/ci-dependencies)。制作以固定主项目提交提供 pins、清单和适配补丁，验证官方 Git 来源与提交关系，记录制作提交、来源、许可证和内容摘要，输出版本化归档。主仓库保留本次源码、补丁应用、工具身份与目标 OTA 构建检查。

额外模块模板由 [LunaKernel/extra-modules](https://github.com/LunaKernel/extra-modules) 管理；主仓 `.env` 固定提交与 `ipset/` 模板目录 SHA-256，`patches/init.sh` 拉取并校验，`patches/build.sh` 负责用户态编译、模块组装与交付。

维护遵循 KISS：按制作、消费、构建职责放置代码；删除失去用途的分支和重复校验。文档记录操作、约束和已验证事实，避免重复告诫与防御性表述。

固定源码仓库必须保持干净，或其差异能被补丁脚本用允许路径和 reverse-apply 精确证明。`sources/`、`work/`、`evidence/`、`kernel_out/`、日志、转储和测试包不得提交。不得在输出目录手工修改 `.config`、`Module.symvers` 或包内容绕过守卫。

`kernel_out/` 只存 Image、内核刷机 ZIP 与配套官方 CI Manager APK，每次构建使用 `luna-xiaomi17-g<项目提交前8位>-YYYYMMDD-HHMM/`，上海时区，同名拒绝覆盖。工具、缓存、审计、其余配套组件与暂存分别置于 `work/` 子目录；`evidence/` 是用户手动维护的外部证据，MUST NOT 自动清理。内核产物保留最新三套，第四套经用户确认验收后才清理最旧一套；构建开始或失败时 MUST NOT 删除旧内核产物。

构建审计（含日志、失败快照）与配套组件各保留最新三份，由 `.env` 的 `WORK_HISTORY_KEEP=3` 固定；CI 生成流程退出后按构建时间轮换。清理仅作用于 `work/audit/`、`work/components/` 下匹配构建命名的普通目录。回移调查记录由依赖仓库管理。发布必须具备完整产物与审计清单。

除用户明确要求或构建、来源及验收门禁必需的记录外，MUST NOT 新增说明性报告文件；工作结果直接在对话中说明。项目已有 Git 历史，MUST NOT 为已受 Git 管理的旧状态另留无用备份。目录规范文件须在整理完成、用户确认规范内容后才创建并引用。

## 5. 构建与发布门槛

- `bash tools/ci/check.sh` 统一执行 Shell/Python 语法检查、单元测试、构建输入检查和 actionlint；`metadata` 与轻量检查对 AK3 模板、OTA 镜像仅核对 pin 格式，实际输入在 init 准备后验证。该轻量检查可在本地开发时执行，完整编译与发布门禁由 CI 执行。
- common 版本必须为 `.env` 固定的 6.12.92，QCOM/Xiaomi symbol list 必须存在。
- 项目配置、modules.order 及摘要以 `.env` 为准；保留 stock Rust Binder 黑名单和工具探测缓存项，后者 MUST NOT 成为启动门禁。完整构建与实机状态按第 3、6 节独立记录。
- 4 KiB、SMP、PREEMPT、模块、MODVERSIONS、BASIC/EXTENDED_MODVERSIONS、GENDWARFKSYMS、Android vendor hooks、IKCONFIG、CFI、Rust、BPF JIT、module BTF、MODULE_ALLOW_BTF_MISMATCH、FUSE BPF、BLK_WBT_MQ 必须启用。
- 按用户本轮确认，仅构建和交付 4 KiB 版本；16 KiB 暂不交付。16/64 KiB、`LOCALVERSION_AUTO`、`TRIM_UNUSED_KSYMS`、强制模块签名、Full/Thin LTO 必须关闭；使用 `LTO_NONE`。
- 按本轮授权，Rust Binder 必须内置并作为唯一实际 Binder 实现：`ANDROID_BINDER_IPC_RUST=y`、`ANDROID_BINDER_IPC=n`，不启用 C 实现专用的 `ANDROID_BINDERFS`；Binderfs 由 Rust 驱动自带实现提供。不得同时内置 C/Rust 两套同名 tracepoint。保留独立 vendor hooks，固定 OTA 的其余模块继续严格闭包检查。配置使用 `CMDLINE_EXTEND=y`，保留 common 原始参数并追加 `module_blacklist=rust_binder`，仅阻止 stock 同名 `.ko` 的符号解析，不影响内置驱动。模块屏蔽策略独立于最小启动门禁；Rust Binder 本身提供核心 IPC，必须纳入启动配置检查。
- `BPF_UNPRIV_DEFAULT_OFF=y`；DMA-BUF system/CMA heaps、GUNYAH_QCOM_PLATFORM、ARM_SMMU、ARM_SMMU_V3、ARM_SMMU_V3_PKVM 与 QCOM_IOMMU 必须保持关闭。ARM_PKVM_GUEST、VFIO_PKVM_IOMMU 与 PKVM_PVIOMMU 必须启用。
- seccomp 内核能力必须启用。KernelSU Manager 或获准 root 进程因官方 `disable_seccomp()` 显示 `Seccomp: 0` 属于预期；普通 Android 应用应为 `2`。
- 保留 AOSP r21 原生 Unicode/casefold 语义，F2FS 使用默认 `LOOKUP_PERF`。
- LSM 展开后的 `MAX_LSM_COUNT` 必须与实际启用的 LSM 数量精确一致；当前参考值为 6，BBG 占 1 槽，KernelSU 不得额外注册 LSM。
- Clang r596125（22.0.2）、Rust 1.97.0-dev（LLVM 22.1.6）与 build-tools 来自固定 AOSP Git subtree。依赖仓库制作时验证上游 Git tree、检出内容及 bindgen/bc 的 Git blob 与 SHA-256；主仓库验证归档、来源记录、安装树和实际工具身份。Clang/Rust 的 LLVM 主版本必须一致，启用 `RUST_INLINE_HELPERS`；Rust 独立安装。
- AutoFDO MUST 使用固定 common 自带的 `gki/aarch64/afdo/kernel.afdo`，路径和 SHA-256 由 `.env` 固定；构建前校验 Git blob 身份及固定 LLVM 的读取能力，实际 C/Rust 命令 MUST 包含对应 sample-use 参数。缺失或不匹配必须失败，不得静默退回普通编译；保持 `LTO_NONE`。当前编译策略见 [构建说明](BUILDING.md)，回移来源与审查见 `patches/backports/`。
- ExtTSP MUST 显式禁止作用于无 profile 的函数。AutoFDO 的 Profi 固定使用 `-sample-profile-even-flow-distribution=false`，以官方单路径增广规避当前组合中均匀分流 DAG 搜索的异常耗时；LLVM 22 与 LLVM 23 均已复现该路径，保留 sample-use、Profi 最小费用流与 MIR profile loader。该策略可能改变推断权重和代码布局，不得声称性能等价。C/Rust 后端参数最终值独立审计。Rust 仅 core 使用 `.env` 固定的四线程前端，保留 GNU Make jobserver 和全部内核 crate 的 `codegen-units=1`；这些构建策略 MUST NOT 纳入启动门禁。
- Rust 普通内核代码允许非对齐访问，使用 softfloat 且特性列表以 `-strict-align,-neon` 结束，MUST 校验实际 LLVM 属性；早期启动 C 保持原生严格对齐规则。IPSet/libmnl 使用固定 SM8850 ISA 与 Oryon-1，配置缓存仅在源码、工具链、API、参数及路径身份一致时复用；内核与 NDK 共用项目 ccache，容量由 `.env` 固定。
- stock 清单覆盖 `OS4.0.6.0.XPCCNXM` 同包四分区全部模块，4090 项实际 vmlinux 依赖及五列 tuple 的摘要以 `.env` 为准。system_dlkm 的 103 个模块中，102 个必须严格闭包；唯一 stock `rust_binder.ko` 保留固定镜像身份、240 项原始需求及无导出、无模块依赖、无反向依赖证明，其本次比较完整记录，不得宣称该 `.ko` 可加载。放行另须证明 `modules.builtin` 包含 Rust Binder、`modules.order` 不含它、`System.map` 含 Rust 初始化函数/initcall 且无 C 初始化函数，实际配置在符号解析前屏蔽 stock 同名模块。其余模块不得套用此替代；项目新增模块独立执行第 3 节门禁。
- 输入固定为 `work/cache/downloads/ota/os4.0.6.0/system_dlkm.img`，由 `patches/init.sh` 下载准备，大小与 SHA-256 由 `.env` 固定。`patches/build.sh` 必须校验整镜像身份、AVB hashtree、EROFS 及 stock 清单绑定，缺失或不匹配时在打包前失败。重建清单必须校验同 OTA 四镜像及 `unpack_bootimg`、`bsdtar`、kmod、EROFS 工具；不得混用不同 OTA 的分区证据。

发布产物名称：

```text
luna-xiaomi17-g<项目提交前8位>-YYYYMMDD.zip
Image-luna-xiaomi17-g<项目提交前8位>-YYYYMMDD
```

AnyKernel3 只能替换 `Image`，必须含 `kernel.string=Luna Kernel for Xiaomi 17` 与 `do.devicecheck=0`，不得携带或修改 DTB、DTBO、vendor modules、ramdisk 或 boot header。模板源码及许可证由依赖仓 [`ak3_template/`](https://github.com/LunaKernel/ci-dependencies/tree/build-inputs-v1-d082477/ak3_template) 维护，主仓 init 校验归档 SHA-256、安全解包并验证树摘要，build 使用其中固定的官方脚本基线与 Luna 差异补丁重新组装；BusyBox 和 MagiskBoot 必须来自 `.env` 固定来源并在使用前校验摘要，禁止重新提交预制模板 ZIP。IPSet 用户态命令继续作为独立 KernelSU 模块交付。

Manager APK 属于配套交付检查，不是内核启动门禁。`.env` MUST 固定官方 main CI 的提交、run/artifact ID、归档与 APK SHA-256、版本、UAPI 和签名证书；更新 KernelSU 时一并审查兼容性。`patches/init.sh` 优先复用 `work/cache/ksu-manager/` 或已验证的现有 APK；`patches/build.sh` 只离线校验、记录来源并交付，校验签名证书与实际内核编译参数一致。APK MUST 纳入 `.build-artifacts`，由 `release.tsv` 的 `ksu_manager_apk` 指定，CI 产物导出不得遗漏；历史未要求 APK 的发布按原清单验证。缺少兼容官方产物时不得静默省略或宣称交付齐全。

KernelSU 保持 built-in，不得借门禁重构改变交付边界。后续切换 LKM 须专项审计并保持单一安装入口，补齐模块交付、逐项依赖与真机加载检查；不能以 `.ko` 出现在 modules.order 代替验证。驻留 LKM 与新 Image 的完整闭包通过同等门禁后，才允许只更新 Image/已组装 boot。

## 6. 真机验证

当前验收基准为项目 `1d3c30f1945ad2c70bbf084886339649b3017123`，release `6.12.92-android16-luna-g1d3c30f1-4k`。用户于 2026-11-08 确认在 `pudding` / `OS4.0.6.0.XPCCNXM` 完成严格实机验收并通过，状态为 `accepted`。身份、构建审计与范围见 [验证记录](VALIDATION.md)。

每个新 Image 的验收绑定项目提交、二进制摘要和 OTA。发布前完成完整构建、目标模块闭包和真机复测，记录 `uname -a`、`/proc/version`、boot completed、slot/verified boot、cmdline、模块加载、Binder、BPF sysctl、dmesg、logcat 与 pstore。

必须分别验证 KernelSU/SUSFS/BBG、SELinux/LSM 和 IPSet。环境隐藏可使属性显示为 green/locked；验收时必须结合 bootconfig 和测试环境说明，不能把预期隐藏行为误判为内核失败。

## 7. 提交规范

提交标题采用 `<type>: <准确精炼中文描述>`，类型限 `chore`、`feat`、`fix`、`refactor`、`docs`。pin、功能、可启动兼容性硬门禁、全量差异审计、打包和文档应独立审查。提交前执行 `git diff --check`、脚本语法检查和与风险相称的构建验证。

不确定项先以固定上游、stock 模块闭包、`Module.symvers`、IKCONFIG、已验证 Image 和日志取证。放宽目标 OTA 可启动闭包硬门禁、关闭安全/调试能力、扩大来源或改变 Image-only 边界前，必须暂停并向用户说明；快照变化按第 3 节完整报告和审查，不得静默接受。
