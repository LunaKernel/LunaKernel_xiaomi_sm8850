# Hanamaki 26w36e 拆解与 Luna 候选评估

分析日期：2026-09-07。对象为用户提供的 `tmp/Kernel-Hanamaki-6.12-26w36e-021748.zip`。本次仅静态分析，未执行包内程序、安装模块、刷机或回移补丁。

后续已按用户选择完成[03/06/07/08/09/10 与 stock 模块、防护、Binder 深入对比](HANAMAKI-26W36E-SELECTED-ANALYSIS.md)，并形成[独立配套模块分析](HANAMAKI-26W36E-COMPANION-ANALYSIS.md)。本报告保留完整拆解清单，当前不推进 01/02/04/05；新增取证与修正以这两份报告为准。

拆解确认的新增实现包括 **混合链 zsmalloc、ZstdP 页压缩、memcompress/kreclaimd、kFAS 帧反馈调频**。其中压缩和回收改动深入内存管理；游戏性能还混有温控、频率限制和 Android 用户态策略变化。没有该版本源码及同条件实测，不能宣称它比 Luna 更快、更省电或更稳定。

编号见下一表。当前建议优先研究 **06 的单个小尺寸 mTHP、08 的单项水位/预读，再评估 07 TTL**；10 已确认目标 OTA 接口，适合定向缓存策略研究。03 仅继续研究可排除 memcompress 的传统 WRITEPAGE 分派；09 正常路径没有确认的有效调用。尚未从这个包中追溯出可直接加入 Luna 清单的新增官方修复提交；本报告不构成回移或调参授权。

## 1. 决策清单

“已证实”指配置、构件或机器码中的动作；作用是机制分析，收益均未经目标设备验证。“参数实验”使用已有能力，不需要新增内核算法。Luna 现有用户态实际值没有在本次采样，不能保证调参前后一定不同。

