# 当前验证状态

## 已验收基准

用户已确认 `6.12.92-android16-luna-g8eb963eb-4k` 可用，2026-10-06 作为当前验收基准。完整项目提交为 `8eb963eb4af4d478c2b5878190869ec89221b667`。

实机为小米 17 `pudding`、HyperOS 4 `OS4.0.0.32.XPCCNXM` / Android 17。保留的身份、启动与模块记录、功能检查、dmesg、logcat 及 pstore/crash 文件检查位于 `evidence/device/luna-xiaomi17-g8eb963eb-20261006-0208/`，由其中 SHA256SUMS 校验。

原始 Image 和 AnyKernel3 ZIP 位于 `kernel_out/luna-xiaomi17-g8eb963eb-20261006-0208/`。构建审计及交付清单位于对应的 `work/audit/` 目录；迁移保持八项交付文件原始摘要。

构建闭包仍固定于 `OS4.0.0.9.XPCCNXM`：4083 项 vmlinux 依赖，103 个 system_dlkm 模块，其中 102 个严格匹配；唯一 Rust Binder 例外精确为 234 项需求、167 项匹配、67 项构建上下文符号缺失，无 CRC/provider 异常。`.32` 实机记录不替代 `.9` 的完整 OTA 闭包证明，也不扩大支持范围。

## 待验改动

以下改动尚未实机验收；完整本地构建与 OTA 闭包结果以新提交对应的 `work/audit/` 发布清单为准。

`a5b887dd` 的 `module_blacklist=rust_binder` 策略保留 C Binder、Rust Binder 模块配置和既有精确闭包审计，在符号解析前屏蔽 Rust Binder 加载；不把黑名单作为启动门禁。

Rust 取消普通内存 strict-align 已通过 kernel/helpers 合并 bitcode 的实际 LLVM 属性检查，softfloat 与 SIMD 禁用约束保持。IPSet/libmnl 的 SM8850 参数、Android ELF/模块包、增量复用、配置失败与编译中断恢复已通过本地验证，尚未实机验收。

MGLRU 不可回收 folio 处理回移固定于官方 `f7e698e326b239a91ea15844817551921209e826`，仅适配 r21 上下文并保留 Android vendor hook；已通过 `mm/vmscan.o` 对象编译。当前 37 项独立清单均已通过单项应用、撤销及完整重放，固定基础差异保持不变。

Kbuild 宿主优化只含固定的 kallsyms token 索引和参数探测缓存链。真实符号表输出及原生构建参数等价、宏支持/拒绝/回退语义、工具身份刷新、no-op 时间戳保持和来源/路径拒绝测试通过；不改变既有启动或 ABI 门禁。

BBG 仅调整 file_permission、mmap_file 和 file_mprotect 的判断顺序，使普通读、非共享写映射及非块设备提前返回；7,776 组局部策略对比一致，其余保护钩子保持原实现。仅对有 profile 函数启用的 ExtTSP 已通过三个代表对象编译，75 个导出 CRC 一致，尚无小米实机性能数据。Rust 仅 core 使用四线程前端，局部编译约 9.23→7.76 秒，峰值内存增加约 116 MiB；完成原有符号重命名后，对象与元数据均与原产物逐字节一致。完整新构建及实机状态仍以对应提交的发布审计和验收记录为准。

已验收 Image 的配置为 8249 行、SHA-256 `9a708cd313d37073cb2e5b1614a4044e003661ea05700e10b614d5c03e85f22c`。当前 `.env` 的 8261 行参考配置包含新增黑名单及 12 个探测缓存项；原有 6576 项配置值与黑名单参考保持一致。新提交不能继承旧 Image 的实机身份。

iorap2 已确认非本项目内核问题，不列为待修复项；功耗暂不追踪，用户态问题不扩展为本项目修复责任。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
