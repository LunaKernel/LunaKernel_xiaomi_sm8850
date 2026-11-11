# CI 构建 Luna Kernel

完整编译统一在 GitHub Actions 的 x86_64 Linux runner 上执行，构建环境由 `tools/ci/prepare_runner.sh` 准备。在仓库 Actions 页面选择 `.github/workflows/build.yml` 对应工作流，点击 Run workflow 并选择 main；构建完成后从该次运行下载交付 artifact。

所有 pin、构建身份和参考摘要以 [`.env`](../.env) 为准。固定源码的差异必须由补丁脚本精确证明；禁止手改构建配置、符号表或包内容绕过检查。

## 输入与流程

以下代码路径均相对于 runner 中的仓库根目录，脚本说明用于维护 CI 内部流程。

`patches/init.sh` 从依赖仓固定 Release 下载原样发布的 `system_dlkm-os4.0.6.0.img`，校验后缓存至 `work/cache/downloads/ota/os4.0.6.0/system_dlkm.img`，共 17,281,024 字节。构建校验固定 `OS4.0.6.0.XPCCNXM` OTA 镜像的大小、摘要、AVB hashtree、EROFS 内容及 stock 模块清单；该镜像不进入刷机包。正常构建不重新提取 stock 清单，不需要完整 OTA 或其余分区镜像；人工重建清单才需要 `evidence/os4.0.6.0/` 中同一 OTA 的 `boot.img`、`vendor_boot.img` 和 `vendor_dlkm.img`。原始外部证据仍按 `evidence/` 规则保留，不自动清理。

清单工具由 `patches/init.sh` 按固定 Git blob 与 SHA-256 准备于 `work/tools/stock-evidence/`。同一 OTA 的实机验收与静态模块闭包核对均已完成，范围见 [VALIDATION.md](VALIDATION.md)。

CI 按初始化、内核回移、外部组件接入、编译与审计的顺序运行以下脚本。

`patches/init.sh` 复用并校验固定源码、工具、AK3 模板、OTA 镜像与官方 CI Manager APK；`patches/patch.sh` 应用官方内核回移；`patches/patch_external.sh` 接入已准备的组件，不下载；`patches/build.sh` 编译并执行模块闭包、关键配置和独立快照审计，离线校验并交付配套 APK，不准备源码。补丁脚本必须幂等。

