# 当前验证状态

开发分支 `feat/kmi6-2026-09-r8-rust-binder` 已切换到官方九月 r8，并改为内置 Rust Binder、关闭 C Binder、屏蔽 ROM 中同名模块。该开发状态尚未经完整构建及实机验证；以下验收仅属于历史 `g58672003`。

## 已验收基准

用户于 2026-10-07 确认 `6.12.92-android16-luna-g58672003-4k` 功能正常并验收，完整项目提交为 `586720039e9896d86e4e55dbdfd4bf8f01cd81b6`。

实机为小米 17 `pudding`、HyperOS 4 `OS4.0.0.32.XPCCNXM` / Android 17。身份、启动与模块记录、功能测试、dmesg、logcat 及 pstore/crash 文件检查位于 `evidence/device/luna-xiaomi17-g58672003-20261007-0030/`，由其中 `SHA256SUMS` 校验；大日志以 gzip 保留完整原始内容。用户确认屏幕、触控、拍照、声音和移动网络正常。

Image 和 AnyKernel3 ZIP 位于 `kernel_out/luna-xiaomi17-g58672003-20261007-0030/`；完整构建审计及五项交付清单位于对应 `work/audit/` 目录，`release.tsv` 标记为 `accepted`。更新验证文档不改变或重命名这些二进制，也不能把文档提交当作已构建内核。

完整本地构建及 ABI/KMI/STG 审计通过，无未确认漂移。构建闭包仍固定于 `OS4.0.0.9.XPCCNXM`：4083 项 vmlinux 依赖，103 个 system_dlkm 模块，其中 102 个严格匹配；唯一 Rust Binder 例外精确为 234 项需求、167 项匹配、67 项构建上下文符号缺失，无 CRC/provider 异常。`.32` 实机记录不替代 `.9` 的完整 OTA 闭包证明，也不扩大支持范围。

## 实机回归与范围

运行中的配置为 8261 行，SHA-256 `a21ee20190c2f129d240203835120d780f313c315a63f9f4c9a1684db05f8dde`，与本次 Image 和 `.env` 一致。669 个已加载模块与上一验收 `g8eb963eb` 的集合完全相同；启动完成，Rust Binder 在符号解析前按黑名单拒绝，C Binder 和关键服务正常。观察期间 boot ID 保持不变，未发现新的 panic、Oops、栈 WARN、lockup、CFI 错误或模块符号/CRC 拒绝；pstore 为空，无新增 tombstone/SSR 转储。

KernelSU 为 built-in、version code `32651`、UAPI `4`，提权及模块环境正常；SUSFS v2.3.0 的版本、variant 和启用功能查询正常。六项 LSM 与 SELinux Enforcing 保持，普通应用及 system_server 的 Seccomp 为 `2`，获准 root 为 `0`。

BBG 普通文件读写、共享映射正常；保护分区的零字节写调用、共享可写 mmap 和 mprotect 均返回 `EPERM`，并有三个对应拒绝日志。测试未写分区数据、未发送存储 ioctl，前后读取内容一致。初次在只读 `modem_a` 上的映射由原生只读规则返回 `EINVAL`；最终在非只读保护分区上完成三个钩子的测试。

新 IPSet 命令 SHA-256 为 `96358b9b24991d2a1fcf14b3c7869234b161c35eee872064ca61d794a7b5cba8`，经临时执行完成 IPv4/IPv6 集合创建、增删、查询（含 IPv4 未命中反例）和销毁。现有 IPSet 模块仍使用旧二进制，本轮未安装或替换模块；临时文件和集合均已清理。

设备运行时 `/sys/kernel/mm/lru_gen/enabled` 为 `0x0000`，因此未验证 MGLRU 不可回收页修复的实际回收路径，也未修改该策略。Rust 对齐、ExtTSP 等编译策略通过完整构建和本次启动回归，但未做性能、功耗、内存压力或长期稳定性测试。Kbuild 优化的生成结果和参数等价性属于本地构建验证。

早期非 PID 1 的 init 子进程 SIGABRT、可容忍的模块 BTF 调试信息不匹配、ptp_kvm 不支持及运行时非特权 BPF 开关为 `0`，与旧验收记录同类；init 根因仍未证明，本次观察未重复。Manager 的每秒提权轮询和用户态 SELinux 审计噪声仍存在，不据此新增内核修复。iorap2 已确认非本项目内核问题，功耗暂不追踪。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
