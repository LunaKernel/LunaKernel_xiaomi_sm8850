# 九月基线全量补丁必要性与质量审计

本文保留 `3ecabf88` 之前的全量去重审计事实。后续官方 AutoFDO 及两项低开销回移见 [独立接入记录](AUTOFDO-2026-09.md)；当前结构化清单为 98 条、直接回移为 63 项，不覆写下述历史比较。

本轮在 `chore/kmi6-2026-09` 上，以 `edeb0276e0dbe9cdcea2f9f6d2eed4eef1c95518` 的已验证源码和产物作为对照。Linux 6.12.92 / KMI6、同一 HyperOS 4 OTA、KSU `623eba3e`、SUSFS `b213c54`、BBG `a54e0dc` 与工具链均不升级。此次审计处理已有差异，不增加回移候选、参数调优或功能。

## 逐项结论

[结构化质量清单](../patches/backports/kmi6-2026-09-quality.tsv) 共 95 行：62 个直接修复逻辑项、25 个外部补修/吸收/上下文/拒绝记录、8 个接入与产品配置项目。清单区分静态可达性、有效构建对象、机制、来源及验收限制；它补充原[吸收清单](../patches/backports/kmi6-2026-09-absorption.tsv)，后者仍描述当时迁移事实，不覆写历史。

直接修复由 62 项减为 **61 项**：19 项有序集合（23 个来源提交）、31 项独立集合、11 项脚本直接逻辑修复（12 个来源提交）。前置/补修链保持完整，独立清单和来源 pin 不变。小补丁不因行数少而自动删除，也不因官方身份或可应用而自动保留。

| 实际精简 | 证据与影响 |
| --- | --- |
| 删除 EAS cpumask 空集判断回移 `ff1de90dd7a6` | 当前 arm64 `NR_CPUS=32`，两个 bitmap 操作原生已走单字内联。固定 r536225、实际内核编译参数与实际头文件分别编译旧/新表达式，生成指令完全相同；未形成该产品的代码收益。撤销源码层，同时删除准备、应用、构建检查、允许路径和 pin 的失效入口。 |
| 删除 BBG `bbg_process_setpermissive()` 与 `bbg_test_domain_transition()` 及声明 | 最终 common/KSU/BBG 源码中均无调用，未导出，只返回 0。删除遗留空实现，不关闭 SELinux 能力，不用空 provider 遮掩闭包失败；必要的 cred 标记/复制、拒绝入口与日志保留。 |

保留判断不是要求“证明真机已经触发过每个缺陷”。网络报文、文件系统损坏元数据、线程退出、接口销毁以及显式可选的 governor/BPF/隧道接口本来就是内核必须正确处理的输入。清单按实际构建路径及可触发接口评价，不把历史实机日志未触发当作无效证明。

## 性能项与跨层重叠复核

- Timer base：先决定 index，再取 per-CPU 地址，避免 deferrable 分支重复取地址。实际参数编译对照产生代码差异；仅作为代码生成证据，不外推实机延迟/功耗。
- F2FS：DIO 首映射区间检查与普通 buffered cached overwrite 的入口不同；后者排除 inline/compressed，前者保留公共 helper 的完整检查。两者不互相替代。atomic retry、ACL/xattr/orphan 边界、GC 提交链是正确性修复，不能按“文件同名”合并删除。
- PSI/MEMCG/MGLRU：零 IRQ 增量退出省去压力统计后续处理；rstat 可刷新时退出祖先遍历省去层级更新；memcg 达到 reclaim 目标后停止扫描避免过度回收。三者机制、状态及入口不同；不引入新回收参数，基线原生 freezer/signal 处理保留。
- BLK_WBT：只把读请求状态访问放进已有 read 分支，减少非 tracked write 完成的共享状态读取。block plug 删除只针对单 bio 内层创建/立即结束的 plug，不取消文件系统批量 plug；blk_time 竞争修复仍需用于存在 plug 的路径。
- TCP 时间戳：减少 recv 消费路径的时间采样调用，ACK 发送前仍刷新，无 RTT 样本时退出。上游 x86 测试周期不能当作 SM8850 收益。
- EAS runnable_avg 是迁移任务的容量估算算术修复；schedutil 修复在共享 policy 初始化后才发布 hook。stock WALT 优先选择路径不证明所有 CFS/governor 回退永远无效，不据此移除正确性修复。PSI 和 schedutil 被 `kernel/sched/build_utility.c` 合并编译，不能因没有独立 `.o` 误判未构建。
- IPv6 设备 `in6_dev_get`、MLD work 引用和 MLD skb head 重分配是三个独立生命周期；MAC header 读取检查与 IPv6 defrag sentinel 保护是不同入口。IPSet publication、blk-mq cached request、BPF linked delta 与 F2FS GC 的前置/补修链均整体保留。

