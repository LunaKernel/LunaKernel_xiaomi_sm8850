# 当前验证状态

开发分支 `feat/kmi6-2026-09-r8-rust-binder` 本轮更新至官方九月 r11，保留内置 Rust Binder、关闭 C Binder、屏蔽 ROM 中同名模块。按用户确认仅交付 4 KiB 版本，16 KiB 暂不交付。完整构建证据以本分支对应发布审计为准，尚未实机验收；以下验收仅属于历史 `g58672003`。

`eb7aa9ca` 已完成 r8 与内置 Rust Binder 的完整本地构建和模块闭包验证，`c0cb0f53` 已完成 KSU 32705 / SUSFS `3ff9fd3` 的完整本地构建。本次更新至 r11、KSU `51c21786`（32712 / UAPI 6）、SUSFS `6b60a30`、BBG `028ff7f` 与新版 AnyKernel3，删除 r11 已吸收的两项 Rust Binder 回移；保留兼容的 Clang r596125 / LLVM 22 与 Rust 1.97.0-dev。本次构建与实机状态按新提交的对应审计核实。Manager 须匹配新版接口，旧验收记录中的 32651 / UAPI 4 不适用于本次更新。

此前 r8 参考快照已完成相对旧验收归档的差异审查：配置只变更四个 Binder 项，活动模块减少同名 Rust Binder；全量导出减少 11 项、增加 8 项、3 项 CRC 变化，分别对应 C Binder 专属导出、r8 Rust 内部调整及新增音频 hook。STG 差异限于上述符号和 C Binder 类型定义消失；固定 OTA 的 4083 项五列依赖记录摘要保持一致。QCOM 参考中的两个 C Binder tracepoint 记为未导出，未删除参考对象。本次 r11 必须另行审查完整快照漂移并通过全部构建门禁，不沿用旧版本的通过结论。

LLVM 23 本轮不交付：固定 OTA 消费的 `net_ns_type_operations` CRC 从 `1cffd49b` 变为 `5cd5fc70`，虽然该符号及全部可达类型的 STG 文本除 CRC 外完全一致，仍不满足模块闭包硬门禁。已确认 gendwarfksyms 输出类型串存在分隔符差异，最新官方 Linux 与 ACK 尚无对应修复；因此选择兼容的 LLVM 22 配对，撤销仅 Rust 1.98 需要的参数更名回移，保留 r11 和其他组件更新。

当前输入下 LLVM 22/23 均在 `filemap.o` 的 MIR profile 流量推断中出现持续单核异常耗时。只追加官方 `-sample-profile-even-flow-distribution=false` 的隔离编译分别在 1.369/1.271 秒完成；该策略保留 AutoFDO、Profi 最小费用流和 MIR loader，实际 C/Rust 最终参数独立审计。此验证说明该对象可以正常编译，不代表权重推断或实机性能等价。

## 已验收基准

用户于 2026-10-07 确认 `6.12.92-android16-luna-g58672003-4k` 功能正常并验收，完整项目提交为 `586720039e9896d86e4e55dbdfd4bf8f01cd81b6`。

实机为小米 17 `pudding`、HyperOS 4 `OS4.0.0.32.XPCCNXM` / Android 17。身份、启动与模块记录、功能测试、dmesg、logcat 及 pstore/crash 文件检查位于 `evidence/device/luna-xiaomi17-g58672003-20261007-0030/`，由其中 `SHA256SUMS` 校验；大日志以 gzip 保留完整原始内容。用户确认屏幕、触控、拍照、声音和移动网络正常。

Image 和 AnyKernel3 ZIP 位于 `kernel_out/luna-xiaomi17-g58672003-20261007-0030/`；完整构建审计及五项交付清单位于对应 `work/audit/` 目录，`release.tsv` 标记为 `accepted`。更新验证文档不改变或重命名这些二进制，也不能把文档提交当作已构建内核。

完整本地构建及 ABI/KMI/STG 审计通过，无未确认漂移。构建闭包仍固定于 `OS4.0.0.9.XPCCNXM`：4083 项 vmlinux 依赖，103 个 system_dlkm 模块，其中 102 个严格匹配；唯一 Rust Binder 例外精确为 234 项需求、167 项匹配、67 项构建上下文符号缺失，无 CRC/provider 异常。`.32` 实机记录不替代 `.9` 的完整 OTA 闭包证明，也不扩大支持范围。

## 实机回归与范围

历史验收运行配置为 8261 行，SHA-256 `a21ee20190c2f129d240203835120d780f313c315a63f9f4c9a1684db05f8dde`，与当时 Image 和 `.env` 一致。669 个已加载模块与上一验收 `g8eb963eb` 的集合完全相同；启动完成，Rust Binder 在符号解析前按黑名单拒绝，C Binder 和关键服务正常。观察期间 boot ID 保持不变，未发现新的 panic、Oops、栈 WARN、lockup、CFI 错误或模块符号/CRC 拒绝；pstore 为空，无新增 tombstone/SSR 转储。

KernelSU 为 built-in、version code `32651`、UAPI `4`，提权及模块环境正常；SUSFS v2.3.0 的版本、variant 和启用功能查询正常。六项 LSM 与 SELinux Enforcing 保持，普通应用及 system_server 的 Seccomp 为 `2`，获准 root 为 `0`。

BBG 普通文件读写、共享映射正常；保护分区的零字节写调用、共享可写 mmap 和 mprotect 均返回 `EPERM`，并有三个对应拒绝日志。测试未写分区数据、未发送存储 ioctl，前后读取内容一致。初次在只读 `modem_a` 上的映射由原生只读规则返回 `EINVAL`；最终在非只读保护分区上完成三个钩子的测试。

新 IPSet 命令 SHA-256 为 `96358b9b24991d2a1fcf14b3c7869234b161c35eee872064ca61d794a7b5cba8`，经临时执行完成 IPv4/IPv6 集合创建、增删、查询（含 IPv4 未命中反例）和销毁。现有 IPSet 模块仍使用旧二进制，本轮未安装或替换模块；临时文件和集合均已清理。

设备运行时 `/sys/kernel/mm/lru_gen/enabled` 为 `0x0000`，因此未验证 MGLRU 不可回收页修复的实际回收路径，也未修改该策略。Rust 对齐、ExtTSP 等编译策略通过完整构建和本次启动回归，但未做性能、功耗、内存压力或长期稳定性测试。Kbuild 优化的生成结果和参数等价性属于本地构建验证。

早期非 PID 1 的 init 子进程 SIGABRT、可容忍的模块 BTF 调试信息不匹配、ptp_kvm 不支持及运行时非特权 BPF 开关为 `0`，与旧验收记录同类；init 根因仍未证明，本次观察未重复。Manager 的每秒提权轮询和用户态 SELinux 审计噪声仍存在，不据此新增内核修复。iorap2 已确认非本项目内核问题，功耗暂不追踪。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
