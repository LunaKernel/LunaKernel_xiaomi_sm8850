# 九月 KMI6 基线迁移

## 固定身份

- 项目分支：`chore/kmi6-2026-09`，从 `8d841e3` 创建，保留原有本地提交。
- AOSP：`android16-6.12-2026-09` @ `0316e9866fdf55601aae97b14ee08d1b38a3916c`。
- Linux 6.12.92、KMI generation 6、clang r536225 与 Rust 1.82.0.p2。
- 该提交是正式 r3 `db9bd6c1` 的直接后继，新增禁止释放 pKVM 内部 identity domain 的修复。
- 小米基线、固定 OTA、组件版本、工具链和 Image-only 交付边界保持既有固定值。

## 补丁去重

逐项记录见 [吸收清单](../patches/backports/kmi6-2026-09-absorption.tsv)。审计覆盖原有序集合、42 个独立项与 16 个单独逻辑修复，共 81 个逻辑项、89 行来源记录。

- 19 个逻辑项完整吸收、1 个部分吸收、61 个仍需完整回移。删除 20 个应用来源行及 1 个 F2FS mainline 证明行。
- 有序集合从 23 项 / 28 个应用行精简为 19 项 / 23 行；独立集合从 42 项精简为 31 项；单独修复从 16 项精简为 12 项。
- Ethernet MAC header 链第一项已进入基线，只携带第二项；新基线 SHA 与吸收清单保留前置来源证明。
- 普通 F2FS write-end 的 stable 修复已原样进入基线，移除项目两行上下文适配及仅服务该回移的证明行。
- POSIX CPU timer 修复经 AOSP `8eff909dd82da10a599468a514cc1ad07e90c3cc` 吸收，绑定同一 mainline 原始提交并通过最终树 reverse-check。
- hrtimer 修复 `d8d7b0043acc` 是基线祖先；后续修改增加 enqueue 参数，已核对 enqueue 后 `in_hrtirq` 早退仍存在，不因上下文冲突继续携带重复层。
- 其他删除项均有官方祖先关系与最终树 reverse-check；对应修复未因后续回退丢失。

Tegra 两个不透明指针接口仍保留原有窄 KMI 标注。剩余直接修复使用既有固定来源，未新增候选或扩大授权集合。SUSFS 上下文补丁调整为 6.12.92：旧 smaps_rollup 已被上游重写，在新全量/区间统计调用前接入同一隐藏判断，保持原生 VMA 锁、遍历、统计范围和 last_vma_end 更新。其他接入与 BBG 补丁保持原样。

## 下载与编译复用

九月 Image 源码使用独立目录。审计仓库复用本地历史与新源码 pack，仅补缺失提交元数据；源码 pack 复制不使用 object alternates，也不覆盖 r21 或小米基线。

九月初始化提交将 2023 初始根与 LTS 合并。旧 `2025-01-01` 浅历史边界会截断整个 merge，仅新构建基线的浅历史日期使用 `2023-10-04`；原有回移来源快照保持 r21 / 2026-08-28 和原水合身份，避免升级构建基线时重取未变的来源历史。这不授权新增回移。

本地 r21 只保留验证证据，没有可复用的完整 `.o` 构建树，因此新基线需要首次完整编译。后续保留新构建目录，使用增量编译完成快照更新和最终项目身份验证，不执行 clean 或 mrproper。

## 验证状态

首次完整构建已生成 Image 与 104 个模块，固定 OTA 的 4083 项 vmlinux 依赖及完整 tuple、Rust Binder 精确例外、vermagic、关键配置、LSM 槽位与项目功能构建检查全部通过。脚本在 12 项参考漂移处按预期拒绝打包；已保留首次完整快照、完成下述审查并更新 `.env`。最终打包仍由同一脚本执行零漂移检查。真机复测未执行；r21 真机结论不得外推到本版本。

## 参考快照漂移审查

| 对象 | r21 | 九月 | 结论 |
| --- | ---: | ---: | --- |
| 配置行数 | 8236 | 8246 | 关键启动与安全配置守卫通过 |
| modules.order | 104 | 104 | 内容及排序摘要不变 |
| 全量导出 | 19703 | 19794 | 固定消费者无删除或变更 |
| vmlinux 导出 / STG 根符号 | 19105 | 19196 | 同上 |
| QCOM/Xiaomi 列表并集 | 4723 | 4740 | 原 4723 项 CRC 全部不变，新增 17 项 |

全量差异包含 1121 个新增、1030 个删除、173 个 CRC 变化。删除项全部是 Rust 生成符号；新增项包括 1032 个 Rust 生成符号与 89 个 C 导出。173 个变化仅涉及 CRC，provider、export type 和 namespace 未变化；50 个是 Rust 符号，123 个 C 接口分别属于 fscrypt（48）、KVM/VFIO（66）、nfqueue（4）、FunctionFS（2）、dm-verity hooks（2）和 PCI endpoint MSI-X（1）。上述删除及 CRC 变化均无固定 OTA 消费者，不扩大 Rust Binder 缺失例外。新建模块和内核仍同次构建，原有 104 项模块矩阵不变。

C 变化来自固定官方源码：fscrypt 密钥管理修复、pKVM 与 KVM 内部类型、nfqueue 生命周期保护、FunctionFS endpoint/rw_proxy、dm-verity 私有类型解耦及 PCI 类型依赖。代表来源包括 `89ffa47ebb4b`、`6a379f037a29`、`5c165027e17c`、`de3d34623482` 与 `50bf35d628ad`。新增 C 导出主要是原生 vendor hooks、Tegra/音频接口及通用 helper；现有消费者接口的签名、CRC 和 tuple 不变。运行时回归仍需固定 OTA 真机复测。

消费者 STG 以 4083 项 stock 依赖和 Rust Binder 167 项匹配需求的去重并集（4142 个根符号）比较，只有四处类型差异：

- `task_struct` 使用 `ANDROID_KABI_USE(3, ...)` 占用既有保留槽，原类型大小及其他字段偏移不变。
- `cfs_rq.min_vruntime` 使用 `ANDROID_KABI_REPLACE` 增加同宽 union，原字段位置和大小保持。
- `trace_buffer` 是 `ring_buffer.h` 中仅前置声明的不透明对象，内部删除冗余 subbuf_size；相关消费接口 CRC 不变。
- `fscrypt_master_key` 只在 `fs/crypto/fscrypt_private.h` 定义，密钥列表和缓存布局属于内核内部实现；消费接口及对外类型布局保持兼容。

配置漂移来自 AOSP 原生配置：`54d5133dd5d9` 开启 DAMON 分析接口，但 DAMON_RECLAIM/LRU_SORT 未启用；`1d5d2bee38d2` 统一 RCU lazy 默认关闭策略，仍保留 RCU_LAZY 能力；`aa2b7dc0d9bc`、`7ae1ce18e14d` 与 `8334d1199d20` 提供 Tegra context bus、音频 MMIO 和 VPR 初始化。VPR 只匹配 `nvidia,tegra-video-protection-region` DT 节点，system/CMA DMA-BUF heaps 仍关闭。

首次完整审计快照与结构化 `snapshot-delta.json`、全量/消费者 STG 差异保留在 `kernel_out/kmi6-2026-09-migration-audit/`；最终完整快照随构建审计归档交付。不得把全量 Rust 或内部类型变化推广为其他设备或 OTA 的兼容性结论。
