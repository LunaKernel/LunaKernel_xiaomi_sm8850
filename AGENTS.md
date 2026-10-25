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
| 实际 GKI Image 源码 | `sources/aosp_common_6.12.92_kmi6_2026-09/` | `https://android.googlesource.com/kernel/common` | `android16-6.12-2026-09_r8` 发布标签 | `8349fd96abe644d106ea2145cbadf93da9a484e3` |

Image MUST 从 AOSP common 构建。小米仓库 `android/ACK_SHA` 中的 r8 / `f1bdb13583da85a47fcf1632a78ef52d6e6da651` 仅用于完整性检查；不得复制目录伪造单仓源码树。

## 2. 来源与改动边界

取证优先级为：固定的小米与 AOSP 上游、官方 AOSP/Linux 历史与 KMI 清单、已验证产物和真机日志。不得从无关整树内核复制实现，不得保留无关作者或项目品牌。实际集成的独立组件必须保留准确来源、固定提交及许可证信息。

当前固定组件：

- KernelSU `v3.3.0-50-g623eba3e`：`623eba3e092b911a3a7389b7d87622a5835d2f3a`，SUSFS 官方明确配套的 main 快照，built-in，version code `32651`、UAPI `4`。Manager 由用户独立获取匹配内核接口的官方版本，不属于项目下载、构建或交付目标。MUST 使用上游已吸收的修复实现并删除重复回移层。`c20d48a` 修改的 object 被 SUSFS 官方兼容层从 Kbuild 移除，不得视为当前组合中的有效功能。
- SUSFS v2.3.0：`b213c54126fb243595ce7876e91d84d6e0861fec`；common 与 KernelSU 官方兼容补丁取自同一提交。SUSFS KernelSU 模块 ZIP 与独立 helper 不属于项目交付目标；内核能力保持启用。已吸收的三个重复补修 MUST 删除；剩余差异与上下文见 `patches/susfs/b213c54-absorption.tsv`。`OPEN_REDIRECT` 的 nd->name 生命周期已修复，但 readlink 返回值及短 buffer 语义缺陷仍存在，MUST 在编译期关闭并等待上游完整修复；内核日志静态键 MUST 默认关闭，仅允许显式运行时启用。
- Baseband Guard：`a54e0dc6cf0aff4dd87fec49644a02d2eb612905`，叠加项目固定的无缓存块设备身份复核、固定上游判定的破坏性 block ioctl 与 UFS BSG 原始命令封堵、`io_uring discard`/共享可写映射入口保护、KernelSU 授权凭据标记与最小限速拒绝日志；file_permission、mmap_file 与 file_mprotect 在凭据检查前排除无关操作和非块设备，保护策略不变。boot/recovery 分区保护关闭，其余能力启用。
- IPSet 7.24、libmnl 1.0.5 与 Android NDK r30：固定归档摘要和解压树摘要。

内核直接修复仅授权 `patch.sh` 可精确证明的 AOSP/Linux 官方修复。新增候选 MUST 机制清晰、关联小米 17 实际路径、来自稳定官方历史、无回退或明显回归证据，并通过第 3、5 节硬门禁及完整差异审计；拒绝收益极小、路径无关、来源不清或逻辑证据不足的改动。缺少实机性能数据本身不构成否决，不得将机制不明的猜测视为优化。r21 已原样包含主动回收响应 freezer 的 AOSP 修复 `bee364ffffd30532ef586a10bb42b505ed347988`，不得重复回移。

另经用户授权，仅接入官方 Kbuild `kbuild-next-speedups` 固定快照中的 kallsyms token 索引及参数探测缓存链，分别由独立清单 `670-kallsyms-token-index.tsv`、`680-kbuild-probe-cache.tsv` 固定。来源与必要 Git 对象独立置于 `sources/linux_kbuild_audit/`，不得将 next 提交标为主线或稳定树。MUST 证明生成结果及现有参数顺序等价，保留 6.12 原生 Kconfig 语法、工具链门禁和早期启动严格对齐；授权不含该快照的其他改动。

