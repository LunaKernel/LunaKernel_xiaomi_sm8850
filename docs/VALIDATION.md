# 当前验证状态

## 已验收基准

用户已确认 `6.12.92-android16-luna-g8eb963eb-4k` 可用，2026-10-06 作为当前验收基准。完整项目提交为 `8eb963eb4af4d478c2b5878190869ec89221b667`。

实机为小米 17 `pudding`、HyperOS 4 `OS4.0.0.32.XPCCNXM` / Android 17。保留的身份、启动与模块记录、功能检查、dmesg、logcat 及 pstore/crash 文件检查位于 `evidence/device/luna-xiaomi17-g8eb963eb-20261006-0208/`，由其中 SHA256SUMS 校验。

原始 Image 和 AnyKernel3 ZIP 位于 `kernel_out/luna-xiaomi17-g8eb963eb-20261006-0208/`。构建审计及交付清单位于对应的 `work/audit/` 目录；迁移保持八项交付文件原始摘要。

构建闭包仍固定于 `OS4.0.0.9.XPCCNXM`：4083 项 vmlinux 依赖，103 个 system_dlkm 模块，其中 102 个严格匹配；唯一 Rust Binder 例外精确为 234 项需求、167 项匹配、67 项构建上下文符号缺失，无 CRC/provider 异常。`.32` 实机记录不替代 `.9` 的完整 OTA 闭包证明，也不扩大支持范围。

## 待验改动

`a5b887dd` 的 `module_blacklist=rust_binder` 策略待下次完整编译和实机验收。保留 C Binder、Rust Binder 模块配置和既有精确闭包审计，在符号解析前屏蔽 Rust Binder 加载；不把黑名单作为启动门禁。

已验收 Image 的配置为 8249 行、SHA-256 `9a708cd313d37073cb2e5b1614a4044e003661ea05700e10b614d5c03e85f22c`。当前 `.env` 的参考配置包含新增黑名单，尚未出现在该 Image 中。目录整理后的新提交同样没有新 Image，不能继承旧提交的实机身份。

iorap2 已确认非本项目内核问题，不列为待修复项；功耗暂不追踪，用户态问题不扩展为本项目修复责任。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
