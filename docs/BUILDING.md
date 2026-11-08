# 构建 Luna Kernel

使用 x86_64 Linux；macOS 通过已配置的 OrbStack Linux 执行相同流程。主机需要 Bash、Git、curl、tar、bzip2、xz、unzip、7-Zip、patch、Python 3、GNU coreutils 和常规内核构建依赖。源码与缓存占用数十 GiB。

所有 pin、构建身份和参考摘要以 [`.env`](../.env) 为准。固定源码的差异必须由补丁脚本精确证明；禁止手改构建配置、符号表或包内容绕过检查。

## 输入与流程

发布构建直接使用仓库中的 `ci/inputs/os4.0.6.0/system_dlkm.img`，共 17,281,024 字节。构建校验固定 `OS4.0.6.0.XPCCNXM` OTA 镜像的大小、摘要、AVB hashtree、EROFS 内容及 stock 模块清单；该镜像不进入刷机包。正常构建不重新提取 stock 清单，不需要完整 OTA 或其余分区镜像；人工重建清单才需要 `evidence/os4.0.6.0/` 中同一 OTA 的 `boot.img`、`vendor_boot.img` 和 `vendor_dlkm.img`。原始外部证据仍按 `evidence/` 规则保留，不自动清理。

清单工具由 `init.sh` 按固定 Git blob 与 SHA-256 准备于 `work/tools/stock-evidence/`。同一 OTA 的实机验收与静态模块闭包核对均已完成，范围见 [VALIDATION.md](VALIDATION.md)。

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

`init.sh` 复用并校验固定源码、工具与官方 CI Manager APK；`patch.sh` 应用官方内核回移；`patch_external.sh` 接入已准备的组件，不下载；`build.sh` 编译并执行模块闭包、关键配置和独立快照审计，离线校验并交付配套 APK，不准备源码。补丁脚本必须幂等。

正常初始化仅准备已采用补丁所需的官方提交、父对象与来源关系。调查候选补丁、比较历史 ABI 或重建 stock 清单前，运行 `./init.sh --audit-history` 补齐维护资料；这些资料不参与常规 CI 缓存。来源范围收敛不改变已采用补丁集合及本次 Image 的 ABI/STG 检查。

独立回移审计在同一次调用中复用已验证的清单、来源及导出补丁，仍执行逐项应用、撤销和完整重放；单独调用的检查入口保持自校验，不使用跨构建的通过标记跳过证明。

`INIT_FETCH_JOBS` 仅控制独立依赖的准备并发，本地默认 1、CI 使用 2；任一任务失败会终止其他准备任务。它是运行时参数，不写入 `.env`，也不改变来源、工具链或内核参数。

## GitHub Actions

`.github/workflows/check.yml` 在 main 的 push 和以 main 为目标的 PR 执行轻量检查，使用 `.env` 固定的官方 actionlint 校验 workflow；`.github/workflows/build.yml` 仅支持从 main 手动触发完整构建，不创建 GitHub Release。云端构建状态以对应提交的 Actions 记录为准，现有实机验收只属于 [VALIDATION.md](VALIDATION.md) 中的既有二进制。

完整流程使用 GitHub 托管 `ubuntu-24.04`，分为 build、notify 两个 job：

- **build**：`tools/ci/prepare_runner.sh` 准备宿主，先检查空间，仅在不足时按固定白名单逐项清理无关 SDK，达到 50 GiB 即停止，安装依赖后再次检查；`tools/ci/run_build.sh` 通过 `metadata`、`init`、`compile`、`export`、`summary` 子命令调度现有流程。init 与 compile 共用 330 分钟预算，源码、工具、目标 OTA、配置、ABI/STG 和交付门禁全部保留。
- **缓存**：保留 5 GiB ccache、固定归档下载及官方 Manager APK 缓存，并按固定输入缓存未打补丁的 common 源码、构建必需的只读审计对象和 Clang/Rust/build-tools 来源树，初始化验证成功后才保存。common 缓存绑定来源、分支、提交、目录与准备逻辑，在应用补丁前保存；存在已跟踪差异、未跟踪或忽略文件时不保存。ccache 使用 `compiler_check=content`，来源与下载缓存恢复后仍校验内容、来源及固定摘要。已打补丁的源码、构建目录、审计结果和产物不作为依赖缓存保存，缓存缺失不能改变构建配置或跳过校验。
- **交付**：校验六个交付文件及 `.build-artifacts`、`release.tsv` 后导出为一个保留相对路径的 `tar.gz`，上传为 Actions artifact，保留 30 天。新产物状态为 `awaiting-device`；云端构建成功不等同于实机验收。
- **notify**：`tools/ci/notify_telegram.py` 使用仓库 Actions secrets `TG_BOT_TOKEN`、`CHAT_ID`，发送已校验的内核 ZIP 和官方 Manager APK，附件说明只保留 `SHA256` 与 `Build`；验收状态仍保存在交付清单中。不发送源码、原始证据或凭据。通知失败可单独重跑 notify，下载同一次构建的 artifact 重新校验并发送，无需重新编译；artifact 过期后不能通过重跑通知恢复产物。

两个 Telegram secrets 仅供 notify 使用，不写入 `.env` 或日志。发送成功但响应丢失时，重试可能产生重复文件消息。首次 CI 的实际磁盘占用、缓存命中和耗时以运行记录为准；不得以提速为由引入时间劫持、宽松 ccache 校验或省略 Image/modules 及闭包审计。

## 编译策略