| 编号 | Hanamaki 所做的改动 | 简洁作用与潜在价值 | Luna 现状、代价与建议 |
| --- | --- | --- | --- |
| **01** | **zsmalloc 混合 8/16 页链**；配置上限 16，建池先按 8 页选链，仅当结果只能装一个对象时再试 16 页 | 让部分接近一页大小的压缩对象共同占页，减少退化成“一对象一页”的浪费，同时限制普通尺寸类链长；**值得源码审计** | 已有官方可配置链长，当前为 8；**混合算法是额外改动，直接设置 16 不等价**。未取得其官方来源。Luna 的 zsmalloc 为 `.ko`，只改 Image 配置不会改变 stock 模块；改为 built-in 又会改变 provider，须先解决模块闭包及交付边界。不能直接移入当前 Image-only 发布流 |
| **02** | **ZstdP 页压缩及 crypto profile 扩展**；附带 `crypto_zstdp.ko`，新增 page/fast/profile 接口 | 针对换页数据的压缩路径做专门处理，可能改善压缩比与压缩 CPU 开销的平衡；**值得源码审计** | Luna 已有标准 Zstd/LZ4/LZO，ZstdP 不是“打开 Zstd”即可得到。其压缩细节和收益尚未恢复；需固定源码、许可证、官方来源及独立 `.ko` 加载证明，不能复用包中二进制 |
| **03** | **kreclaimd 并行回收工作队列**，含普通页写出和 memcompress 两类工作、完成反馈及节流 | 将部分回收工作分派给后台工作线程，可能缩短分配路径同步等待；**机制有价值，风险较高** | Luna 没有该自定义体系。它与扫描、压缩、反馈及背压相互依赖，不能只摘一个线程函数。先取得源码理解机制；进入当前回移清单仍须绑定稳定 AOSP/Linux 官方实现，并验证低内存、冻结/退出、休眠和并发回收语义 |
| **04** | **memcompress 压缩内存体系**：直接回收接入、PTE/folio 装载、压缩池、批量 swap、写回、整理与 swapoff | 在内存压力下压缩冷页，尝试减少物理内存占用和前台等待；**潜力较大，移植成本最高** | 不是普通 ZRAM 参数。`ZRAM=n`、`MEMCOMPRESS=y`，另有模块拦截；会改变原有换页与模块路径。缺源码、压力/损坏恢复证据和完整 ABI 审计，建议保留为研究方向，不进入当前回移批次 |
| **05** | **kFAS + CPU 压力/掉帧监控 + GUI 帧事件**，根据帧目标调用 QCOM/MTK 调频路径 | 让性能供给跟随帧需求，可能降低掉帧或减少不必要的高频；**值得机制审计** | 需内核实现与 Joyose/用户态事件共同工作，不能把 `perfmgr.ko` 当算法。包中同时解除多项性能/温控限制，无法分离算法收益。源码未匹配；即使研究该机制，也须保留目标设备安全及 vendor 协作语义 |
| **06** | **THP/mTHP 与按进程 THP 入口**；模块对大内存机器全局启用 THP、多尺寸继承、积极整理 | 较大的匿名页可减少缺页和 TLB 开销；**适合先研究定向、小尺寸实验** | GKI/Luna 已有 THP/mTHP；全局默认 `madvise`，PMD 尺寸继承，其他 mTHP 尺寸默认 `never`，实际值需采样。无需为了此能力回移算法。包内 `defrag=always`、启动阶段 `scan_sleep=0` 不建议照搬；基础页仍保持 4 KiB |
| **07** | **MGLRU 工作集保护 `min_ttl_ms=1000`** | 尽量保留最近 1 秒工作集，减轻反复回收/重新缺页造成的卡顿；**适合独立参数实验** | Luna 已有 MGLRU 及主动回收修复。只需评估已有接口；内存无法容纳受保护工作集时可能更早 OOM。须观察 LMKD、应用重启和卡顿，不能只看缓存应用数量 |
| **08** | **回收水位、换页和写回参数**，包括 `watermark_scale_factor=200`、`page-cluster=0`、`swappiness=1` | 提前启动后台回收、减少 swap 预读或改变匿名/文件页回收比例；**部分参数可单项研究** | 全部是现有接口，部分值本来就是默认。高水位占用可用内存；低 swappiness 未必适合 ZRAM。建议先确认 stock 实值，只挑水位/预读独立比较，不复制整组 |
| **09** | **schedutil 调频余量修正主体**，`schedutil_little_margin` 默认 10 | 公式试图把通常的 25% 余量调至约 10%，同时保留 1 GHz 下界；**优先级低** | 后续确认正常 QCOM 不注册该 hook，WALT 不走此路径；MTK 注册后又被 IS_MTK 静态键挡住。不能把公式存在当作本包正常路径已生效，详见后续报告 |
| **10** | **SM8850 MPAM/SLC 参数**，更改 apps/gpu gear、CPU 缓存配额与 SLC 分区映射 | 缓存竞争管理有合理价值，适合定向场景研究 | 后续已确认固定 OTA 的模块与 DT 接口；CPU MSC 对应 L2_0/L2_1，SLC 是另一路 client/partition 设置。固件接受情况和实际收益仍未验证，应在配套策略层研究 |

01 与 02 是不同方向；03 与 04 在本包中紧密协作。06–08 是运行时策略，不能将其数量计作“新增官方回移补丁”。本包的 THP/MGLRU/VM 参数初始化受 `service.sh:305` 检出 `pandora_config/enable_mm_vhs` 节点的条件控制，写入效果未验证。当前直接内核回移仍只接受稳定 AOSP/Linux 官方来源；可审计第三方源码可用于理解机制，不自动获得准入。任何新增 `.ko` 或 provider 改变都必须遵守 [AGENTS.md](../AGENTS.md) 的同次构建、闭包和真机加载要求；本次没有提出或实施放宽这些门禁。

## 2. 取证身份与比较基线