九月 selected 回移集合有序且不可拆分：19 项逻辑修复、23 个应用提交。已吸收的层及旧 F2FS 上下文适配 MUST 删除。r8 已吸收 XFRM6 设备引用修复，重复的 600 清单及 pin 已删除；直接回移为 68 个逻辑项（含宿主构建回移），独立项为 38 个。已删除无目标代码收益的 EAS cpumask 回移及 BBG 遗留空函数，不得把未编译路径计作有效功能。吸收、保留理由及质量证据见 `patches/backports/` 中固定 TSV。

新增高置信回移 MUST 置于 `patches/backports/kmi6-2026-09-independent/`，每份清单仅含一个逻辑项，不可拆的官方前置/补修链同清单，独立 pin SHA-256。必须以临时 Git index 证明从固定基础差异单项应用、撤销及固定顺序完整重放；授权不含清单外提交。配置、UAPI、syscall、ABI 或 KMI 影响逐项说明，不得破坏固定 OTA 模块闭包、关键启动配置或用户态语义。

r21 对 `struct tegra_mc` 的私有类型重构使固定 OTA 实际消费的 `devm_tegra_memory_controller_get` 与 `tegra_mc_probe_device` 产生 CRC 漂移。`patches/kmi/tegra-mc-opaque-pointer-kmi-r21.patch` 只使用 `ANDROID_KABI_TYPE_STRING` 固定这两个不透明指针接口的版本字符串，不改变函数机器 ABI、运行时代码或结构体布局；该窄兼容补丁及其 SHA-256、patch-id MUST 固定并纳入源码差异门禁。

## 3. 小米 17 可启动兼容性硬门禁

启动门禁 MUST 只包含有明确机制或目标 OTA 证据、确实影响基本启动与内核核心功能的最小必要检查。新增启动门禁 MUST 说明其对应的启动链路、核心功能或目标模块加载失败机制；性能优化开关、可选组件、日志策略、普通命令行参数和完整配置快照不得因配置偏好被加入启动门禁。项目功能、编译身份、来源完整性及全量快照审计 MUST 独立检查、独立报告，不得冒充启动必需条件；既有模块闭包、安全能力与发布审计要求仍按各自职责执行。

ABI/KMI 硬门禁仅针对固定小米 17 同一 OTA 模块闭包实际消费的接口及相关类型兼容性。待放行版本 MUST 同时满足：

- 覆盖固定 OTA 的 `boot`、`vendor_boot`、`vendor_dlkm`、`system_dlkm` 中全部实际使用及可能按硬件、服务或运行时路径加载的内核模块，不限于单次启动已加载子集。
- 对上述目标模块闭包中的每个依赖，验证符号存在、CRC、provider、导出类型、namespace、依赖顺序、vermagic 和相关 ABI 类型兼容；不得出现 unknown symbol、CRC disagreement、namespace 拒绝、vermagic/CFI/BTF 不兼容或伪造 provider。
- 保持 arm64、4 KiB、对应 GKI/KMI generation、模块版本机制以及启动、存储、显示、Binder、SELinux/LSM、seccomp、BPF 和设备安全路径所需的关键配置与语义。
- 项目新增的 built-in 能力或 `.ko` 不得破坏 stock 闭包；新增 `.ko` 必须随对应 `Image` 同次构建，并独立证明可加载、依赖完整及功能正常。
- 真机完成启动、全部预期模块加载、关键硬件和项目功能验证，并排除 panic、Oops、watchdog、关键模块加载失败及持续性严重错误。

目标闭包符号删除、CRC/provider/namespace/相关类型不兼容或关键启动配置破坏均为绝对拒绝项，安全性或性能收益不能豁免。禁止删除验证对象、伪造导出、硬编码跳过、扩大例外或以空模块掩盖失败；唯一固定 `rust_binder.ko` 的内置替代策略见第 5 节。

全量导出、STG 类型图、配置和模块矩阵是参考快照：哈希、项目数或顺序变化本身不是 ABI/KMI 硬失败或补丁拒绝理由。构建 MUST 报告参考值与本次值、生成结构化漂移摘要并保留本次完整快照。九月 r8 与 SM8850 LLVM 22 当前参考为：Module.symvers 18589 项、vmlinux/STG 17991 项导出、QCOM/Xiaomi vendor 参考并集 4740 项，其中两个 C Binder tracepoint 未导出且无目标 OTA 消费者，参考 CRC 记为 `-`，不得据此伪造导出；各项 SHA-256、配置与模块清单均以 `.env` 为准。

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
- `patch.sh`：仅应用项目维护的官方内核及宿主构建回移；必须幂等。
- `patch_external.sh`：仅接入已准备的外部组件；不得下载。
- `build.sh`：生成配置、编译，执行第 3、5 节门禁与快照审计；仅在发布闭包齐全且无未确认漂移后打包，不得准备源码。

