# Hanamaki 26w36e：所选内核方向与 Luna 深入对比

分析日期：2026-09-07。承接[首轮拆解](HANAMAKI-26W36E-ANALYSIS.md)，本轮仅研究用户选择的 **03、06、07、08、09、10**，以及 stock 模块屏蔽、防护/诊断裁剪、实际 Binder 实现切换。01、02、04、05 暂不推进；03 只讨论排除 04 后还能成立的范围。[配套模块另行分析](HANAMAKI-26W36E-COMPANION-ANALYSIS.md)，可作为未来 Luna 优化模块的研究输入，目前未纳入产品。

本轮结论：**优先验证 06 的单个小尺寸 mTHP、08 的单项水位/预读参数；07 是有条件的抗颠簸策略；10 已确认目标 OTA 有对应接口，值得定向研究；03 有机制价值，但尚无可独立落地的官方实现；09 在本包正常初始化流程中没有确认的有效调用。** 不把来源缺口或缺少实测本身当作机制无价值，也不把合理机制写成已经证实的收益。

## 1. 比较口径与证据身份

- Hanamaki：原包 SHA-256 `0af63f2efcc269134eca148986a19df5827355613a5fb565a5f88054d92acfff`；Image SHA-256 `f9ce4918408d961b2afe9937f8c745ec29c02f0d201b5c71a98edb73e3f432a3`；release `6.12.69-android16-6-4k-Hanamaki-26w36e`。机器码位置均为解压 Image 偏移，反汇编外壳不是原始 vmlinux。
- Luna：项目分析起点 `7308e4a`，AOSP common 固定基础 `0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28` 加项目允许补丁；配置取已构建 `gd753d8b2` 产物，SHA-256 `b35ffd54c23acf009c1819d01614ecc40b53845b1bb3e7b6b7018622e872c935`。旧产物不能证明当前项目哈希通过真机复测。
- 下文“Luna 默认”是固定源码/配置的启动初值，**不是 HyperOS 启动后实测值**。vendor 模块、init、LMKD 和已有用户模块可能再次改值。Hanamaki 脚本值也只表示尝试写入；其 `mask_val` 可在写入失败后用普通文件 bind 覆盖节点，显示值不能单独证明内核接受了设置。
- 本轮从固定 `OS4.0.0.9.XPCCNXM` OTA 定点提取 vendor_boot/vendor_dlkm，并与项目已有镜像身份核对；system_dlkm 沿用固定输入。DTB 共 12 个 FDT，完整 6,557,303 字节，SHA-256 `0182b665c5e611eb1db3febff0fb503738c454ed77eb18d64daab8d6cd555876`。设备树证明输入具有该拓扑，不代替启动后 DT overlay、固件响应和实际节点检查。
- 全程静态分析；未运行包内程序、修改内核/配置/门禁、构建、刷机或调参。内核回移仍遵守固定官方来源及目标 OTA 兼容性要求。

| 项目 | Luna 已具备什么 | Hanamaki 增量 | 合理性与当前价值 |
| --- | --- | --- | --- |
| 03 kreclaimd | 每节点 kswapd、并发直接/memcg 回收、异步 I/O、stock ZRAM | kswapd 将 WRITEPAGE / MEMCOMPRESS 分派给多 worker，带队列和背压 | 单线程压缩瓶颈下有价值；排除 04 后只保留传统 WRITEPAGE 研究，不能直接摘二进制实现 |
| 06 THP/mTHP | 4 KiB 基础页上的多尺寸匿名大页；默认主要按 madvise 使用 | 全局放开多个尺寸、shmem、积极整理/扫描、自定义进程开关 | 小尺寸可降低缺页开销；优先单尺寸实验，整组激进策略不合适 |
| 07 MGLRU TTL | MGLRU、主动回收官方修复；TTL 源码默认 0 | 尝试设为 1000 ms | 抗颠簸有机制支持；可能更早内核 OOM，不能直接等同保后台 |
| 08 VM 参数 | 完整原生 sysctl、WBT 与既有回收/块层修复 | 高水位、低 swappiness、零预读、较低脏页比例等 | 应逐项拆开；水位与预读最值得先看，其他多为条件性取舍或默认值 |
| 09 调频余量 | schedutil 的约 25% 余量；stock WALT 有独立映射 | handler 试图降到约 10%，加 1 GHz 下界 | 正常 QCOM 不注册此 hook，WALT 也不走它；MTK 注册后又被静态键挡住，本包优先级很低 |
| 10 MPAM/SLC | stock 已有 CPU MPAM、SLC、平台带宽控制模块和 DT 节点 | 改 CPU L2 分配及其 SLC partition 映射、apps/GPU SLC gear | 目标路径真实存在；适合场景化分配研究，不能把全局放宽配额当确定收益 |

