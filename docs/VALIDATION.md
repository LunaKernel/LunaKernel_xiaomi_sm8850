# 验证记录

## 固定目标

- 设备：小米 17（`pudding`）
- OTA：HyperOS 4 `OS4.0.0.9.XPCCNXM`
- Android：17
- AOSP GKI：`android16-6.12-2026-06_r21`
- common：`0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28`
- 内核：Linux 6.12.81、arm64、4 KiB

## 构建期兼容性

固定清单覆盖 boot、vendor_boot、vendor_dlkm 与 system_dlkm 中目标设备可能使用的模块，并验证 4083 个实际 vmlinux 依赖的符号、CRC、provider、导出类型和 namespace。

system_dlkm 含 103 个 stock 模块。其中 102 个必须完整匹配；`rust_binder.ko` 是唯一固定例外：234 项需求中 167 项匹配、67 项为 stock Rust 构建上下文符号，且不存在 CRC/provider 异常。目标启动输入没有选择 Rust Binder，系统使用 C Binder；该例外不能扩展到其他模块或符号。

完整配置、模块矩阵和 ABI/KMI 快照会随构建保留。快照漂移必须审计，但只有目标 OTA 消费接口或关键启动语义不兼容时才构成硬失败。

## 真机记录

2026-08-29，公开历史整理前的项目提交 `838d2857` 对应内核：

```text
6.12.81-android16-luna-g838d2857-4k
```

已在固定目标 OTA 上完成以下验证：

- 正常启动并达到 Android boot completed。
- 存储、显示、Binder、SELinux/LSM、seccomp、BPF 和目标 vendor 模块未出现关键加载失败。
- KernelSU、SUSFS、Baseband Guard 与 IPSet 正常工作。
- 使用期日志未发现内核 panic、Oops、watchdog 或持续性严重内核错误。
- 系统按预期使用 C Binder；未观察到 `rust_binder.ko` 被启动路径选择。

公开历史整理没有改变补丁集合和内核源码结果，但会改变项目提交哈希与内核 release 字符串；AnyKernel3 也改为从固定源码重新组装。因此公开主分支的最终提交仍需完成一次干净构建、闭包复核和真机复测，才可标记二进制版本。

## 发布验收

每个候选版本至少记录：

- `uname -a`、`/proc/version`、boot completed、活动槽和 verified boot 环境说明。
- 预期模块加载及 unknown symbol、CRC、namespace、vermagic、CFI/BTF 错误检查。
- Binder、BPF sysctl、SELinux/LSM、KernelSU、SUSFS、Baseband Guard 与 IPSet 状态。
- dmesg、logcat 和 pstore 中的 panic、Oops、watchdog 与关键硬件错误。

环境隐藏可能使 Android 属性显示为 green/locked；验收时应同时记录 bootconfig 和测试环境，避免误判。