固定源码仓库必须保持干净，或其差异能被补丁脚本用允许路径和 reverse-apply 精确证明。`sources/`、`work/`、`evidence/`、`kernel_out/`、日志、转储和测试包不得提交。不得在输出目录手工修改 `.config`、`Module.symvers` 或包内容绕过守卫。

`kernel_out/` 只存 Image 与内核刷机 ZIP，每次构建使用 `luna-xiaomi17-g<项目提交前8位>-YYYYMMDD-HHMM/`，上海时区，同名拒绝覆盖。工具、缓存、审计、配套组件与暂存分别置于 `work/` 子目录；`evidence/` 是用户手动维护的外部证据，MUST NOT 自动清理。内核产物保留最新三套，第四套经用户确认验收后才清理最旧一套；构建开始或失败时 MUST NOT 删除旧内核产物。

构建审计（含日志、失败快照）、回移审计及配套组件按类别各保留最新三份，份数由 `.env` 的 `WORK_HISTORY_KEEP=3` 固定；生成流程退出及宿主导入完成后自动删除超额的最旧目录。构建与组件按构建目录时间排序，回移审计按固定快照日期排序且同快照复用目录。清理 MUST 仅作用于 `work/audit/`、`work/components/` 下匹配项目命名的普通目录，不得跟随符号链接或删除源码、工具与缓存。已轮换掉审计的旧内核不再构成完整发布集合，MUST NOT 绕过清单校验重新发布。

除用户明确要求或构建、来源及验收门禁必需的记录外，MUST NOT 新增说明性报告文件；工作结果直接在对话中说明。项目已有 Git 历史，MUST NOT 为已受 Git 管理的旧状态另留无用备份。目录规范文件须在整理完成、用户确认规范内容后才创建并引用。

## 5. 构建与发布门槛