## 2. 03：kreclaimd 的价值是分担压缩换页，不是“Linux 由串行变并行”

Luna `NUMA=n`，通常只有一个内存节点的 kswapd，但分配线程的直接回收、memcg 回收、文件 flusher 与块 I/O 本来就能并发。Hanamaki 的增量是：**把 kswapd 自己要做的一部分工作继续交给其他 CPU**，让它更快返回扫描/回收循环。

这对手机有一个具体合理场景。r21 ZRAM 声明同步块设备特性，swap 写出可进入 `submit_bio_wait`，压缩使用 per-CPU 流。若单个 kswapd 的大量时间耗在压缩执行，其他 CPU 有余量，跨核 WRITEPAGE 分派可能加快回收进展，减少分配者跌入直接回收的机会。若主要瓶颈是 UFS I/O、锁竞争或系统所有核都很忙，再加线程可能只增加竞争。实际使用的 stock ZRAM 模块仍需用调用栈/计数确认这一瓶颈。[固定 r21 换页代码](../sources/aosp_common_6.12.81_kmi6_r21/mm/page_io.c)、[ZRAM 代码](../sources/aosp_common_6.12.81_kmi6_r21/drivers/block/zram/zram_drv.c)

已恢复的实现并非无限制排队：

| 环节 | 二进制中确认的行为 | 工程含义 |
| --- | --- | --- |
| 入队资格 | 检查 `PF_KSWAPD`；普通直接回收不能直接走此入口 | 主要改善后台回收，不能声称把所有直接回收都异步化 |
| 队列 | 1024 项，每项 16 字节，含 folio 和类型；队列满可返回失败 | 必须保留失败回退和引用释放 |
| 并发 | 启动在线核数为 n 时，总 worker 数约为 `max(n,2)-1`；n≥3 时含一个 burst worker | 启动时若 8 核在线，则 6 普通＋1 burst；并非已证明的最佳并发度 |
| 批量与背压 | 每批最多 8 项；槽数达到 512 请求 burst，达到 768 节流 kswapd；每次等待最长 1 jiffy，HZ250 时约 4 ms | 有明确反馈设计，但阈值是否适合 pudding 未知 |
| WRITEPAGE | 取得 mapping，构造回收写出上下文，执行 `writepage`，处理重脏、错误、解锁和引用 | 对传统 swap/ZRAM 有独立机制意义；写出完成不等于页已经释放 |
| MEMCOMPRESS | 与专用压缩队列、inflight、完成计数及 `nr_reclaimed` 反馈相连 | 这部分属于用户暂不考虑的 04，不能随 03 一起引入 |
| 停止/冻结 | 等待会检查停止、冻结和水位；停止后排空队列并释放上下文 | 仍需源码证明 swapoff、mapping 消亡、错误路径和锁顺序正确 |

**排除 04 后，03 仍可保留为“kswapd 的传统 WRITEPAGE 分派”研究方向。** 两种工作在运行分支上可区分，但当前未取得源码证明编译依赖可拆，也不能把专用压缩的完成计数照用于传统写出。Luna 可以继续保留原有 stock ZRAM/provider，不必为这个概念引入新压缩池或改 PTE。

当前尚未绑定能进入项目清单的稳定 AOSP/Linux 官方提交。下一步最有价值的证据是同负载下 kswapd CPU 与压缩函数占比、直接回收尾延迟、PSI、pgscan/pgsteal、refault 和帧时；只有先证明瓶颈确在单 kswapd 的 CPU 工作，才知道额外并发是否对症。这是研究优先级判断，不是因缺实测否定机制。

## 3. 06：Luna 已有 mTHP，重点是启用范围与分配延迟