| 对象 | 已核实身份 |
| --- | --- |
| 原始 ZIP | 25,786,199 字节；SHA-256 `0af63f2efcc269134eca148986a19df5827355613a5fb565a5f88054d92acfff`；18 个 ZIP 条目，CRC 测试全部通过 |
| `Image.gz` | 20,779,900 字节；SHA-256 `d55c9368dab25409c83084ac270bea52054e958b090db6618e90137181845560`；gzip 解压校验通过 |
| 解压 `Image` | 46,742,016 字节；SHA-256 `f9ce4918408d961b2afe9937f8c745ec29c02f0d201b5c71a98edb73e3f432a3` |
| 内核 release | `6.12.69-android16-6-4k-Hanamaki-26w36e` |
| 完整 banner 中的构建时间 | `#3 SMP PREEMPT Fri Sep 4 02:19:23 CST 2026`；这是二进制自报时间 |
| 编译器 | Pandora Clang/LLD 21.1.8；LLVM 自报提交 `2078da43e25a4623cab2d0d60decddf709aaea28` |
| IKCONFIG | 8,140 行；SHA-256 `d922931e1617d131522b625d99634da3aac99d256d7f319c782187950764764c` |
| 内嵌 BTF | 8,027,251 字节；194,932 个类型记录、75,930 个 FUNC 记录；SHA-256 `a044bb8530d3ecb847c0e09a32bb1b0266f07e17c6efb7ac3d50360dd47f2443` |
| kallsyms | 166,277 个符号；解码核对全部 650 个压缩名 marker，符号基址 `0xffffffc080000000` |
| 附加模块 | `magisk.zip` 的 id 为 `hanamaki_kernel`，版本 `26w36e` / `260904`；含用户态脚本及 `crypto_zstdp.ko`、`perfmgr.ko` |
| 官方 GKI 参照 | 固定 AOSP r21 `0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28` 的源码与 `gki_defconfig`，用于排除原生能力 |
| Luna 产品配置参照 | `kernel_out/android17-r21/luna-xiaomi17-gd753d8b2-20260901-audit.zip` 的 `image.config.current`；8,236 行、SHA-256 `b35ffd54c23acf009c1819d01614ecc40b53845b1bb3e7b6b7018622e872c935`，与项目参考相符 |
| 本次审阅的 Luna 项目提交 | `1a5a0eb81a1fc77f03d35bae8941f614f53a3b8d`，并检查当前 common 的部分已应用补丁 |

按 Kconfig 键归一化后，Hanamaki 与上述 Luna 产品配置有 **248 项差异**。其中包含 6.12.69 与 6.12.81 的基础版本差异、模块改 built-in、调试/安全取舍及 Luna 独有组件，不能将 248 当作优化项数量。

未取得能和这个 ZIP 精确绑定的 Hanamaki 源码提交及完整补丁清单。公开索引中的旧版 Hanamaki 发布说明不能外推到 26w36e；6.12.69 版本字符串也不足以锁定其具体 AOSP tag。因此本报告是**可见功能、配置、机器码与集成策略的反推清单**，不是完整 Git 差异恢复。函数内部没有新增符号的修改、实际构建参数、运行时 vendor 行为和性能效果仍可能无法从本次证据确定。

Luna 的旧产物仅用于本次配置比较，不据此宣称当前项目提交已完成新构建或真机复测。没有为了分析启动构建流程或读取 `.env`。

## 3. 新增内核机制的具体证据

### 3.1 zsmalloc 混合链确有实现差异

配置为 `ZSMALLOC=y`、`ZSMALLOC_CHAIN_SIZE=16`、`ZSMALLOC_HYBRID_CHAIN=y`。反汇编 `__zs_create_pool` 在 Image 偏移 `0x390410` 以 8 为上限调用 `calculate_zspage_chain`；检查可容纳对象数，等于 1 时在 `0x390430` 改用 16 再算。该路径支持“常规 8、接近 huge class 的对象尝试 16”的判断。

`calculate_zspage_chain` 位于偏移 `0x3912ec`，循环寻找更少尾部浪费的链长。还可见 `zs_pool_get_failure_stats`、`zs_pool` 中的失败统计和 `nonempty_fg` 等额外字段。它们证明分配器有更广的变化，但不能仅凭字段名确认每个快路径都更高效。