- `bash -n init.sh patch.sh patch_external.sh build.sh tools/backport_audit.sh tools/backport_manifest.sh tools/independent_backports.sh` 必须通过。
- common 版本必须为 `.env` 固定的 6.12.92，QCOM/Xiaomi symbol list 必须存在。
- 参考配置为 8259 行，modules.order 为 103 个活动模块，摘要以 `.env` 为准。相对旧验收仅切换四个 Binder 配置项：Rust 模块改内置、C 实现关闭、两个 C 专用选项不再序列化。配置参考包含 stock Rust Binder 模块黑名单和 12 个序列化工具探测缓存项；缓存项 MUST NOT 成为启动门禁。完整构建与实机状态按第 3、6 节独立记录。
- 4 KiB、SMP、PREEMPT、模块、MODVERSIONS、BASIC/EXTENDED_MODVERSIONS、GENDWARFKSYMS、Android vendor hooks、IKCONFIG、CFI、Rust、BPF JIT、module BTF、MODULE_ALLOW_BTF_MISMATCH、FUSE BPF、BLK_WBT_MQ 必须启用。
- 16/64 KiB、`LOCALVERSION_AUTO`、`TRIM_UNUSED_KSYMS`、强制模块签名、Full/Thin LTO 必须关闭；使用 `LTO_NONE`。
- 按本轮授权，Rust Binder 必须内置并作为唯一实际 Binder 实现：`ANDROID_BINDER_IPC_RUST=y`、`ANDROID_BINDER_IPC=n`，不启用 C 实现专用的 `ANDROID_BINDERFS`；Binderfs 由 Rust 驱动自带实现提供。不得同时内置 C/Rust 两套同名 tracepoint。保留独立 vendor hooks，固定 OTA 的其余模块继续严格闭包检查。配置使用 `CMDLINE_EXTEND=y`，保留 common 原始参数并追加 `module_blacklist=rust_binder`，仅阻止 stock 同名 `.ko` 的符号解析，不影响内置驱动。模块屏蔽策略独立于最小启动门禁；Rust Binder 本身提供核心 IPC，必须纳入启动配置检查。
- `BPF_UNPRIV_DEFAULT_OFF=y`；DMA-BUF system/CMA heaps、GUNYAH_QCOM_PLATFORM、ARM_SMMU、ARM_SMMU_V3、ARM_SMMU_V3_PKVM 与 QCOM_IOMMU 必须保持关闭。ARM_PKVM_GUEST、VFIO_PKVM_IOMMU 与 PKVM_PVIOMMU 必须启用。
- seccomp 内核能力必须启用。KernelSU Manager 或获准 root 进程因官方 `disable_seccomp()` 显示 `Seccomp: 0` 属于预期；普通 Android 应用应为 `2`。
- 保留 AOSP r21 原生 Unicode/casefold 语义，F2FS 使用默认 `LOOKUP_PERF`。
- LSM 展开后的 `MAX_LSM_COUNT` 必须与实际启用的 LSM 数量精确一致；当前参考值为 6，BBG 占 1 槽，KernelSU 不得额外注册 LSM。
- Clang r596125（22.0.2）、Rust 1.97.0-dev 与 build-tools 必须来自固定 AOSP Git subtree，同时校验完整上游 Git tree 与明确检出内容的 SHA-256；bindgen 0.72.1 和宿主 bc 必须校验固定 AOSP Git blob 与 SHA-256。Clang 与 Rust 的 LLVM 主版本必须相同，`RUST_INLINE_HELPERS` 必须启用。Rust 必须独立安装，禁止覆盖 Clang 的 LLVM 共享库；完整工具链安装树摘要必须保持 `d962642b792c48a2fc35457d0f72058cad6e7778b682e3a5f52c0d081113bc64`，并与 `.env` 固定值一致。
- AutoFDO MUST 使用固定 common 自带的 `gki/aarch64/afdo/kernel.afdo`，路径和 SHA-256 由 `.env` 固定；构建前校验 Git blob 身份及固定 LLVM 的读取能力，实际 C/Rust 命令 MUST 包含对应 sample-use 参数。缺失或不匹配必须失败，不得静默退回普通编译；保持 `LTO_NONE`。当前编译策略见 `docs/BUILDING.md`，回移来源与审查见 `patches/backports/`。
- ExtTSP MUST 显式禁止作用于无 profile 的函数，C/Rust 后端参数最终值独立审计。Rust 仅 core 使用 `.env` 固定的四线程前端，保留 GNU Make jobserver 和全部内核 crate 的 `codegen-units=1`；这些构建策略 MUST NOT 纳入启动门禁。
- Rust 普通内核代码允许非对齐访问，使用 softfloat 且特性列表以 `-strict-align,-neon` 结束，MUST 校验实际 LLVM 属性；早期启动 C 保持原生严格对齐规则。IPSet/libmnl 使用固定 SM8850 ISA 与 Oryon-1，配置缓存仅在源码、工具链、API、参数及路径身份一致时复用；内核与 NDK 共用项目 ccache，容量由 `.env` 固定。
- stock 清单覆盖 HyperOS 4 `OS4.0.0.9.XPCCNXM` 同一 OTA 的 boot/vendor_boot/vendor_dlkm/system_dlkm，可证明 4083 项实际 vmlinux 依赖，v5 清单摘要为 `866afc7ea549ff8aa13a53f28d242396f1a8fa356ead345709cc1b7f7a16136a`；对应五列硬门禁 tuple 摘要为 `d3add92d15233b79b94c354ad6bd74a254c8be94eba2b2c199369dc80f6a6555`。固定 system_dlkm 输入含 103 个 stock 模块，其中 102 个必须严格闭包。唯一被替代的 stock `rust_binder.ko` 必须保持固定镜像身份、234 项原始需求、无导出、无模块依赖及无反向依赖的证据；原先 C Binder 构建中的 167 项匹配、67 项缺失仅为历史参考，不得宣称该 `.ko` 可加载。其本次需求比较必须完整保留；放行必须另行证明本次 `modules.builtin` 包含 Rust Binder、`modules.order` 不包含它、`System.map` 含 Rust 初始化函数及 initcall 且不含 C Binder 初始化函数，并由实际配置证明 stock 同名模块在符号解析前被屏蔽。其余模块不得沿用此替代策略。项目自身新增模块不计入这 103 个 stock 模块，但必须通过第 3 节所述加载与依赖门禁。
- 同 OTA `evidence/os4/system_dlkm.img` 固定为 17281024 字节、SHA-256 `7918f34b6ae9210b8470abbe1ee52f2fc72da04bfa241627ab0c66f340ab9816`。`build.sh` 必须校验整镜像身份、AVB hashtree 自洽、EROFS 完整性以及与 stock 清单绑定关系；镜像缺失或不匹配时 MUST 在打包前失败。重建 stock 清单还需固定的 Xiaomi 四个分区镜像以及脚本校验过的 `unpack_bootimg`、`bsdtar`、kmod 和 EROFS 工具。