4 KiB 是基础页大小；在其上使用 16/32/64 KiB 等 mTHP 不改变项目 4 KiB 构建身份。小尺寸主要通过较大 folio/PTE 映射减少缺页与分配操作，不能保证获得 2 MiB PMD 块映射同等的 TLB 收益。固定 6.12 的 khugepaged 仍主要做 PMD 合并，不应把最新版文档中的后续 mTHP 合并能力倒推过来。[固定大页定义](../sources/aosp_common_6.12.81_kmi6_r21/include/linux/huge_mm.h)、[Linux THP 机制说明](https://docs.kernel.org/admin-guide/mm/transhuge.html)

| 参数 | Luna 固定源码默认 | Hanamaki 尝试设置 |
| --- | --- | --- |
| 匿名页全局策略 | `madvise` | RAM 至少 10 GiB 时 `always`，否则 `madvise` |
| 每尺寸匿名页 | PMD/2 MiB 为 `inherit`，其他为 `never` | 16–2048 KiB 所列尺寸全部 `inherit` |
| shmem 全局/尺寸 | 全局 `never`；PMD `inherit`，其他 `never` | 全局 `within_size`，所列尺寸全部 `inherit` |
| fault defrag | `madvise` | `always` |
| khugepaged 扫描间隔 | 10000 ms | 启动阶段先 100，等待启动后改 0，满足扫描轮次后改 6000 |
| 分配失败休眠 | 60000 ms | 100 ms |
| 单轮扫描量 | 4096 页，即 16 MiB 地址扫描量 | 65536 页，即 256 MiB 地址扫描量；不是额外固定占用 256 MiB RAM |
| `max_ptes_none` | 511 | 8，更少容忍未分配页，限制部分驻留膨胀 |
| `max_ptes_shared` | 256 | 511，允许更多共享页参与合并，可能增加写时复制成本 |
| `use_zero_page` / khugepaged defrag / `max_ptes_swap` | 1 / 1 / 64 | 相同，不能算新优化 |

脚本是在多个方向同时取舍：较少空页合并相对保守，全局 `always`、fault 整理和几乎不休眠的启动扫描则很积极。它可能减少后续缺页，也可能在分配/启动时增加整理、清零、CPU 占用与尾延迟。shmem 的 `within_size` 是单独的策略，不受匿名页 `madvise` 自动约束，普通 tmpfs mount 也要核对自己的 huge 策略。[固定 khugepaged](../sources/aosp_common_6.12.81_kmi6_r21/mm/khugepaged.c)、[固定 shmem](../sources/aosp_common_6.12.81_kmi6_r21/mm/shmem.c)

一个重要纠正：`set_task_thp` 解析 PID 和整数，**0 设置 `MMF_DISABLE_THP`，非 0 清除此位**。脚本给 HWC PID 写入 0，实际是在禁用硬件合成进程的大页，不能说是在给 HWC 启用大页。清除禁用位也不等于给 VMA 标记 `MADV_HUGEPAGE`。Luna 原生 `prctl(PR_SET_THP_DISABLE)` 是进程自己调用的接口，没有同样的外部 PID sysfs。该自定义函数未见正常 task/mm 引用获取与 NULL-mm 检查，不能照搬其生命周期处理。

**建议先试单个 16/32/64 KiB 匿名页尺寸，其他参数不动。** 若应用确有 `MADV_HUGEPAGE` 区域，可在 `madvise` 下比较；否则需要受控负载，或明确试验单个尺寸的全局 `always`，不能把后者称为按进程定向。即使有 madvise，保留 PMD 策略时也可能优先分配 2 MiB；必须确认目标尺寸的 `anon_fault_alloc` 确实增加，或使用无法容纳完整 2 MiB、但满足目标小尺寸对齐的受控 VMA，避免无实际差异的 A/B。重启目标应用，观察每尺寸分配/fallback/split、缺页尾延迟、RSS/PSS、swap、PSI、帧时和能耗，再单独决定是否研究 shmem 或 2 MiB 合并。

## 4. 07：MGLRU TTL 用更早 OOM 换取减少颠簸

Luna 已有 MGLRU，且主动回收到量停止和 freezer 响应已有官方修复，不必重复回移。`min_ttl_ms` 源码初值是 0；Hanamaki 尝试设为 1000，同时写 `enabled=Y`，后者还会重设功能位。

TTL 的作用不是“每个应用的每一页至少存活一秒”。固定 r21 依据代的出生时间判断可回收工作集：kswapd 找不到足够老、规模合适且未受 memory.min 保护的可回收 lruvec，TTL 非零且能取得 OOM 锁时，可主动走**内核 OOM**。所有代太年轻是典型场景，小 memcg/保护条件也会影响结果。它并非对所有直接回收或 `memory.reclaim` 建立逐页免驱逐承诺。[固定 vmscan](../sources/aosp_common_6.12.81_kmi6_r21/mm/vmscan.c)、[MGLRU 官方说明](https://docs.kernel.org/admin-guide/mm/multigen_lru.html)

机制本身合理：工作集装不下时，继续回收又重新缺页会持续拖慢前台；较早杀掉一个进程可能比全系统颠簸代价小。但 Android LMKD 已利用 PSI、refault/换页等信号做压力处理，TTL 与 LMKD 是两条路径，不能假设一定由 LMKD 先杀，也不能用“缓存应用更多”证明更好。[AOSP LMKD 说明](https://source.android.com/docs/core/perf/lmkd)

**价值中等、适合独立试验。** 先保持 LMKD、MGLRU enabled 位、水位、swappiness 和 THP 不变，对照实际基线与 1000 ms；250/500 ms 可作为探索中间档，均非已证最优值。分别统计内核 oom_kill、LMKD 原因、应用重载/冷启动、PSI、refault 和帧时。若颠簸下降但应用明显更早被杀，应明确记录这笔代价，不能包装成保后台优化。

## 5. 08：参数要拆开，源码默认不能代替手机实值

| 参数 | Luna 源码初值/机制 | Hanamaki 值 | 合理性与代价 |
| --- | --- | --- | --- |
| `watermark_scale_factor` | 10 | 200 | 提前唤醒/延长后台回收，可能降低 allocstall；提高空闲目标，减少可用文件缓存 |
| `min_free_kbytes` | 按低端内存量计算，THP/vendor 还可能调整 | 65536，即 64 MiB | 不是简单的 1024→65536；可能升也可能降，必须先采样 |
| `page-cluster` | 大内存设备一般 3，预读路径窗口上限 `2^3` 基础页 | 0，关闭该路径的额外预读 | 随机回读可能减少无用解压；顺序回读可能增加缺页。实际预读有自适应，且同步 swap 快路可绕过此参数 |
| `swappiness` | 60；cgroup v1 可有自己的值，v2 使用全局 | 1，Image hook 还强制使用全局值 | 偏向回收文件页；可能保护匿名页，也可能增加文件 refault。压缩 swap 未必应尽量少用 |
| `dirty_background_ratio` / `dirty_ratio` | 10 / 20 | 2 / 5 | 按 dirtyable memory 计算；更早写回/节流或降低峰值，也可能损失写合并、增加唤醒和前台等待 |
| `overcommit_memory` | 0，启发式许可 | 1，总是允许过量承诺 | 不增加物理内存，可能把分配失败推迟到 OOM；没有一般性能收益保证 |
| `dirtytime_expire_seconds` | 43200 秒 | 60 秒 | 管 lazytime inode 时间戳，不是普通脏数据期限；可能增加元数据 I/O，优先级低 |
| `compaction_proactiveness` / `watermark_boost_factor` | 20 / 15000 | 相同 | 未证实相对实际系统有变化，不能计作新优化 |

水位公式值得明确。以普通非 MOVABLE lowmem zone 为例，不含 boost 和 vendor hook 二次调整，`D=max(min/4, managed_pages×factor/10000)`，`low=min+D`，`high=min+2D`。所以 200 是约 **2% 的水位间距**，high 相对 min 可增加约 4%，不是总共只保留 2%。假设 managed memory 为 12 GiB、min 为 64 MiB，factor 从 10 到 200 时，high 可由 96 MiB 变到约 555.5 MiB，增加约 459.5 MiB。**这只是公式示例，不是 pudding 测量结果**；实际有多个 zone、可管理页数、动态 boost 及其他设置。[固定 page_alloc](../sources/aosp_common_6.12.81_kmi6_r21/mm/page_alloc.c)、[官方 VM 参数说明](https://docs.kernel.org/admin-guide/sysctl/vm.html)

这一组并非必然互补：高水位提前回收，swappiness=1 又偏向文件页，再叠加 THP 和 TTL，可能让文件 refault 或杀进程更早出现。Hanamaki 的低 swappiness 还处在 memcompress 替代路径中，不能把值原样搬到 Luna stock ZRAM 后认为行为等价。

**建议先看水位，再独立看预读。** 若实际 baseline 有明显 allocstall/kswapd 来不及，水位可逐档提高；若已有充足空闲和很低 stall，提高水位针对性就弱。page-cluster=0 应比较随机应用切换与顺序回读；但固定 r21 对同步 swap、单引用页可走 `alloc_swap_folio → swap_read_folio`，绕过 `swapin_readahead`，还可读大 folio，故不能说全系统每次只读 4 KiB，对此类 ZRAM 快路收益可能有限。[固定缺页路径](../sources/aosp_common_6.12.81_kmi6_r21/mm/memory.c) 脏页比例单独对照写延迟、UFS I/O、能耗与 PSI，保留 Luna WBT。`overcommit=1` 和一分钟 dirtytime 暂无足够通用价值。

## 6. 09：余量调低的思路成立，但本包正常路径不支持“已经生效”

Luna schedutil 先以 `map_util_perf(actual)=actual+actual/4` 加约 25% 余量，再与 min/max 约束合成并计算频率。Hanamaki handler 对包含 CPU0 的 policy 重算输入，另设 1 GHz 下界。默认 margin=10，忽略整数截断/约束时请求比例约为 `1.10/1.25=0.88`，可近似理解为 25%→10% 的余量；但输入被 min/max、uclamp、boost 改变时就不是单纯替换余量。这是约 12% 的请求差异，**不是 12% 的功耗收益**；OPP 离散化、QoS 和负载饱和也会改变结果。低负载的 1 GHz 下界还可能增加功耗。[固定 schedutil](../sources/aosp_common_6.12.81_kmi6_r21/kernel/sched/cpufreq_schedutil.c)

进一步恢复初始化和静态键后，本项应下调评价：

1. `init_mtk` 注册 `android_vh_map_util_freq`，`init_qcom` 没有对应注册。配套脚本在 QCOM 请求 WALT。
2. 固定小米 WALT 的 `walt_map_util_freq` 有独立余量/分段计算，正常调用路径没有这个 schedutil hook；不能把 schedutil 参数作用自动外推到 WALT。[固定小米 WALT](../sources/xiaomi_sm8850_soc/kernel/sched/walt/cpufreq_walt.c)
3. MTK 初始化在注册后启用 `IS_MTK`。Image 跳转表记录 `code=0x8f60fc`、`target=0x8f610c`、key 的 branch 位为 1；按 jump-label 的 `enabled XOR branch` 规则，启用后该点是 NOP，落入 `0x8f6100` 的直接返回路径。这一机器码/静态键结论已独立交叉核对。

因此正常 QCOM 缺少注册，正常 MTK 启用后又被门控挡住；只剩注册到启用之间的短窗口或未来其他代码改键值等未证实条件。原始未打补丁指令看起来会跳入主体，不能据此忽略启动后的静态键改写。

**本包的 09 不值得直接仿制。** 若未来要研究较低调频余量，应先读真机 `scaling_governor` 与实际 WALT/schedutil 参数，针对正在运行的调频器设计，比较突发响应、帧时、频率驻留和能耗。Luna 的编译默认 governor 也不能代替设备运行状态；CPU0 集群不应简单称为传统“小核”。

## 7. 10：MPAM/SLC 是目标 OTA 已有能力，新增的是分配策略

本轮在固定 vendor_boot/vendor_dlkm 找到 `mpam`、`cpu_mpam`、`slc_mpam`、`platform_mpam`、`mpam_msc`、`mpam_msc_slc` 模块，设备树也有对应节点。因此它不再只是脚本中的 SM8850 名称线索。Luna 的 Image-only 路径会继续使用这些 stock 消费者；不是要往 common 新移植一套硬件驱动。

固定 OTA 的 12 个 FDT 在相关节点上均显示：CPU MPAM 的 MSC 是 **L2_0、L2_1**；SLC client 包含 apps/GPU/NSP，apps 声明 partition 0/1/2；另一路 NOC 带宽控制有 low/medium/high/veryhigh，对应 ID 1/2/3/4。后者不能拿来解释 SLC 的 `gear=0`。SLC 驱动实际依据固件 `num_part_id` 创建 configfs 节点，没有用这些 DT part-id 声明决定数量，所以不能据 DT 断言运行时恰有三个 apps 分区。尚未用运行后合成设备树确认具体板级选择及固件版本。

| 脚本动作 | 固定小米驱动解释 | 关键限制 |
| --- | --- | --- |
| apps 下所有 schemata 写 `gear=0`，GPU 同样写 0 | SLC partition 请求；v0 协议枚举的 0 是 HIGH | v1 有不同映射，应查询实际固件和可用 gear；不能当作无条件全缓存独占 |
| default 写 `cmax=100,cpbm=0xfff` | CPU MSC 的 capacity 和允许 way mask；未指定 MSC 时应用所有 CPU MSC，固定 DT 对应两个 L2 | 不是直接把所有 SLC 分给 CPU；驱动成功映射 `mon-base` 后已将 capacity 设为 100，因此此字段未必有变化 |
| `prio=99` | 设置 `dspri` 字段 | 仅凭数字不能证明最高优先级、合法范围或固件实际接受 |
| `slc_partid=1` | CPU partition 到 SLC partition 的映射 | 改的是流量归属；需要对应 client/partition 策略共同成立 |

`cpu_mpam` 初始查询固件，成功映射 `mon-base` 时再强制设 capacity=100、dspri=0；固定 DT 含此资源，cpbm/slc_partid 仍需核对查询结果。它用逗号解析一组字段、分号分开多轮更新；该字符串产生三轮更新，每轮分别提交两个 L2 MSC，正常解析时共六次底层设置，并非一个原子事务，未指定字段沿用已存值。底层设置失败时 CPU 接口仍可能返回写入长度，另有 `mask_val` 覆盖风险，因此 shell 返回成功或节点显示新字符串均不足以证明生效。[固定 CPU MPAM 实现](../sources/xiaomi_sm8850_soc/drivers/soc/qcom/mpam/cpu_mpam.c)、[SLC 实现](../sources/xiaomi_sm8850_soc/drivers/soc/qcom/mpam/slc_mpam.c)、[SLC 协议定义](../sources/xiaomi_sm8850_soc/include/soc/qcom/mpam_slc.h)

**机制价值中等偏高，实施形态更适合未来配套模块。** 缓存分区可减少竞争、保护关键工作集；把所有 apps partition 与 GPU 同时改为某个 gear 未必形成有效隔离，还可能挤压其他客户端或增加互相竞争，也可能与原值相同。合理方向是读取真实 schemata/可用 gear/监控能力，针对已确认受缓存竞争影响的游戏进程或单 client 临时调整，退出场景恢复。比较 cache miss、带宽、CPU/GPU stall、帧时与能耗，并覆盖相机、音视频和后台服务同时工作的情况；不能只看瞬时跑分。

## 8. stock 模块、防护/诊断和 Binder 专项

### 8.1 黑名单移除了哪些实际功能

`load_module` 把 `load_info.sig_ok` 传给自定义 `module_is_blocked`。验签成功则豁免，否则精确匹配 50 个内部模块名，命中后返回 `-EPERM`。本轮与固定 OTA 全量交叉，**41 个名字实际存在，9 个不存在；其中 22 个不同 vendor 模块无签名，且都出现在至少一份正常启动 modules.load**。另外 19 个 system 测试类名字有签名、不在正常 system modules.load。zram/zsmalloc 同时有 vendor 无签名版与 system 有签名版。

“文件带签名”不等于 Hanamaki 的 `sig_ok=true`，离线没有完成它的信任链验证；因此不能说 system 版本必定豁免，也不能说 50 个模块都在小米 17 上被禁。对匹配的无签名 vendor 版本，已恢复的正常加载路径会拒绝。固定镜像的提取与清单数量亦吻合：vendor_boot 466、vendor_dlkm 404、system_dlkm 103 个模块，分区间存在重复，不相加当独立模块数。

| 实际命中类别 | 可能得到的收益 | 移除的行为与价值判断 |
| --- | --- | --- |
| `mi_trace`、`mi_stack`、`mi_ubt`、`mi_memcheck`、日志/测试类 | 已启用采样、回溯、日志和模块驻留开销 | 只有确实在采样才有持续收益；失去 OEM 诊断。未加载的 KUnit 模块几乎没有运行收益可省 |
| `mi_damon`、`kshrink_slabd`、`scene_swappiness`、`unfairmem` | 扫描/回收及策略钩子的 CPU 开销 | 也失去 OEM 回收/场景策略；可能减轻重复扫描，也可能加重直接回收与文件 refault，需逐模块取证 |
| `cpq`、`perf_helper`、`mi_wq_dynamic_priority`、`mi_proc_exit`、`powersave` | OEM I/O、调度和任务策略开销 | `cpq` 的 ELF 描述确认是 CPQ I/O scheduler；不能当作普通遥测模块。策略退出后的回退行为和净收益未知 |
| `cpu_hotplug`、`thermal_pause`、`thermal_config` | 减少相关控制工作，或降低温控策略施加的限制 | 前两者固定源码属于 thermal cooling 路径；解除降载可能增加短时吞吐，同时增加功耗/温升，不等于持续效率更高 |
| `cameramsger`、`mibbr` | 相机事务/网络扩展钩子开销 | 属于功能/策略模块；移除后必须验证相机服务与网络行为，不能统一归为诊断裁剪 |
| vendor `zram` / `zsmalloc` | 避免加载原 provider，为替代内存实现让路 | 不是简单关闭无用组件。system 版本可能仍被加载，其他模块还有 zsmalloc 依赖；要证明 built-in/provider 替代关系 |

完整 22 名还包括 `f_fs_ipc_log`、`mi_ubt_test`，明细见[逐模块交叉表](../tmp/hanamaki-analysis/blacklist-stock-matches.tsv)。黑名单里的 `qcom_cpufreq_thermal` 不在本 OTA，而真实的 `qti_cpufreq_cdev`、`qcom_tsens`、`qti_thermal_vendor_hooks` 等仍在，所以不能称为移除全部温控。

Image 另有 `freq_qos_update_request` 筛选：部分 thermal/mtkpower 进程上下文命中后直接返回成功，旧请求不更新。来源关键词匹配部分使用筛选器自身返回地址，未正确使用外层传入地址，不能据此宣称所有温控 QoS 都被阻止；旧限制也不因返回成功自动消失。配套用户态还尝试停止温控服务和改 trip point，属于另一层动作。

**这里最值得学习的是识别重复策略和真实开销，不能直接复制黑名单。** 诊断模块若有受支持的低开销运行模式，可在不卸载消费者的前提下研究；回收/调度策略应逐个确认工作量与替代关系。当前整表把测试、相机、温控、I/O、swap 混在一起，已经改变 stock 正常加载和功能契约，不满足 Luna 现有发布要求。

### 8.2 防护/诊断裁剪：哪些真能省工作，哪些只是改变故障处理

两者都启用 `CMDLINE_EXTEND`。以下结合 Hanamaki 编译配置、内置 cmdline、可见解析器和固定上游实现；最终启动参数、硬件能力及运行时覆写仍需真机确认。没有把“配置保留”当作“运行时一定启用”，也没有把“参数存在”当作“所有硬件上都生效”。

| Hanamaki 相对 Luna 的差异 | 实际动作及可能收益 | 代价与边界 |
| --- | --- | --- |
| `nokaslr`、`norandmaps` | 分别关闭内核布局随机化、把用户地址随机化默认设 0 | 主要改地址布局，缺少显著持续热路径收益；用户 ASLR 后续仍可由 sysctl 改变 |
| `kpti=0`、`mitigations=off` | 若本来启用，可减少页表隔离、受硬件/固件条件控制的部分推测执行缓解工作 | 对本来无需相关缓解的 CPU 不会得到同样收益；不能理解为关闭一切保护 |
| `hardened_usercopy=off` | late init 静态键绕过对象边界加固检查，确实减少检查路径工作 | 失去这类越界检测；普通访问范围检查并非全被移除 |
| `audit=0` | 禁用内核 audit 初始化和记录，相关实现提示直到重启保持禁用 | 可减少已产生的审计工作，损失安全审计；SELinux 访问拒绝本身不等于被关闭 |
| `kasan=off`、`arm64.nomte` | 前者跳过 HW_TAGS KASAN 初始化，后者屏蔽 MTE 能力 | 两者收益重叠；无 MTE 硬件时原本就没有该运行成本。nomte 还影响用户态能力；Luna 的 `kasan.stacktrace=off` 仅关栈记录 |
| `arm64.nobti` | 屏蔽 BTI 能力 | 两者 `ARM64_BTI_KERNEL=n`，不能声称省了内核 BTI；主要影响支持该功能的用户态映射 |
| KFENCE interval 500→0 | 保留编译能力，默认停止采样，可运行时再开启 | 少量采样开销与低频内存错误捕获能力的取舍；500 ms 不是每半秒全量扫描内存 |
| hardlockup detector 关闭 | 移除 Luna 的 buddy 硬锁死检测 | 可减少 watchdog 工作，失去相应定位能力；softlockup、hung task、WQ watchdog 仍保留 |
| DPM watchdog 编译关闭 | 移除可按需开启的驱动 suspend/resume 回调超时监测；Luna 虽编译但 `DPM_WATCHDOG_ENABLED=n`，默认未启用 | 默认状态主要减少少量代码与分支，代价是失去按需开启的转换卡死诊断，不是普遍 CPU 热路径优化 |
| panic-on-oops 默认关闭 | Oops 后默认不立即 panic，仍报告 Oops | 正常运行几乎无收益；带故障继续运行不等于更稳定，运行 sysctl 也可改变此策略 |
| `BPF_UNPRIV_DEFAULT_OFF=n` | 默认允许非特权 BPF 的配置取舍 | 不会自动加速已有特权 BPF 工作，扩大可访问面；与 Luna 固定要求冲突 |
| `BLK_WBT_MQ=n` | 少了 WBT 写回节流路径 | 可能提高某些吞吐，也可能恶化前台读/交互尾延迟；Luna 必须保留此项 |

这类差异中，**运行中有效的 usercopy 检查、审计、标签检测和硬件确需的隔离/缓解**最有明确省工作的机制；关闭地址随机化、Oops 后 panic 则很难形成有意义的持续性能收益。没有因涉及保护就停止分析，但也不能拿理论上的少执行指令替代目标设备净收益和语义成本评估。[固定 usercopy](../sources/aosp_common_6.12.81_kmi6_r21/mm/usercopy.c)、[arm64 CPU 特性处理](../sources/aosp_common_6.12.81_kmi6_r21/arch/arm64/kernel/cpufeature.c)

不要重复计算共同项：两者都有 `stack_depot_disable=on` 和 `cgroup_disable=pressure`，后者仅针对 cgroup pressure，不代表没有全局 PSI；PAGE_OWNER 虽编译但默认关闭，SLUB_DEBUG 编译但非默认全开，内存分配 profiling 也默认关闭。BTF/DWARF 的存在不是每次调度都在采样。

Hanamaki 仍保留 CFI、SELinux、seccomp、FORTIFY、stack protector、PAC kernel、slab freelist 加固、INIT_ON_ALLOC、pstore 等。不能概括为“全关安全所以快”，也不能用关掉诊断后的安静日志作为稳定性证据。

### 8.3 实际换成 Rust Binder：有结构性价值，但 OEM 钩子存在具体缺口

Hanamaki 为 `ANDROID_BINDER_IPC=n`、`ANDROID_BINDER_IPC_RUST=y`，Image 有真实 Rust Binder 初始化、事务/线程/进程路径，属于实际实现替换。Luna 是 C Binder built-in，Rust 为模块且固定启动输入没有选择它。r21 在 C=n 时 Rust 直接注册，还自带 `rust_binderfs.o`，所以缺少单独 `CONFIG_ANDROID_BINDERFS` 不能证明没有 BinderFS。[固定 Binder 构建与实现](../sources/aosp_common_6.12.81_kmi6_r21/drivers/android/binder)

Rust 的明确价值是利用所有权、生命周期和安全抽象减少某些内存错误；unsafe、C 边界、锁顺序和协议逻辑仍需审查。两种实现都支持 Binder UAPI、LSM、优先级继承、冻结/通知等，不能因语言变化就预设不兼容，也不能由语言推断性能必然改善。[Rust for Linux Binder 项目说明](https://rust-for-linux.com/android-binder-driver)

性能应比较当前具体实现。Rust 使用 per-VMA lock 可减少 mmap 锁争用，但 **Luna 当前 C Binder 同样已有 `lock_vma_under_rcu` 及 mmap fallback**，不是切换 Rust 才获得。[AOSP per-VMA 支持提交](https://android.googlesource.com/kernel/common/+/0c50773076035e84669f0f6d4414ca267248e74b)、[当前 C Binder 分配器](../sources/aosp_common_6.12.81_kmi6_r21/drivers/android/binder_alloc.c) 仍应比较 IPC 吞吐/尾延迟、同步唤醒、分配回收争用、内存压力与真实服务行为，而非用早期 C 实现代表 Luna。

本轮找到比“ABI 可能不兼容”更具体的证据：固定 OTA 模块消费了 **13 类 C Binder vendor tracepoint**。

| stock 消费者 | 消费的 C Binder 事件，省略公共前缀 |
| --- | --- |
| `binder_gki` | alloc_new_buf_locked、reply、trans、wait_for_work、preset |
| `os_cpu_qi` | transaction_init、set_priority、restore_priority、proc_transaction、free_oem_binder_struct、buffer_release |
| `os_cpu_qs` / `sched_walt` | preset / set_priority、restore_priority |
| `mi_kernel_monitor` / `dump_binder` | transaction_received / proc_transaction_finish |
| `cameramsger` | proc_transaction、transaction_received；此模块还在黑名单中 |

Hanamaki 保留了这些 C tracepoint/traceiter 导出，但完整 `__jump_table` 未找到 C Binder vendor hook 分支站点，常规 `.text` 的直接 B/BL 扫描也没有对应 traceiter 调用；Rust 的 set_priority、restore_priority、looper_entry 则有三类、五个实际分支站点。**在已识别的正常 Rust Binder 路径中，没有找到这些 C 事件的等效转发。**

静态扫描不能穷尽任意间接调用、外部模块主动触发或运行时热补丁；imports 也不能还原每个回调的完整业务语义。但当前证据已说明：保留导出乃至 CRC 一致，仍可能失去 OEM 调度/任务策略、冻结协同、事务监测、相机消息等事件行为。首轮确认的 4083 个依赖名字覆盖，不能填补这一语义缺口。[逐消费者表](../tmp/hanamaki-analysis/stock-binder-consumers.tsv)、[静态分支证据](../tmp/hanamaki-analysis/binder-static-branches.txt)

**Rust Binder 值得单独的兼容性专项，当前 Hanamaki 组合不宜作为直接替换范例。** 必须逐个核对消费者、结构访问、回调时序与替代路径，再验证固定 OTA 全闭包和真实服务。Luna 对未被选择的 stock `rust_binder.ko` 的精确例外，不能用于批准实际选择 Rust 的新路径；如果新方案使用 `.ko`，还必须同次构建、完成依赖与真实加载验证。本轮未作此切换。

## 9. 证据定位与后续决策

忽略目录中保留[03/06/07 逐函数取证](../tmp/hanamaki-analysis/selected-memory-findings.md)、[08/09/10 工作证据](../tmp/hanamaki-analysis/selected-root-findings.md)、[stock/防护/Binder 专项取证](../tmp/hanamaki-analysis/selected-safety-binder-findings.md)、`selected-memory.disasm.txt`、`selected-schedutil-vendor.disasm.txt`、[固定 OTA MPAM 设备树摘录](../tmp/hanamaki-analysis/stock-mpam-dtb.txt)。本报告已纳入独立复核对同步 swap 快路、MPAM 默认值及分区创建方式的修正，工作稿中的早期表述以本报告为准。原包、解包模块和镜像不提交。

当前适合进入下一轮决策的是：06 单个小尺寸匿名页、08 单项水位/预读、07 独立 TTL、10 定向缓存策略；03 继续验证瓶颈与官方实现来源。它们不应一次组合修改，否则无法分离收益、互相作用及回归。每项必须能恢复真实旧值，保留原始诊断及温控条件，并用同应用版本、画质、帧率、环境温度和充电状态比较。**本轮没有实施任何候选，也没有得出真机性能提升结论。**