目标为合理收益及低维护成本，不把一次比较的省略等同所有微小修复，也不要求缺少手机跑分就删除机制明确的热路径改动。没有量化实机结果的性能项仅报告机制，不标注未经测量的百分比。

## 外部层与完整差异证明

SUSFS 三项已吸收补修仍不携带；cmdline 重试输出修复仍使用上游结果，仅保留实际并发分配/读写互斥。KSTAT hash 查询逐入口核对完整可用键，fsnotify final free 与持有引用的 put 各司其职。SUS_MAP 的远程访问必须在 GUP 前检查实际 VMA，自定义 pagewalk 保留默认 VM_PFNMAP 行为。路径隐藏保留 RCU 重试、dentry 引用清理和正常失败语义；不通过 SELinux 绕过权限检查完成隐藏。

KSU `on_post_fs_data` 有 ioctl dispatch 与首次 zygote exec 两条调用路径，函数内原子门闩不能删除。dispatch 对重复用户事件的外层门闩及启动完成时启动 sdcard monitor 是不同边界。KSU/SUSFS 的两个 fsnotify group 各有独立分配对象，需要各自的 free_mark。BBG 凭据标记覆盖实际三处 commit_creds，保持 built-in、独立一槽 LSM 及无导出的内部接口。

官方组件未构建的兼容分支、关闭的 OPEN_REDIRECT 源码以及 MAC 修复附带但未构建的 eui64 块，不计作有效功能或收益。对这些固定官方内容不另造裁剪层、路径例外或整树重写；删除的是没有必要的项目回移和空补修。OPEN_REDIRECT 成功 readlink 返回值/短 buffer 缺陷仍未完整解决，继续编译期关闭；官方不适用 fdinfo 块继续排除，目标文件保持 AOSP 原样。

Tegra 的两个不透明指针接口虽然不对应 SM8850 控制器，确由固定 OTA 模块闭包消费。窄类型字符串兼容层必须保留，不能以 SoC 名称推断它无用。

`kernel_out/full-patch-quality-audit/` 保存本轮原始差异、旧 pin/完整快照、官方消息、后续引用检索、代码生成比较、按真实顺序重放及逐差异块归属。重放从三个固定仓库的 HEAD 起，依次应用真实官方/适配补丁、必要的 Kbuild 接入和复制文件，并逐文件比较最终字节与链接目标。不得只以允许路径或 patch-id 替代完整重放证明。本轮精确重放覆盖 common 96、KSU 29、BBG 4 个文件/链接，共 713 个无上下文差异块；704 块按改变行归属，9 块因相同空行/大括号移动按邻接上下文归属，最终字节匹配仍是硬条件。`hunk-coverage.json` 的 SHA-256 为 `cf7d313a64dc4f2f0acd23f3688dd262be8ef9e55013dbb97e56a12bd8312428`。

官方后续修复/回退检索仅覆盖 `.env` 固定 AOSP/mainline/stable 审计终点与实际 common 基线，已识别的 blk-mq 补修在同一不可拆链中。该结论不声称已检查固定快照之后的全部上游历史。本轮所有取证复用本地对象，没有为了扩大审计范围重新下载历史或整树。

## 验证与发布条件

脚本语法、源码差异检查、来源/摘要、精确应用与撤销、独立项单独应用/撤销、完整顺序重放及脚本幂等性必须通过。改动后的构建只复用 `kernel_out/.build-kmi6-2026-09` 和 ccache；不 clean/mrproper、不逐项编译内核。代码生成比较为必要的小对象验证，不是额外完整构建。

固定 4083 项 OTA tuple、102 个严格 system_dlkm 模块及 Rust Binder 精确 167/67 例外不随本轮审计改变。关键配置、模块矩阵、目标消费者 STG 与完整参考快照均须比较；漂移不能自动写回参考值。所有新包仍是候选，构建记录保存在上述审计目录；没有新的同 OTA 设备日志时，不宣称启动、硬件、SUSFS/KSU/BBG/SELinux/IPSet 真机复测已经完成。