发布产物名称：

```text
luna-xiaomi17-g<项目提交前8位>-YYYYMMDD.zip
Image-luna-xiaomi17-g<项目提交前8位>-YYYYMMDD
```

AnyKernel3 只能替换 `Image`，必须含 `kernel.string=Luna Kernel for Xiaomi 17` 与 `do.devicecheck=0`，不得携带或修改 DTB、DTBO、vendor modules、ramdisk 或 boot header。模板必须由 `ak3_template/` 中固定的官方脚本基线与 Luna 差异补丁重新组装；BusyBox 和 MagiskBoot 必须来自 `.env` 固定来源并在使用前校验摘要，禁止重新提交预制模板 ZIP。IPSet 用户态命令继续作为独立 KernelSU 模块交付。

当前 KernelSU 仍为 built-in，本轮不得借门禁重构改变交付边界。若后续经专项审计切换为 LKM，面向用户必须保持单一安装入口，不得要求分别管理或手工刷入两个分区镜像；该专项还必须新增模块交付、逐项依赖与真机加载门禁，不能把 `modules.order` 中存在 `.ko` 当成已完成验证。首次安装后只有在驻留 LKM 与新 `Image` 的完整依赖闭包通过同等硬门禁时，才允许仅更新或直接刷入已组装的 boot 镜像。

## 6. 真机验证

当前验收基准为项目 `586720039e9896d86e4e55dbdfd4bf8f01cd81b6`，release `6.12.92-android16-luna-g58672003-4k`，2026-10-07 完成本地构建、快速实机回归及用户功能确认，状态为 `accepted`；实机为 `pudding` / `OS4.0.0.32.XPCCNXM`，构建闭包仍固定于 `.9` OTA。必要原始证据与验证范围见 `docs/VALIDATION.md`。该验收 MUST NOT 外推到其他设备、OTA 或新项目哈希，也不得视为性能或长期稳定性实测。设备运行时 MGLRU 为关闭状态，其回收路径未触发；新 IPSet 二进制仅经临时执行验证，未替换已安装模块。完整本地构建与闭包证据以对应提交的发布审计为准。

本开发分支的 r8、内置 Rust Binder 及后续回移尚待对应提交的完整构建与实机验证，不继承上述 C Binder 版本的验收状态。

公开主分支最终提交在发布前仍 MUST 完成同一 OTA 的完整构建、`system_dlkm` 闭包证明和真机复测，记录 `uname -a`、`/proc/version`、boot completed、slot/verified boot、cmdline、模块加载、Binder、BPF sysctl、dmesg、logcat 与 pstore。目录迁移不改变二进制内容，也不能把旧 Image 改名为新提交产物。

必须分别验证 KernelSU/SUSFS/BBG、SELinux/LSM 和 IPSet。环境隐藏可使属性显示为 green/locked；验收时必须结合 bootconfig 和测试环境说明，不能把预期隐藏行为误判为内核失败。

## 7. 提交规范

提交标题采用 `<type>: <准确精炼中文描述>`，类型限 `chore`、`feat`、`fix`、`refactor`、`docs`。pin、功能、可启动兼容性硬门禁、全量差异审计、打包和文档应独立审查。提交前执行 `git diff --check`、脚本语法检查和与风险相称的构建验证。

不确定项先以固定上游、stock 模块闭包、`Module.symvers`、IKCONFIG、已验证 Image 和日志取证。放宽目标 OTA 可启动闭包硬门禁、关闭安全/调试能力、扩大来源或改变 Image-only 边界前，必须暂停并向用户说明；快照变化按第 3 节完整报告和审查，不得静默接受。