固定 AOSP Clang r596125 / 22.0.2、Rust 1.97.0-dev（LLVM 22.1.6）、bindgen 0.72.1、kernel build-tools、宿主 bc，以及 IPSet 使用的 NDK r30 / API 35。Clang、Rust 各自保留独立 LLVM 库，并验证官方 Git 对象、明确检出树与安装树摘要。

common 使用官方 `android16-6.12-2026-09_r11`（Linux 6.12.92 / KMI generation 6），仅构建和交付 4 KiB 页面版本。

C 使用固定 `-march` 和 `-mtune=oryon-1`；Rust 使用 `target-cpu=generic`、`tune-cpu=oryon-1` 与固定 ISA 列表，全部参数见 `.env`。保留 O2、CFI、Rust inline helpers、`LTO_NONE` 及原生 SIMD/分支保护约束。Rust 使用 softfloat，特性列表以 `-strict-align,-neon` 结束，允许普通内存非对齐访问；早期启动 C 保持严格对齐。

Binder 仅使用内置 Rust 实现及其 Binderfs，关闭 C Binder；`module_blacklist=rust_binder` 拒绝 ROM 同名旧模块。构建通过配置、`modules.builtin`、`modules.order`、`System.map` 和命令行证明替代关系；保留旧模块完整需求审计，其余 stock 模块严格检查 ABI/KMI。

实际模块闭包与全量参考快照分开检查：目标依赖的符号、CRC、provider、导出类型、namespace 和相关类型不兼容时拒绝发布；参考漂移须保留快照、完成审查并更新摘要。完整门禁见 [AGENTS.md](../AGENTS.md)。

AutoFDO 使用 common 自带的 `gki/aarch64/afdo/kernel.afdo`，校验摘要、Git blob 和 LLVM 可读性，实际 C/Rust 命令必须带 sample-use。固定 `-sample-profile-even-flow-distribution=false` 使用 Profi 官方单路径增广，规避均匀分流 DAG 搜索的异常耗时；保留最小费用流与 MIR profile loader。该选项可能改变推断权重和布局，且 profile 来自 Pixel 工作负载，不宣称小米实测性能收益。

KernelSU 内嵌的 preinit runner 保持官方静态 nolibc 用户态参数，不使用内核 AutoFDO/ExtTSP；独立检查实际命令、arm64 ELF 与 Image 嵌入符号。

C/Rust 启用 ExtTSP，并以 `ext-tsp-apply-without-profile=false` 限于有 profile 的函数；审计实际命令和 LLVM 属性。Rust 仅 core 使用四线程前端，遵循 GNU Make jobserver，全部内核 crate 保持 `codegen-units=1`。

增量构建树位于 `work/cache/kernel/`；IPSet/libmnl 使用 `work/cache/userspace/ipset-sm8850/`、SM8850 ISA、Oryon-1 与正常用户态 SIMD。配置缓存绑定源码、NDK、API、路径及参数，变化时仅重建受影响缓存；交付校验 ELF、Android linker、依赖、版本和模块 ZIP。

内核与 NDK 共用 `work/cache/ccache/`，压缩开启、上限 5 GiB，NDK 身份包含完整工具树摘要。复用源码、审计仓库和下载缓存，不运行 clean/mrproper 或放宽依赖校验；路径变化导致的失效由必要构建处理，不改写旧编译命令。

预编译检查本次核心 C/Rust/helper 对象；完整 Image/modules 构建后检查所有活动编译命令、LLVM 属性和发布闭包。

宿主加速仅使用固定官方 `kbuild-next-speedups` 的 kallsyms token 索引及 C/链接器参数探测缓存，保留 6.12 Kconfig 语法与参数顺序；工具身份变化自动重探测。来源和等价性证据见 [`patches/backports/`](../patches/backports/)。

## 交付与身份

内核产物写入 `kernel_out/luna-xiaomi17-g<8位提交>-YYYYMMDD-HHMM/`，时间为上海时区。同名目录拒绝覆盖，文件仍为：

```text
luna-xiaomi17-g<8位提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<8位提交>-YYYYMMDD
```

官方 CI Manager APK 与 Image、内核 ZIP 同目录。审计 ZIP、日志和 `.build-artifacts` 位于 `work/audit/<同名目录>/`；IPSet 命令与模块 ZIP 位于 `work/components/<同名目录>/`。六个交付文件全部由清单绑定 SHA-256 和相对路径，`release.tsv` 指定配套 APK，导入导出必须保持完整。

AnyKernel3 由固定官方脚本、[`ak3_template/luna.patch`](../ak3_template/luna.patch)、BusyBox 和 MagiskBoot 组装，仅替换 Image，保留当前槽、分区容量和镜像大小检查。KernelSU/SUSFS 保持内核集成，不打包 SUSFS 模块或独立 helper。

Manager 使用 `.env` 固定的官方 main CI。`tools/ksu_manager.py` 校验源码/UAPI、归档与 APK 摘要、证书、包名版本和 arm64 组件，构建后核对实际内核接受的签名。优先复用 `work/cache/ksu-manager/` 或已有匹配 APK，缺失才下载固定 artifact；官方 artifact 过期不影响已保存 APK 的摘要验证。无可用副本时在编译前失败，须恢复同 SHA 官方 APK 或审查后更新 pin，不追随 latest、不本地编译替代。

构建只接受干净项目提交；成功后为 `awaiting-device`，不能继承旧 Image 的验收状态。产物、审计与缓存的保留和清理按 [项目目录规则](../AGENTS.md#4-脚本职责) 执行。