固定 r21 的 [mm/Kconfig](../sources/aosp_common_6.12.81_kmi6_r21/mm/Kconfig) 原生支持 4–16，默认 8。官方文档解释了长链减少尺寸类浪费的机制，也说明在内部碎片严重、无法整理释放链时可能增加内存压力；其中合成测试的 4→8 结果不能当作 Luna 8→16 的收益。[Linux zsmalloc 文档](https://docs.kernel.org/mm/zsmalloc.html)

### 3.2 memcompress 与 kreclaimd 是新体系

`MEMCOMPRESS=y`、`KRECLAIMD=y`、`ZPOOL=y`，同时 `ZRAM=n`。恢复出 123 个 `memcompress_` 和 13 个 `kreclaimd_` 文本符号，包含：

- 压缩/缺页：`memcompress_store_after_unmap`、`memcompress_load_folio`、`memcompress_pte_batch`。
- 并行回收：`kreclaimd_queue_work`、`kreclaimd_worker`、`kreclaimd_feedback_collect`、`kreclaimd_throttle`。
- 写回与恢复：`memcompress_swap_batch_flush`、`memcompress_writeback_drain_worker`、`memcompress_swap_defrag_worker`、`memcompress_swapoff`。

BTF 中 `scan_control` 增加了 kreclaimd 完成反馈、等待与 memcompress 直接回收状态；`kreclaimd_work` 携带 folio 及工作类型，枚举区分 `WRITEPAGE` 和 `MEMCOMPRESS`；`kreclaimd_node_ctx` 有 FIFO、inflight、throttle、burst 和 worker 状态。`kreclaimd_queue_work` 的实际机器码调用 `folio_get`、`memcompress_reclaim_queue` 等，支持并行工作的判断。

二进制初始值：`memcompress_auto_enable=1`，`memcompress_capacity_threshold=200`，压缩器字符串 `zstdp`。初始化函数安排 3,750 tick 延迟工作；`HZ=250` 对应 15 秒。自动启用路径还有压缩器是否可用、CPU capacity 差值和 zpool 初始化检查；错误时可失败，不能仅凭初值保证启动后开启或一定使用 ZstdP。

这些变化涉及数据在内存、PTE 与 swap 间的生命周期，性能收益不足以替代正确性证明。固定本地官方 mainline/AOSP 审计仓库的提交标题搜索没有找到同名体系，公开检索也没有取得该版本实现；这只说明本次未建立官方来源绑定，不证明所有外部仓库均不存在源码。

### 3.3 ZstdP 有新增接口与单独模块

附加 `crypto_zstdp.ko` 自报 GPL，并含 Zstd 库版本字符串 `1.5.8`；这不是 `.modinfo` 的模块版本字段，也不足以锁定原始归档或代码提交。模块含 `zstd_compress_cctx_page`、`zstd_compress_cctx_page_fast`、`zstd_set_page`、`zstdp_profile`，并依赖 `crypto_comp_register_profile` / `crypto_comp_unregister_profile`。

Image 则导出上述 profile 注册接口，并在 memcompress 初始化时调用 `crypto_comp_set_page`、`crypto_comp_has_fast`。可以确认存在专用页压缩接口及快路径选择；不能确认压缩算法内部修改及性能幅度。

模块 `service.sh:247–263` 的备用 ZRAM 配置只在 `/proc/swaps` 没有 ZRAM 时尝试使用 `zstdp`，不能据脚本断言每台设备都会切换。`post-fs-data.sh:8` 还尝试加载包中不存在的 `crypto_lz4p.ko`。这不证明 Image 没有标准 LZ4，配置中标准 LZ4 仍然存在。

### 3.4 帧反馈与 vendor 协作

Image 中有 `pdr_cpu_util_report_frame`、`pdr_cpu_util_report_sf_drop`、`pdr_cpu_util_get_pressure`、`gui_frame_handler`、`kfas_get_tfps`、`do_freq_tune_qti` 和 `do_freq_tune_mtk` 等真实文本符号，集中在偏移 `0x8f1614–0x8f6508` 附近。另有 `kfas_enable`、`kfas_hook`、`fixed_tfps`、`boost_minfreq`、`use_scx` 等参数。

`kfas_apply_limit` 实际调用两次 `freq_qos_update_request` 修改 CPU 最小/最大频率请求。帧事件路径计算间隔、报告负载，按当前频率范围把压力映射成频率下界，再与帧间隔反馈合并。`kfas_get_tfps` 可由帧间隔推断目标帧率，也支持固定目标。QCOM 路径含 SM8850 频率表，对 CPU0–5 和 CPU6–7 使用不同表；表中有频率不证明修改了 OPP 或硬件超频。

压力监控启用后用 `sched_switch` 统计目标线程执行时间，专用线程每轮睡眠约 8 ms 再采样；默认关注 4 个繁忙线程，并结合帧超时、SurfaceFlinger 掉帧形成 0–100 的压力。监控本身也有开销，未测净收益。

这是帧反馈调频控制器，不能据此称为新增 Linux 调度类。仅有 `SCHED_CLASS_EXT=y` 和 `use_scx` 参数也不能证明加载了某个完整第三方 BPF 调度器；实际机器码还有 sched_ext 启用时的避让分支。模块包含 `pudding` 的 Joyose 配置和 fas-rs 事件桥；何时启用仍依赖初始化与用户态开关。

`perfmgr.ko` 的 description 是 `Pandora kFAS Shim`、license 是 `Proprietary`；`.text` 为空，`.init.text` 只有 KCFI 前缀及返回成功的两条指令，提供三个参数入口。脚本把其 enable 节点 bind 到 `pandora_kfas/kfas_enable`，所以它是兼容入口，不能作为独立帧调度算法移入 Luna。

### 3.5 内存 vendor hook 与 THP 入口

`mm_vh_init` 注册了 swappiness、scan type 和匿名/文件页回收平衡三个 hook。机器码显示 `android_vh_use_vm_swappiness` 请求使用全局 swappiness，并在非正数时写成 1；`android_vh_tune_scan_type` 直接返回，不能将这个空回调列为额外扫描优化；开启 `enable_mm_vhs` 时，平衡回调将其布尔输出清零。另有 `mm_vhs.task_thp` / `set_task_thp` 入口。

这些证据不等于“更好的通用回收算法”。后续已确认按进程入口写 0 设置 MMF_DISABLE_THP，因此脚本对 HWC 的操作是禁用大页；清除该位也不等于 MADV_HUGEPAGE。Luna 已有 THP/mTHP 与 MGLRU；可先使用原生接口评估目标进程的缺页、尾延迟、内存峰值和回收表现。官方 THP 文档也说明大页清零/整理存在延迟成本，mTHP 可以减少一次分配过大的冲击。[Linux THP 文档](https://docs.kernel.org/admin-guide/mm/transhuge.html)

## 4. 包中用户态策略：不能全部计作 Image 优化

下表行号相对于 `tmp/hanamaki-module-analysis/` 解出的文件。外层 `tmp/hanamaki-analysis/anykernel.sh:93` 起先要求通过 Magisk/KernelSU/APatch 安装模块，之后才刷内核。刷包后的体验包含这些配置影响。THP、MGLRU、VM 参数初始化还受 `service.sh:305` 的节点存在性条件控制，不能假定每项始终执行。

| 策略 | 包内动作与证据 | 评估 |
| --- | --- | --- |
| THP/mTHP | `service.sh:276–301`：内存至少 10 GiB 时 `always`，否则 `madvise`；`defrag=always`；16–2048 KiB 各尺寸继承；启动扫描一度无睡眠 | 可以研究定向方案；不照搬全局积极整理。无睡眠扫描可占满一核 |
| MGLRU TTL | `service.sh:307–308`：`min_ttl_ms=1000`、`enabled=Y` | 原生参数；工作集保护与提前 OOM 的权衡。[官方说明](https://docs.kernel.org/admin-guide/mm/multigen_lru.html) |
| 回收/写回 | `service.sh:310–319`：`swappiness=1`、`page-cluster=0`、`min_free_kbytes=65536`、`watermark_scale_factor=200`、dirty ratio 5/2 等 | 可单项评估；200 表示 2% 水位距离，不是保留 200% 内存；`dirtytime_expire_seconds` 管 inode 时间戳，不是所有脏页。[VM 参数文档](https://docs.kernel.org/admin-guide/sysctl/vm.html) |
| WALT/PELT/时间片 | `service.sh:10,27–28,68–69,112,118–120`：请求 WALT、升降频限速 1 ms、90/70 迁移阈值、PELT multiplier 4、迁移成本 5 ms、base slice 10 ms | 响应、迁移和吞吐取舍；不能将已有 vendor WALT 说成包里新发明的调度器 |
| CPU/IRQ 亲和性 | `service.sh:104–109`：后台/IRQ 限于 cpu0 集群，部分 cpuset 放开全部 CPU | cpu0 集群不能自动称为传统“小核”；default_smp_affinity 使用列表格式与标准 bitmap 接口不符，可能拒绝 |
| 核心与频率 | `service.sh:95–97`、`utils.sh:123`：core_ctl min/max 写 99 后关闭、解 CPU 频率范围；另改 DDR/LLCC/L3 限制 | 可能以更高功耗换短时速度；越界值是否被拒绝/钳制尚未证明，不建议写入通用内核 |
| MPAM/SLC | `service.sh:64–75` 的 SM8850 分支修改 gear/schemata | 后续已核实目标 OTA 接口与 DT，实际写入和收益仍需证明 |
| UFS/块队列 | `service.sh:123–129`：所有块设备 `scheduler=none`、`nomerges=2`、`iostats=0`、预读 128 KiB | 禁用调度/合并未必适合前台延迟和顺序 I/O；停统计影响诊断，不建议整组照搬 |
| 热控/GPU | `service.sh:35–62,131–137`：throttling/bcl/cxl 写 0、trip point 写 100000、停 thermal-engine、杀 mi_thermald；action 模式还写 105000 和 UFS 高频 | 有明确降低保护/解除限制的意图。不能断言所有硬件保护实际失效，也不能据此认定算法更高效；不建议引入 |
| Joyose 游戏配置 | `gen_cloud_config.sh:83` 选择 pudding JSON，脚本覆盖云配置；含目标负载、时延投票、perfmgr、分辨率/SR/FI/VRS/高帧率设置 | 属于应用/厂商游戏路径；画质、分辨率、插帧变化会混淆性能比较 |
| 保后台/LMKD/freezer | `service.sh:339–347,365`、`system.prop:85–104`、`miui.prop`：提高缓存/phantom 上限、尝试关闭多种冻结/回收、改 LMKD | 部分值确有消费者，但标准 CachedAppOptimizer 的命名空间/取值与脚本不匹配，不能说成功关闭缓存冻结；适合在未来配套模块中逐项评估 |
| ART/JIT/渲染 | `system.prop:5–76,119–136`：dex2oat 多线程/过滤器、堆目标、JIT 和渲染属性 | Android 版本与属性消费者相关；无法证明每项适用于固定 OTA，不应归为内核优化 |
| TCP/DNS | `service.sh:350–355,371–383`：连接回收、乱序阈值、buffer、DNS 并行等 | 网络条件相关；四个 rmem/wmem default/max 参数写到 `net/ipv4`，标准节点在 `net/core`，这些写法有误 |
| 日志/监控 | 停部分诊断服务，用返回成功的空脚本替代 tcpdump/cnss_diag，关闭部分监控属性 | 影响可观测性；不作为 Luna 性能改进 |
| 其他系统改动 | 改证明服务域名、关闭 CT 日志列表服务等 | 与内核性能无直接关系，不纳入回移候选 |

关键取证限制：`utils.sh:59–68` 的 `mask_val` 先尝试写节点，再将含指定值的普通文件 bind 覆盖节点；没有核验写入成功。后续显示值可能只是覆盖文件，不能作为真实运行值。标准参数、私有属性和被注释的启动项都必须按实际执行条件判断，例如 AdrenoLimiter 的启动被注释，不能因为二进制在包里就称其已工作。

## 5. 已有能力和已回移项：无需重复

| 项目 | 官方 GKI / Luna 现状 | 对比较的含义 |
| --- | --- | --- |
| MGLRU | r21 原生启用，Luna 还具有主动回收到量停止修复 | 开启 MGLRU 不是 Hanamaki 独有优化 |
| sched_ext | r21/Luna 已有 `SCHED_CLASS_EXT=y` | 需要另证调度策略，不把配置开关当新调度器 |
| Proxy execution | r21 `gki_defconfig` 原生开启 | 缓解 mutex 优先级反转的机制已经具备 |
| RT softirq aware | r21 原生开启 | 关键实时线程避让繁忙 softirq CPU 的能力已有 |
| EAS/schedutil/UCLAMP | Luna 已有，且回移了 EAS runnable_avg 与 schedutil 初始化竞态修复 | 没有新增源码证据时，不将相同名称列为新候选 |
| PREEMPT/HZ | 两者均 PREEMPT、HZ=250、NO_HZ_IDLE | 本包没有从这些配置证明新的高频 tick 或实时抢占方案 |
| F2FS 压缩/UNFAIR_RWSEM | r21/Luna 已有；Luna 保留 LOOKUP_PERF 并有 overwrite/生命周期/GC 修复 | 不重复回移原生特性，不从文件系统名称推断改版性能 |
| EROFS 并行解压 | Luna 已有 per-CPU 高优先级解压和多压缩格式支持 | Hanamaki 反而关闭 deflate/LZMA/Zstd 格式，不能称功能全面增强 |
| THP/mTHP | Luna 原生能力，全局默认 `madvise`；PMD 尺寸继承，其他 mTHP 尺寸默认 `never` | 主要新增的是策略与自定义进程入口，不代表 Luna 默认启用了所有尺寸 |
| ZRAM 标准多算法/写回 | Luna 已有 LZO/LZ4/Zstd、多压缩与写回配置 | 与 Hanamaki 的替代压缩体系区分 |
| BBR/FQ | 两者都有 BBR 与 FQ，默认 TCP 仍是 cubic | 未发现可确认 BBR v2/v3 或默认启用 BBR 的证据 |
| 编译优化 | 两者 `CC_OPTIMIZE_FOR_PERFORMANCE=y`、`LTO_NONE=y`、`CFI_CLANG=y`、`AUTOFDO_CLANG=y` | 编译器版本不同不证明 profile 实际输入、`-O3`、LTO 或性能改善 |

当前 common 中，15 项性能/调度相关已选修复对固定官方 patch（上下文适配项用固定项目补丁）的 `git apply --reverse --check` 全部通过。以下是应特别去重的条目；这些检查证明已应用状态，不证明 Hanamaki 具有或缺少同一修复。

| 已有修复 | 作用 | 来源与仓内清单 |
| --- | --- | --- |
| MGLRU 主动回收到量停止 | 避免多余扫描/回收 | mainline `19999e479c2a38672789e66b4830f43c645ca1f2`；[310 清单](../patches/backports/r21-independent/310-mglru-proactive-reclaim.tsv) |
| F2FS cached overwrite | extent cache 命中时减少 inode folio 查找 | mainline `222bc257a151cc1b01d926199a0d5a7ba61d2e53`；[320 清单](../patches/backports/r21-independent/320-f2fs-cached-overwrite.tsv) |
| EAS runnable_avg | 修正迁移时利用率计算 | stable `29cf3b31e8cceebceed395b2a0ec7863adabca69`；[330 清单](../patches/backports/r21-independent/330-eas-runnable-avg.tsv) |
| schedutil 初始化顺序 | 避免 util hook 暴露未初始化状态 | stable `0504d52d05299c1177f2086884343430cdca1f5c`；[260 清单](../patches/backports/r21-independent/260-schedutil-hook-init-race.tsv) |
| PSI zero delta | 无新增 IRQ 时间时跳过无效统计 | mainline `b0bc1c75f304099347cfc0cc880b556966b54138`；[300 清单](../patches/backports/r21-independent/300-psi-zero-delta.tsv) |
| 去除单 bio 冗余 plug | 减少调用和栈开销 | mainline `9cbbac29d752fb5d95e375fa3685a359b89caa0a`；[900 清单](../patches/backports/r21-independent/900-block-submit-bio-plug.tsv) |
| hrtimer 避免无效重编程 | 中断处理中减少重复硬件事件设置 | stable `d8d7b0043accdbf641d9a3138a93af83641f1f1c`；[520 清单](../patches/backports/r21-independent/520-hrtimer-reprogram.tsv) |

其余检查通过项是 F2FS DIO overwrite、EAS cpumask 快路径、memcg rstat、blk-wbt done、block 时间戳竞态、TCP recv 时间戳、timer base 指针快路径和 timer migration 活锁修复，见 [patch.sh](../patch.sh) 及现有清单。r21 自带的 freezer 响应修复也不应重复回移。

## 6. 不建议引入的配置与兼容性变化

| 已证实差异 | 为什么不能当作可直接接受的优化 |
| --- | --- |
| C Binder 关闭、Rust Binder built-in | 后续确认实际由 Rust 注册，Rust 自带 BinderFS；固定 OTA 消费的 13 类 C Binder vendor hook 在正常 Rust 路径缺少等效触发证据，不能由导出存在判断语义兼容，更不能挪用现有 `rust_binder.ko` 精确例外 |
| ZRAM 关闭、zsmalloc 改 built-in，其他大量 stock 功能由模块改 built-in | 会改变 module provider、加载及交付关系；固定 OTA 的原有 zram/zsmalloc 模块不能被忽略 |
| `PANDORA_GKI_ABI_KEEPER=y` | 没有源码可审核其具体做法。抽查发现 Binder traceiter 有正常函数体，**不能凭名称断言伪造导出/空实现**；仍然不能替代 Luna 完整闭包门禁 |
| 内嵌 cmdline 含 `nokaslr`、`mitigations=off`、`hardened_usercopy=off`、`audit=0`、`norandmaps`、`kasan=off` 等 | 有明确减少随机化、防护和诊断的意图；各参数实际生效还依赖解析器与最终 cmdline。不作为 Luna 性能候选 |
| `BPF_UNPRIV_DEFAULT_OFF=n` | 与 Luna 保持默认关闭非特权 BPF 的硬要求冲突 |
| `BLK_WBT_MQ=n` | 恢复/保留了 GKI 的关闭状态，但 Luna 明确要求开启；不能以吞吐收益豁免前台写回保护要求 |
| 关闭 hardlockup/DPM watchdog、panic-on-oops，KFENCE 采样间隔 0 | 减少故障检测与诊断，不能据安静日志认定稳定；不建议采纳 |
| `USER_NS=n`、`PID_NS=n`、tmpfs ACL/xattr 关闭，EROFS 压缩格式裁剪 | 改变已有用户态/文件系统能力；没有目标需求和兼容性证据，不属于低风险优化 |
| PCIe ASPM 采用 power_supersave | 潜在节电取舍，不是 UFS 优化；相关设备/链路及恢复延迟未验证，优先级低 |
| 换 Clang 21.1.8、MODULE_SCMVERSION/LOCALVERSION_AUTO 变化 | 工具链和构建身份变化，不构成性能证据；Luna 既有工具链树和 release 规则必须保留 |

补充名称级检查：固定清单的 **4,083 个 vmlinux 依赖名都能在 Hanamaki `__ksymtab_*` 中找到**。这仅证明名字覆盖，本次没有完成全目标 CRC、namespace、provider、相关类型和启动闭包证明，不能据此批准刷入。具体反例风险是 Luna 审计 `Module.symvers` 中 `zs_create_pool`、`zs_malloc`、`zs_free` 等来自 `mm/zsmalloc`，Hanamaki 则在 Image 直接导出；按原 provider 加载 stock `.ko` 的语义必须重新证明。

Image 还有自定义 `module_is_blocked` / `freq_qos_is_blocked` 路径：

- `load_module` 将 `load_info.sig_ok` 传给自定义筛选器；签名验证通过者跳过名单，其余匹配者返回 `-EPERM`。50 项名单包括 `mi_mem_limit`、`kshrink_slabd`、`mi_damon`、`scene_swappiness`、`thermal_config`、`qcom_cpufreq_thermal`、`thermal_pause`、若干 MTK 功耗模块及 `zram`、`zsmalloc`。这证明存在屏蔽策略，不证明目标设备每一个同名模块都没加载。
- `freq_qos_update_request` 筛选命中后直接返回 0，不更新已有请求；按 `current->group_leader->comm` 匹配 `thermal` / `mtkpower` 的路径可见。另一组来源符号关键词匹配使用了筛选器自己的返回地址，未使用调用者传入的原始地址；当前唯一直接调用点下，该部分不能实现预期的来源匹配。不能宣称所有温控或六类 QoS 都被移除。

这些行为会改变模块加载及 vendor 控制语义，不能作为 Luna stock 闭包的例外或通用提速补丁。

## 7. 证据位置与本次验证范围

原始提取物、完整差异和反汇编保留在忽略目录，不提交二进制或转储：

- [Hanamaki 配置](../tmp/hanamaki-analysis/hanamaki.config)、[Luna 对照配置](../tmp/hanamaki-analysis/luna.config)、[完整 248 项配置差异](../tmp/hanamaki-analysis/config-diff.tsv)。
- [kallsyms](../tmp/hanamaki-analysis/kallsyms.tsv)、[kallsyms 布局](../tmp/hanamaki-analysis/kallsyms-layout.json)、[新增机制符号](../tmp/hanamaki-analysis/feature-symbols.tsv)、[BTF 结构](../tmp/hanamaki-analysis/btf-structs.txt)。
- [内存反汇编](../tmp/hanamaki-analysis/memcompress.disasm.txt)、[MM hook 反汇编](../tmp/hanamaki-analysis/mm-hooks.disasm.txt)。反汇编用恢复的符号和 Image 构造只供分析的 ELF 容器，**不是从包中取得的原始 vmlinux**；地址按 Image 基址换算，函数尾部可能包含下一个符号的 KCFI 元数据，不将其误判为执行指令。
- [kFAS/调频/模块筛选详细证据](../tmp/hanamaki-analysis/kfas-findings.txt)及同目录 `kfas-disassembly.txt`、`kfas-callsites.txt`、`kfas-extra.txt`。
- [附加模块详细证据表](../tmp/hanamaki-module-analysis/findings.md)，以及同目录中静态解出的脚本、属性、JSON 和模块。

已完成 ZIP CRC/gzip 完整性检查、IKCONFIG 提取、BTF 结构解析、完整 kallsyms marker 核对、配置键级比较、相关函数反汇编和 Luna 既有补丁去重。**未经真机性能验证，也未完成 Hanamaki 对固定 OTA 的可启动兼容性认证。** 本次只提交分析文档，保留编号供用户选择后续审计/实验范围。
