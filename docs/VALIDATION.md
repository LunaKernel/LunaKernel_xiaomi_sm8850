# 当前基线与验收

当前内核基线为官方九月 r11 / Linux 6.12.92 / KMI 6，仅交付 4 KiB；Rust Binder 内置，C Binder 关闭，ROM 同名模块被屏蔽。用户于 2026-11-08 确认 `6.12.92-android16-luna-g1d3c30f1-4k` 在 `OS4.0.6.0.XPCCNXM` 上完成严格实机验收；同日只读核对确认设备运行身份一致。

已验收项目提交为 `1d3c30f1945ad2c70bbf084886339649b3017123`，使用 KSU `51c21786`（32712 / UAPI 6）、SUSFS `6b60a30`、BBG `028ff7f`、Clang r596125 / LLVM 22 与 Rust 1.97.0-dev。验收记录绑定该提交与下述 Image 摘要。

对应构建审计保存完整配置、模块、导出及 STG 快照。r11 的官方 `dw_pcie_rp` 位域变化已审查，不影响当时固定 OTA 的消费者类型图；两个 C Binder tracepoint 没有目标消费者，保持未导出。历史版本的差异和排查过程从 Git 历史检出。

LLVM 23 不在当前基线中：此前实测 `net_ns_type_operations` CRC 从 `1cffd49b` 变为 `5cd5fc70`，gendwarfksyms 类型串存在分隔符差异，不满足固定 OTA 闭包。保留已验证的 LLVM 22 配对；未来升级必须重新证明兼容性。

AutoFDO 的官方单路径增广参数已消除当前输入下 `filemap.o` 的异常编译耗时，实际 C/Rust 参数独立审计。具体策略见 [BUILDING.md](BUILDING.md)。

## 已验收基准

Image、AnyKernel3 ZIP 与配套官方 Manager APK 位于 `kernel_out/luna-xiaomi17-g1d3c30f1-20261031-0332/`；完整构建审计、交付清单和 `accepted` 状态位于同名 `work/audit/` 目录。Image SHA-256 为 `2bdae1def07346f10da42449130fa00f26a660eabf2415198a9c671464b9f124`。

实机为小米 17 `pudding` / Android 17。身份与启动完成记录位于 `evidence/device/luna-xiaomi17-g1d3c30f1-20261031-0332/`，由 `SHA256SUMS` 校验；严格功能验收由用户确认。

原构建审计针对 `.9` OTA，保持其原始含义。新基线 `OS4.0.6.0.XPCCNXM` 的四镜像、payload 元数据及补充核验记录位于 `evidence/os4.0.6.0/`，大小和摘要逐项匹配同包 manifest，system_dlkm 的 AVB/EROFS 完整性通过。

复用与交付 Image 完全相同的构建缓存完成新 OTA 静态核验：678 个去重模块中 677 个严格闭包，唯一 stock Rust Binder 单独按内置替代审计；4090 项 vmlinux 依赖无缺符号、CRC 或 provider 错误，模块 namespace、GPL 导入及依赖图检查通过。相对旧清单新增 8 项、移除 1 项，共有接口 CRC 未变。stock Rust Binder 的 240 项需求完整保留（166 项匹配、74 项构建上下文符号缺失，无 CRC/provider 异常）；该模块由内置 Rust Binder 替代，模块屏蔽及无 C 初始化函数的证据均通过。

新 4090 项接口及全部可达类型图，从原完整 STG 归档与同 Image 的 vmlinux 两路提取后逐字一致，SHA-256 为 `bfae072ca3f63c7ccbe7526aaea2187f77734e100f3e51c6fb6824f56c8a4654`。本次未重新编译内核，也未改变其配置或优化参数。

历史问题与排查记录保存在 Git 历史和 `evidence/`。每个新 Image 按以下流程独立验收。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