主仓库只消费固定依赖包。`.env` 必须配置回移 manifest 摘要、回移归档 URL/SHA-256、工具链归档 URL/SHA-256，以及工具链安装树摘要。回移版本为 [ci-deps-v1-247b450](https://github.com/LunaKernel/ci-dependencies/releases/tag/ci-deps-v1-247b450)，工具链版本为 [ci-deps-v1-3fc59ff](https://github.com/LunaKernel/ci-dependencies/releases/tag/ci-deps-v1-3fc59ff)。AK3 模板与 OTA 镜像使用独立的 [build-inputs-v1-d082477](https://github.com/LunaKernel/ci-dependencies/releases/tag/build-inputs-v1-d082477)，资产分别为 `ak3-template.tar.gz` 和 `system_dlkm-os4.0.6.0.img`，URL、SHA-256、模板树摘要及镜像大小由 `.env` 固定。`patches/init.sh` 校验模板归档 SHA-256、安全解包并校验树摘要。

初始化校验包内容、清单绑定与工具链安装树；补丁阶段校验 patch-id、允许路径、实际应用、撤销和有序重放。回移内容缓存位于 `work/cache/dependencies/backports-${BACKPORT_BUNDLE_MANIFEST_SHA256}`，工具链位于 `${BUILD_ENVIRONMENT_DIR}/toolchain/${CI_TOOLCHAIN_NAME}`，下载归档位于 `work/cache/downloads/ci-dependencies/`。

依赖制作、官方来源审计与候选调查由 [ci-dependencies](https://github.com/LunaKernel/ci-dependencies) 维护。更新时以固定主项目提交提供 pins 和补丁清单，在依赖仓库完成来源审计、组装及打包，发布新版本后更新主项目的 URL 与摘要。具体制作命令见依赖仓库 README。

额外模块模板由 [extra-modules](https://github.com/LunaKernel/extra-modules) 管理。主仓 `.env` 固定其提交与 `ipset/` 模板目录 SHA-256；`patches/init.sh` 拉取并校验模板，`patches/build.sh` 编译 IPSet 用户态命令、组装模块并交付。

人工重建 stock 清单时，通过依赖仓库准备历史资料，并向 `tools/extract_xiaomi17_android17_stock_common_kmi.py` 的 `--common-repo` 显式传入准备好的 AOSP 历史仓库路径。

`INIT_FETCH_JOBS` 仅控制独立依赖的准备并发，CI 使用 2；源码、工具和回移依赖共用槽位，任务完成后立即补位，任一任务失败会终止其他准备任务。它是运行时参数，不写入 `.env`，也不改变来源、工具链或内核参数。

## GitHub Actions

本地开发可运行 `git diff --check`、相关 shell 语法检查与 `bash tools/ci/check.sh`；这些轻量检查不执行完整编译。`metadata` 与轻量检查对 AK3 模板、OTA 镜像仅核对 pin 格式，不要求已恢复输入；实际输入验证在 init 准备后执行。完整编译与目标 OTA 模块闭包验证由以下 CI 工作流执行。

`.github/workflows/check.yml` 在 main 的 push 和以 main 为目标的 PR 执行轻量检查，使用 `.env` 固定的官方 actionlint 校验 workflow；`.github/workflows/build.yml` 仅支持从 main 手动触发完整构建，不创建 GitHub Release。云端构建状态以对应提交的 Actions 记录为准，现有实机验收只属于 [VALIDATION.md](VALIDATION.md) 中的既有二进制。

完整流程使用 GitHub 托管 `ubuntu-24.04`，分为 build、notify 两个 job：

- **build**：`tools/ci/prepare_runner.sh` 准备宿主，先检查空间，仅在不足时按固定白名单逐项清理无关 SDK，达到 50 GiB 即停止，安装依赖后再次检查；`tools/ci/run_build.sh` 通过 `metadata`、`init`、`compile`、`export`、`summary` 子命令调度现有流程。init 与 compile 共用 330 分钟预算，源码、工具、目标 OTA、配置、ABI/STG 和交付门禁全部保留。
- **缓存**：5 GiB ccache、固定下载、官方 Manager APK、干净 common 源码、回移内容目录和工具链安装树。依赖 key 绑定内容身份与缓存格式，init 验证成功后、patch 前保存。common 缓存要求工作树完全干净；ccache 使用 `compiler_check=content`。
- **交付**：校验六个交付文件及 `.build-artifacts`、`release.tsv` 后导出为保留相对路径的 `tar.gz`，上传为 Actions artifact，保留 30 天。新产物状态为 `awaiting-device`。
- **notify**：`tools/ci/notify_telegram.py` 使用仓库 Actions secrets `TG_BOT_TOKEN`、`CHAT_ID`，发送已校验的内核 ZIP 和官方 Manager APK，附件说明包含 `SHA256` 与 `Build`。通知失败时，可在 artifact 有效期内单独重跑 notify，复用同次构建产物。

两个 Telegram secrets 仅供 notify 使用。发送成功但响应丢失时，重试可能产生重复文件消息。

## 编译策略

固定 AOSP Clang r596125 / 22.0.2、Rust 1.97.0-dev（LLVM 22.1.6）、bindgen 0.72.1、kernel build-tools、宿主 bc，以及 IPSet 使用的 NDK r30 / API 35。Clang、Rust 各自保留独立 LLVM 库。依赖仓库制作时验证官方 Git 对象和检出树，主仓库构建时验证固定内容、安装树摘要及实际工具身份。

common 使用官方 `android16-6.12-2026-09_r11`（Linux 6.12.92 / KMI generation 6），仅构建和交付 4 KiB 页面版本。

C 使用固定 `-march` 和 `-mtune=oryon-1`；Rust 使用 `target-cpu=generic`、`tune-cpu=oryon-1` 与固定 ISA 列表，全部参数见 `.env`。保留 O2、CFI、Rust inline helpers、`LTO_NONE` 及原生 SIMD/分支保护约束。Rust 使用 softfloat，特性列表以 `-strict-align,-neon` 结束，允许普通内存非对齐访问；早期启动 C 保持严格对齐。

Binder 仅使用内置 Rust 实现及其 Binderfs，关闭 C Binder；`module_blacklist=rust_binder` 拒绝 ROM 同名旧模块。构建通过配置、`modules.builtin`、`modules.order`、`System.map` 和命令行证明替代关系；保留旧模块完整需求审计，其余 stock 模块严格检查 ABI/KMI。

实际模块闭包与全量参考快照分开检查：目标依赖的符号、CRC、provider、导出类型、namespace 和相关类型不兼容时拒绝发布；参考漂移须保留快照、完成审查并更新摘要。完整门禁见 [项目协作约束](PROJECT_RULES.md)。

AutoFDO 使用 common 自带的 `gki/aarch64/afdo/kernel.afdo`，校验摘要、Git blob 和 LLVM 可读性，实际 C/Rust 命令必须带 sample-use。固定 `-sample-profile-even-flow-distribution=false` 使用 Profi 官方单路径增广，规避均匀分流 DAG 搜索的异常耗时；保留最小费用流与 MIR profile loader。profile 来自 Pixel 工作负载，该参数影响权重推断和代码布局。

KernelSU 内嵌的 preinit runner 保持官方静态 nolibc 用户态参数，不使用内核 AutoFDO/ExtTSP；独立检查实际命令、arm64 ELF 与 Image 嵌入符号。

C/Rust 启用 ExtTSP，并以 `ext-tsp-apply-without-profile=false` 限于有 profile 的函数；审计实际命令和 LLVM 属性。Rust 仅 core 使用四线程前端，遵循 GNU Make jobserver，全部内核 crate 保持 `codegen-units=1`。

增量构建树位于 `work/cache/kernel/`；IPSet/libmnl 使用 `work/cache/userspace/ipset-sm8850/`、SM8850 ISA、Oryon-1 与正常用户态 SIMD。配置缓存绑定源码、NDK、API、路径及参数，变化时仅重建受影响缓存；交付校验 ELF、Android linker、依赖、版本和模块 ZIP。

内核与 NDK 共用 `work/cache/ccache/`，压缩开启、上限 5 GiB，NDK 身份包含完整工具树摘要。增量构建保留源码、安装树和下载缓存，输入或路径变化由构建系统处理。

预编译检查本次核心 C/Rust/helper 对象；完整 Image/modules 构建后检查所有活动编译命令、LLVM 属性和发布闭包。

宿主加速仅使用固定官方 `kbuild-next-speedups` 的 kallsyms token 索引及 C/链接器参数探测缓存，保留 6.12 Kconfig 语法与参数顺序；工具身份变化自动重探测。来源和等价性证据见 [`patches/backports/`](../patches/backports/)。

## 交付与身份

内核产物写入 `kernel_out/luna-xiaomi17-g<8位提交>-YYYYMMDD-HHMM/`，时间为上海时区。同名目录拒绝覆盖，文件仍为：

```text
luna-xiaomi17-g<8位提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<8位提交>-YYYYMMDD
```

官方 CI Manager APK 与 Image、内核 ZIP 同目录。审计 ZIP、日志和 `.build-artifacts` 位于 `work/audit/<同名目录>/`；IPSet 命令与模块 ZIP 位于 `work/components/<同名目录>/`。六个交付文件全部由清单绑定 SHA-256 和相对路径，`release.tsv` 指定配套 APK，导入导出必须保持完整。

AnyKernel3 模板源码（官方基线、Luna 补丁及许可证）维护于依赖仓的 [`ak3_template/`](https://github.com/LunaKernel/ci-dependencies/tree/build-inputs-v1-d082477/ak3_template)。`patches/build.sh` 使用 init 已校验的模板、BusyBox 和 MagiskBoot 组装刷机包，仅替换 Image，保留当前槽、分区容量和镜像大小检查。KernelSU/SUSFS 保持内核集成，不打包 SUSFS 模块或独立 helper。

Manager 使用 `.env` 固定的官方 main CI。`tools/ksu_manager.py` 校验源码/UAPI、归档与 APK 摘要、证书、包名版本和 arm64 组件，构建后核对实际内核接受的签名。优先复用 `work/cache/ksu-manager/` 或已有匹配 APK，缺失才下载固定 artifact；官方 artifact 过期不影响已保存 APK 的摘要验证。无可用副本时在编译前失败，须恢复同 SHA 官方 APK 或审查后更新 pin，不追随 latest、不本地编译替代。

构建只接受干净项目提交，成功后状态为 `awaiting-device`。产物、审计与缓存的保留和清理按 [项目目录规则](PROJECT_RULES.md#4-脚本职责) 执行。
