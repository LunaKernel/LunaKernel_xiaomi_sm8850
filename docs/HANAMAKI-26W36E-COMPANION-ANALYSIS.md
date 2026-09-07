# Hanamaki 26w36e 配套优化模块独立分析

本文评估 `Kernel-Hanamaki-6.12-26w36e-021748.zip` 内 `magisk.zip` 对未来 Luna 配套模块的参考价值。配套模块是独立候选交付方向，不因其属于用户态而排除；本次只分析，没有创建模块、修改内核、安装归档、执行包内程序或操作手机。

最值得先研究的是：**按应用 ART 编译维护、条件启用小型 USAP 池、游戏场景 WALT 调频参数、正确编码的 DNS 服务器排序，以及终端多子进程场景的有限 phantom 配额调整**。LMKD、IO、TCP 和图形后端也有条件价值，但不宜默认整组启用。原包包含明确的单位、路径、命名空间和值编码错误，不能把脚本宣称的功能直接当作已生效功能。

## 1. 证据范围与当前基线

- 原包脚本及配置安全提取至 `tmp/hanamaki-module-analysis/`；下文 `service.sh:行号`、`system.prop:行号` 等均相对该目录。完整归档拆解见 [总报告](HANAMAKI-26W36E-ANALYSIS.md)。
- 用户态参考采用官方 `android-17.0.0_r1`，不是拿 Android 16 的框架行为推断 Android 17。固定提交：frameworks/base `94b4c163b7dfe5ce3607f7bb8456f9573f7de57d`；ART `b753cf97923c3695338d21466fa14c57b480a59a`；LMKD `c3601e823bd07c9c190f67e2f9bc7486e4978328`；DnsResolver `0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f`；frameworks/native `ae266dcb706d083868578cfedce381ef44488a07`。下载来源、文件摘要保留于 `tmp/hanamaki-module-analysis/aosp17-reference/manifest.json`。
- 官方 AOSP 默认值只能说明参考实现，**不能代替固定 HyperOS OTA 的实际值**。HyperOS 可能有资源覆盖、DeviceConfig、属性覆盖及 vendor 扩展；本次未取得其 framework/vendor 二进制消费者和运行时采样。下文凡称“默认”均明确范围。
- Luna 的已取证配置具备 CPUSETS/MEMCG、cgroup freezer、PSI、BPF、CPUFreq、相关块调度器及网络基础；很多候选无需新增内核代码。WALT、MIST、Joyose 则还依赖目标 vendor 模块、节点和服务，配置中存在能力不等于该 OTA 已启用相关策略。
- `lock_val` 没有写入成功校验；`mask_val` 还会把普通文件 bind 到目标节点，内核拒写后仍可能显示预期字符串（`utils.sh:8`、`:59`）。因此脚本文件、属性回显、被遮罩节点的读值均不足以证明实际生效。
- 原包 `init_mem()` 在缺少 `pandora_config/enable_mm_vhs` 节点时整个返回，连其中 `lmkd --reinit` 也不执行（`service.sh:305`、`:325`）。复制到 Luna 不能假设该路径自然运行。

## 2. 供选择的候选清单

优先级表示下一轮研究顺序，不代表已证明收益或已授权实施。**P1：消费者与机制清楚，值得先单项试验；P2：仅在对应瓶颈或用途存在时试验；P3：证据不足，或原包方案需明显收缩。**

| 编号 | 候选及简洁作用 | 适用场景与代价 | 建议范围 |
| --- | --- | --- | --- |
| M01 / P1 | **按应用 ART 编译维护**：利用已有 profile 预编译常用代码，减少后续解释/JIT 工作 | 常用应用更新后、频繁冷启动；占用编译时间、电量和磁盘空间 | 充电空闲时对选定应用运行系统 ART 维护；优先 `speed-profile`，保留官方默认策略；不照搬全系统 `everything` 与所有场景 8 线程 |
| M02 / P1 | **小型 USAP 池**：预先保留尚未专门化的应用进程，缩短新进程创建路径 | 若 stock 尚未启用，可比较应用冷启动；常驻少量内存、补池有 CPU 成本 | 先确认 stock/OEM 预启动机制；以标准小池 max=3/min=1 起步，已启用时无需重复设置 |
| M03 / P1 | **按游戏 WALT 参数档**：针对持续帧负载调整利用率到频率的映射及响应节奏 | 固定画质/帧率下争取续航和持续性能；可能损失帧尾延迟 | 检查实际 governor/节点，独立测 `target_loads` 和升降频限速；退出游戏恢复，不改温控、电流保护或强锁最高频率 |
| M04 / P1 | **DNS 服务器排序**：根据已积累的服务器表现选择查询顺序 | 网络提供多个 DNS 且其中一个慢或不稳时；样本不足可能误选 | 核实系统确有该消费者后用整数 `1`，验证 resolver 内部状态；维持原 DNS 地址与安全策略 |
| M05 / P2 | **有限 phantom 配额**：减少终端、proot、构建工具等多子进程任务被数量上限截断 | 确认命中 phantom 数量限制的工作负载；增大后台进程和内存消耗 | 保留监控，按实际峰值设置有限上限；64/128 只能作为量测档示例，不作为统一默认；关闭监控只作为明确选择的兼容档 |
| M06 / P2 | **基于杀进程原因的后台驻留档**：减少不必要的 cached/LMKD 驱逐 | 内存容量足、频繁切应用且确实被回收；过度保留可能导致回收颠簸和前台卡顿 | 分开校准 cached 数量、LMKD 阈值和压缩比估计；保留 freezer，拒绝 `65535`、低 swap 阈值 `0`、约 25 天免数量清理的组合默认 |
| M07 / P2 | **UFS 调度/预读单项实验**：权衡请求排队开销、混合 IO 公平性与连续读取吞吐 | 下载/安装与前台启动竞争、连续读大文件；`none` 未必比现有调度器快 | 仅选实际 UFS 底层队列，保留 iostats 与 WBT；独立比较当前调度器和 `none`，预读按工作负载评估 |
| M08 / P2 | **高带宽时延链路的 TCP 自动缓冲上限**：容纳更大的在途数据 | 大文件传输的带宽时延积超过当前上限；更多 socket 内存 | 先证明窗口受限，再只增大上限；不同时把每连接最低/默认缓冲改成 64 KiB/1 MiB |
| M09 / P2 | **稀疏 TCP 的线性重传超时**：减少小流量连接连续超时后的指数退避等待 | SSH/VNC 等稀疏 TCP 且确有丢包；可能增加重传和唤醒 | 独立开关 `tcp_thin_linear_timeouts`；对 UDP 游戏传输没有该项收益 |
| M10 / P2 | **游戏画质/帧率配置与图形后端实验**：按用户选择调整渲染负载或后端 | 指定游戏与驱动组合；可能改变画质、内存占用或兼容性 | 画质、分辨率、插帧与内核性能分项报告；优先已有游戏设置，后端只做可恢复实验 |
| M11 / P3 | **CPU/IRQ 亲和性**：避免已识别的中断与前台线程争抢 | 只有追踪证明存在争抢才有价值；可能增加跨簇通信、延迟或局部拥塞 | 不全局重排全部 IRQ，不删除 cgroup；按拓扑、IRQ 类型及 task profile 定向评估 |

MGLRU、THP/mTHP、VM 回收写回和压缩算法由内核候选专项处理。本模块只需提供明确的独立参数接口和回滚，不应把 `mm_vhs` 节点存在检查变成 Luna 通用内存设置的前置条件。

## 3. ART、JIT 与 USAP：有实际消费者，但原包两处关键误读

### 3.1 编译过滤器和并行度

`system.prop:5–16` 把多类 dex2oat 线程数设为 8、CPU 集合设为 `0,1,2,3,4,5,6,7`，`:20–57` 把许多编译原因改成 `everything`。Android 17 的 `artd` 仍读取不同优先级的 `dalvik.vm.{boot,restore,background,default}-dex2oat-*`，ART Service 从 `pm.dexopt.<reason>` 读取过滤器与并发数量；`everything` 在该版本是有效过滤器，不能简单判成“失效旧属性”。但并非原包列出的每一个旧 reason 都证明有当前消费者。参考产品的安装、后台维护通常用 `speed-profile`；全量编译扩大了覆盖范围，也提高编译 CPU、空间和维护成本。[ART 参数消费](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/artd/artd.cc#2203)、[原因映射](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/libartservice/service/java/com/android/server/art/ReasonMapping.java#174)、[过滤器解析](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/libartbase/base/compiler_filter.cc#197)、[AOSP 产品默认](https://android.googlesource.com/platform/build/+/refs/tags/android-17.0.0_r1/target/product/runtime_libart.mk#117)。

后台并发 2 配合每任务 8 个编译线程，可能形成 16 个编译工作线程；实际执行还受 task profile、CPU 集合及 ART 调度限制，不等于必然同时占满 16 核。其价值主要在缩短维护耗时，不保证前台流畅。`pm.dexopt.boot-after-mainline-updat.concurrency` 少了末尾 `e`（`:32`），无法覆盖标准 `boot-after-mainline-update` 并发设置；标准代码为完整 reason 拼接 `.concurrency`。[并发读取](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/libartservice/service/java/com/android/server/art/ReasonMapping.java#237)。

未来模块的最小实现应是选定应用、明确的空闲/充电条件和有限资源的维护入口。编译结果属于 ART 缓存，撤销属性不会立即恢复原先缓存状态；应让系统正常维护或使用版本匹配的系统接口重新生成所选应用的产物，不能通过删除整棵数据/缓存目录“回滚”。

### 3.2 JIT 裸数是字节，不是 KiB

`system.prop:71–76` 的注释声称从 64 KiB/64 MiB 扩成 64 MiB/512 MiB，实际写入的是 `jitinitialsize=65536`、`jitmaxsize=524288`。`AndroidRuntime` 原样传给 `-Xjitinitialsize:`/`-Xjitmaxsize:`；ART 的 `MemoryKiB` 解析器对无后缀数字仍按**字节**解释，`1024` 是对齐约束，不是乘数。因此实际是 **64 KiB 初始、512 KiB 最大**，最大容量相对官方文档的 64 MiB 默认显著缩小。较小 code cache 会更早面临容量压力，不能写成“扩大 JIT 缓存提速”。[属性传递](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/jni/AndroidRuntime.cpp#898)、[容量解析](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/cmdline/cmdline_types.h#114)、[ART 配置说明](https://source.android.com/docs/core/runtime/configure)。

`jitthreshold=1000` 在固定 ART 中映射到 `JITOptimizeThreshold`，调整优化编译阶段的热度阈值，可能更早提交优化编译；初始热度及 baseline/fast compiler 另有阈值，不能泛称让所有 JIT 更早启动。官方文档中的 10000 也不能直接代替本 OTA 的当前优化阈值。它与极小 code cache 的组合没有量测支撑。[固定选项解析](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/runtime/parsed_options.cc#179)、[JIT 阶段处理](https://android.googlesource.com/platform/art/+/b753cf97923c3695338d21466fa14c57b480a59a/runtime/jit/jit.cc#1268) 未来模块不建议默认改 JIT 容量、阈值或堆大小。若专项实验，应带明确 `k/m` 单位，并分别观察编译、GC、RSS 和启动时间。这些运行时选项在 Zygote/ART 启动时读取，写属性不代表现有进程立即切换；卸载后通常需重启恢复新进程的基线。

堆的 `512m` 上限、`2m` 初始、`512k/32m` 空闲区间、前台增长倍率 `2.5` 与内存容量分档的 target utilization `0.5/0.8`（`customize.sh:72–75`）同样是全局 CPU/内存权衡，不能仅根据物理内存大小认定更合适。`qcom.prop` 的 `oryon`/`features=runtime` 有版本相关 ART 解释，尚未证明相对 stock 生成更好的代码，不列为独立性能候选。

### 3.3 USAP 值得条件启用，池参数多数就是默认

`system.prop:77–81` 开池，max=3、min=1、refill threshold=1、补池延迟 3000 **ms**；`:175` 再设置 `persist.device_config.runtime_native.usap_pool_enabled=true`。Android 17 参考实现默认开关为 false，其余四个值就是标准默认。`ZygoteConfig` 优先读 `persist.device_config.runtime_native.*`，再读 `dalvik.vm.*`，所以只核对后者容易误判。[ZygoteConfig 默认与优先级](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/java/com/android/internal/os/ZygoteConfig.java#30)。

这是明确的应用启动优化机制，Luna 不需新内核实现。先确认 HyperOS 当前是否已启用、是否另有预启动池，再做相同应用顺序的冷启动对照，记录启动尾延迟、驻留内存与补池 CPU。没有 stock 状态时，不能把“写了 true”当作相对 stock 的增益。

## 4. 后台驻留、freezer 与 LMKD：必须拆开评价

### 4.1 cached/phantom 上限与冻结并非一个功能

| 原包设置 | Android 17 标准语义与默认 | 结论 |
| --- | --- | --- |
| `max_cached_processes=65535`（`service.sh:340`） | 标准常量 1024，但资源覆盖、DeviceConfig 与开发者进程上限共同决定实际值 | 近乎取消数量上限；不阻止 LMKD 或其它回收。只有实际命中数量驱逐时，提高上限才有收益 |
| `no_kill_cached_processes_post_boot_completed_duration_millis=2147483647`（`:341`） | 标准默认 600000 ms；实际从用户解锁起计，设定值约 24.855 天 | 延长针对 cached 数量清理的豁免，不是所有低内存杀进程停 25 天 |
| `max_phantom_processes=65535`（`:342`） | 标准默认 32 | 特定多子进程应用确有兼容性用途；普通应用流畅度不能由此推出 |
| `settings_enable_monitor_phantom_procs=false`（`:366`） | 该全局标志按布尔值解析，默认 true；phantom trim 会检查它 | 此处 false 确有标准消费者，应与提高有限配额分开选择 |
| `use_compaction=false`（`:339`） | `activity_manager` 是正确命名空间，AOSP 17 默认 true | 关闭 cached app compaction 可能减少压缩/换出工作，也可能增加驻留内存及杀进程；不是 kernel 内存整理总开关 |
| `kill_bg_restricted_cached_idle=false`（`:344`） | AOSP 17 默认已经 false | 没有 stock 差异证据时不算新增优化 |

来源：[ActivityManagerConstants](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/core/java/com/android/server/am/ActivityManagerConstants.java#192)、[PhantomProcessList](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/core/java/com/android/server/am/PhantomProcessList.java#407)、[FeatureFlagUtils](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/core/java/android/util/FeatureFlagUtils.java#237)、[compaction 消费者](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/core/java/com/android/server/am/CachedAppOptimizer.java#945)。

**原包不能据此确认为关闭了标准 cached-app freezer。** 它写 `activity_manager/use_freezer=false`（`:343`），但标准消费者读 `activity_manager_native_boot/use_freezer`；另写 `settings global cached_apps_freezer false`（`:365`），标准消费者识别的是字符串 `disabled` 或 `enabled`，不是 `false`。无法识别的值走 DeviceConfig 默认/覆盖路径。HyperOS 是否专门兼容这种写法未证实。[精确 freezer 读取分支](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/services/core/java/com/android/server/am/CachedAppOptimizer.java#1030)。

未来驻留档优先保留 freezer：冻结可减少保留下来的 cached 进程消耗 CPU。真正存在特定应用/服务兼容问题时再提供显式 freezer 兼容档，不能把关闭 freezer 和保后台绑定。Joyose JSON 中 `background_freeze_enable=true` 是另一条 vendor 策略，不能与上述标准 freezer 错误简单相互抵消。

### 4.2 LMKD 多数值是默认，少数改动才真正改变压力判定

标准 LMKD 优先读取 `persist.device_config.lmkd_native.<key>`，再读取 `ro.lmk.<key>`。因此必须同时核对两层；只看 `ro.lmk` 会漏掉覆盖。[读取优先级](https://android.googlesource.com/platform/system/memory/lmkd/+/c3601e823bd07c9c190f67e2f9bc7486e4978328/lmkd.cpp#108)。

| `system.prop:85–104` 的主要参数 | 标准非 low-RAM 参考 | 实际解释 |
| --- | --- | --- |
| partial/complete stall = 70/700 | 同值；默认 PSI 窗口 1000 ms | 单位为毫秒的压力触发条件，不是把杀进程等待固定为 70/700 ms |
| thrashing=100、decay=10、direct reclaim threshold=0、swap util max=100、filecache min=0 | 均为参考默认 | 需证明 stock 原值不同才算策略变更；`0` 的含义随参数不同，不能统一称禁用 LMKD |
| `stall_limit_critical=100` | 默认 100 | 是 PSI avg10 的百分比阈值，不能误写为 100 ms |
| low/medium/critical = 1001/800/0；lowmem min oom score=701；kill heaviest=false；pressure after kill min score=0 | 均为参考默认 | 没有独立“保后台算法”增量证据 |
| `swap_free_low_percentage=0` | 默认 10% | 关闭低 swap 比例条件的触发空间，可能推迟相关杀进程分支；并不关闭全部低内存处理 |
| `swap_compression_ratio=5` 后又 `=4` | 默认 1，另有 divisor | 重复定义，最终属性值需看加载结果；脚本后值为 4。它是有效 swap 余量估计参数，不会把实际压缩率提高到 4 倍 |
| `delay_monitors_until_boot=true` | 默认 false | 延后启动期间的监控开启；不是长期保后台能力 |

常量及属性读取见 [LMKD 默认值](https://android.googlesource.com/platform/system/memory/lmkd/+/c3601e823bd07c9c190f67e2f9bc7486e4978328/lmkd.cpp#122)、[配置更新](https://android.googlesource.com/platform/system/memory/lmkd/+/c3601e823bd07c9c190f67e2f9bc7486e4978328/lmkd.cpp#4088)。压缩比参与 `min(free_swap, easy_available × ratio / divisor)` 等估算；随意放大可能高估可承受的 swap，不会改善压缩算法。[有效 swap 计算](https://android.googlesource.com/platform/system/memory/lmkd/+/c3601e823bd07c9c190f67e2f9bc7486e4978328/lmkd.cpp#1997)。

可取的派生方案是：记录真实杀进程原因、PSI、swap、refault 和应用重载，再只校准命中的因素。LMKD 配置通过受支持的重新初始化接口生效；原包 `lmkd --reinit` 还受其内核私有节点条件限制。未来模块应明确验证重读结果，避免以强杀守护进程或关闭监控替代调参。

## 5. DNS 与 TCP：识别版本变化，按网络条件选项

### 5.1 DNS 的一个有效候选和一个过短超时

`service.sh:350–355` 与 `system.prop:157–162` 重复配置 DNS 实验项。AOSP 17 `Experiments` 的开关值通过 `ParseInt` 解析，不是通用布尔属性解析器。[读取与解析](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/util.cpp#40)、[受支持实验项](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/Experiments.h#50)。

| 原包项 | 固定 AOSP 17 消费情况 | 模块建议 |
| --- | --- | --- |
| `sort_nameservers=true` | 有消费者，但需要整数。`true` 解析失败回退，默认 0；正确启用值为 `1`。开启后按 UDP 服务器统计排序 | 可优先测试修正后的独立项，尤其多个 DNS 表现差异明显时 |
| `retransmission_time_interval=100` | 有消费者，单位 **ms**；仅 framework 提供的 `baseTimeoutMsec` 为 0 时采用，标准回退 5000 ms | 100 ms 在蜂窝、漫游、高 RTT 网络过激，易过早重传；不作为全球统一默认 |
| `parallel_lookup=true` | 固定实现的标准路径已并行调用查询；实验项是 `parallel_lookup_sleep_time`，默认间隔 2 ms | 原包此键没有该标准消费者，不能声称新开启 Android 17 DNS 并行 |
| `happy_eyeballs_enable=true`、`smartdns_ipv4_first=false`、`smartdns_ipv6_timeout=300` | 未在已核对的固定 DnsResolver 实验表找到对应消费者 | HyperOS 自定义消费者待证，暂不作为有效优化；不能混同 DNS 并行与 TCP/QUIC 地址竞速 |

排序与 timeout 条件见 [res_cache.cpp](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/res_cache.cpp#1682)、[DNS 排序](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/res_cache.cpp#1767)、[并行查询](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/getaddrinfo.cpp#1675)。

实验值在 resolver 网络缓存创建/销毁等路径刷新，设置值不保证现有网络立即重新读取。未来模块应查看 resolver 的实验值与每网络状态，再以自然网络重建或重启完成验证；没有必要强制用户断网或替换 DNS 地址。[配置刷新入口](https://android.googlesource.com/platform/packages/modules/DnsResolver/+/0aeaf9d222ec761b9e0443a01c7a06590b9d1b4f/DnsResolverService.cpp#279)。

### 5.2 TCP 原包参数与合理派生

| 原包 `service.sh:371–383` | 固定内核标准默认/含义 | 判断 |
| --- | --- | --- |
| `tcp_rmem/tcp_wmem=65536 1048576 16777216` | 三项为最低、默认、最大字节数；接收常规默认约 4 KiB/128 KiB/最高 6 MiB，发送约 4 KiB/16 KiB/最高 4 MiB，最大值受内存条件影响 | 高带宽时延积链路可研究 16 MiB 上限，但抬高所有连接的最低/默认值会增加内存，不宜绑成一组 |
| `rmem_default/max`、`wmem_default/max` 写到 `/proc/sys/net/ipv4/` | 标准节点在 `/proc/sys/net/core/` | 四项路径错误，不能算在标准 GKI 生效 |
| `tcp_thin_linear_timeouts=1` | 默认 0；稀疏 TCP 流最多进行 6 次线性超时重传，再恢复指数退避 | 可用于有证据的交互 TCP 延迟问题；不作用于 UDP |
| `tcp_shrink_window=1` | 默认 0；允许按接收缓冲内存限制收缩已通告窗口 | 可研究高 socket 内存压力场景；不是直接提速开关 |
| `tcp_autocorking=0` | 默认 1；关闭小写入自动聚合 | 某些发送延迟场景可测，但增加小包/CPU 开销，不作通用低延迟默认 |
| `tcp_tw_reuse=1`、`tcp_fin_timeout=5` | 默认分别为 2（仅 loopback 重用）、60 秒；FIN timeout 主要控制 orphan FIN_WAIT_2 | 面向连接生命周期，不直接缩短正常请求 RTT；没有端口/连接病态证据时保留原值 |
| `tcp_reordering=10`、`tcp_max_reordering=1000` | 默认 3/300；控制乱序容忍与自适应边界 | 可能延后真正丢包的恢复；不作弱网统一优化 |

来源为固定 common 的 `Documentation/networking/ip-sysctl.rst`、`net/ipv4/tcp.c`、`net/core/sysctl_net_core.c`，以及 [Linux 官方 TCP sysctl 说明](https://docs.kernel.org/networking/ip-sysctl.html)。最终实现需记录作用的网络命名空间，按原始值回滚；不能用 bind 遮罩文件锁住读数。

## 6. WALT、Joyose、CPU/IRQ 与 IO

### 6.1 pudding 的 `-5` 是利用率下调，不是性能加成

Joyose 的 `config/joyose/booster_config_pudding.json:814`、`:818` 设置 policy0 `target_loads=0 960000:-5`、policy6 `0 1689600:-5`。固定 Xiaomi WALT 源码把频率门槛（kHz）转换为利用率门槛，并执行 `util × (100 + boost) / 100`，再按所在档门槛保底。因此 `-5` 表示该档利用率计算减少 5%，仍受其它 boost、最低门槛和频率映射影响，**不等于实际频率或性能恒定降低 5%，更不是提速 5%**。[固定 Xiaomi 消费者](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/45705be1220b4cfa8100516ad86711656c0b634e/kernel/sched/walt/cpufreq_walt.c#L498)、[参数解析](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/45705be1220b4cfa8100516ad86711656c0b634e/kernel/sched/walt/cpufreq_walt.c#L1017)。

这是可独立借鉴的游戏能耗调参思路：在固定画质和帧率下测量帧时间尾部、功耗、温度及持续 20–30 分钟后的表现，确认有余量后才保留。`service.sh:27–28` 的升/降频限速 1000 **μs** 也应独立测量：stock 若高于 1 ms，改小可加快响应；stock 若为 0，改成 1 ms 反而增加限速。只依据数字小不能断言更快。

WALT 可能由 stock vendor 路径提供，应通过 `scaling_available_governors`、当前 governor 和实际 policy 拓扑确认；Luna 的 GKI 配置不构成这些 vendor 节点存在的证明。模块也不能硬编码“小核 0–5、大核 6–7”标签代替实际拓扑发现。

### 6.2 Joyose 中混有帧控桥与画质策略

原包按设备选择 JSON，并把版本改成 `2047123101`，覆盖整份云配置并更新相关数据库（`gen_cloud_config.sh`）；`service.sh:142–162` 将 Joyose 的 perfmgr 开关 bind 到 `pandora_kfas/kfas_enable`。包内 `perfmgr.ko` 的描述是 `Pandora kFAS Shim`，常规 `.text` 为 0，初始化只是返回成功，提供少量参数；真正算法在定制内核 `pandora_kfas`，不能把这个 `.ko` 当独立帧调频实现。`main.lua:145`、`:164–169` 也通过 fas-rs 事件切换 kfas hook。

JSON 还有 MIST 时延投票、stall 阈值、分辨率、超分、插帧、VRS、高帧率白名单。其作用可能是增加带宽需求、改变游戏负载或画质，不能全部计为“相同画质下内核性能提高”。MIST 节点和 Joyose 业务消费者尚未完整验证，不能用 JSON 字段名推定已经生效。MPAM 的 CPU 控制器与 SLC 映射另见内核专项，不把 `cpbm/cmax/prio` 泛称为把整片 SLC 分给 CPU。

未来模块可先做明确选择的单游戏参数档，优先调用现有系统机制；不复制整份云配置、伪造超高云版本、重写 Joyose 数据库或引入该二进制 shim。需要 kFAS 时应先取得可审计实现及固定来源，而不是从桥接参数推断算法。

### 6.3 全局亲和性重排和块队列设置应收缩

`service.sh:104–109` 把 background 和所有可写 IRQ 绑到 cpu0 所在簇，其他 cpuset 放开所有 CPU。cpu0 所在簇不能自动等同传统 little cluster；managed IRQ 可能拒绝手工亲和性。`:108` 向 `default_smp_affinity` 写的是 CPU **列表**，标准接口需要十六进制 **bitmap**，`:109` 的 `smp_affinity_list` 才接受列表。[Linux IRQ affinity 说明](https://docs.kernel.org/core-api/irq/irq-affinity.html)。

定向避开前台线程与高频 IRQ 的争抢有机制价值，但必须知道设备中断类型、实际 CPU 分布与调度阻塞，不能统一搬迁全部 IRQ。原包还删除 `/dev/memcg`、`/dev/blkio` 并重排 cgroup（`:99–100`）；未来模块不应借此破坏系统 task profile、资源隔离或统计接口。

块队列组（`:123–129`）对所有设备设 `scheduler=none`、`nomerges=2`、`iostats=0`、两处 `read_ahead_kb=128`。固定内核的普通预读初值就是 128 KiB，queue/bdi 两个接口最终操作同一 `ra_pages`，重复写入不是两项优化；驱动和用户态仍可能覆盖初值。`nomerges=2` 禁止全部合并，`iostats=0` 关闭队列统计，都不能普遍提高前台性能。Luna 已启用 MQ deadline/Kyber/BFQ 与 WBT，可在目标 UFS 队列保留统计的前提下比较现状与 `none`，无需先改内核。[固定内核队列 ABI](https://android.googlesource.com/kernel/common/+/0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28/Documentation/ABI/stable/sysfs-block)、[预读接口实现](https://android.googlesource.com/kernel/common/+/0b90ebc7cfc914b9353f3d6898b8b65c35e8bc28/block/blk-sysfs.c#268)。

## 7. 渲染属性：有真实消费者，不保证优于 stock

`debug.renderengine.backend=skiavkthreaded`（`system.prop:136`）在 AOSP 17 SurfaceFlinger 确有消费者，选择 Vulkan 的线程化 RenderEngine；`max_frame_buffer_acquired_buffers=4`（`:123`）相对源码回退值 2 提高允许获取的缓冲数量。它们分别影响合成后端与缓冲资源，不是同一个开关，也不直接提高应用自身的绘制效率。后端可能已由 stock 选好，强制覆盖还可能改变更合适的新后端；增加缓冲占用内存，端到端延迟要看完整队列。[后端选择](https://android.googlesource.com/platform/frameworks/native/+/ae266dcb706d083868578cfedce381ef44488a07/services/surfaceflinger/SurfaceFlinger.cpp#887)、[缓冲默认](https://android.googlesource.com/platform/frameworks/native/+/ae266dcb706d083868578cfedce381ef44488a07/services/surfaceflinger/SurfaceFlinger.cpp#503)。

HWUI 固定实现也会参考 Vulkan sysprop/renderer 选择，但原包各个 `hw=1`、`debug.renderengine.vulkan`、`debug.sf.multithreaded_present` 不能凭名字整体认定有效；本次没有为所有旧键和 vendor 键找到固定消费者。未来候选仅限确认后的后端实验，验证闪屏、合成错误、应用兼容、GPU 时间和温度；不默认叠加缓冲数和画质变化。[HWUI 渲染器选择](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/libs/hwui/Properties.cpp#221)。

## 8. 未来模块的最小实现与回滚边界

每项候选单独开关，默认沿用系统；先辨认设备/OTA、消费者、现值与单位，再决定是否产生实际差异。sysfs/sysctl 写入必须检查返回值并读取真实节点，不使用 bind 文件伪装生效。游戏场景退出时恢复该场景修改过的值；服务与应用有自身更新者时，不以高频循环写入与其争抢控制权。

Android 17 的 `device_config override` 是有效命令，并会优先于服务端更新；`clear_override` 也是单独动作。原包同时 `put` 和 `override`（`service.sh:334–335`），所以回滚不能只 delete 可见值，也不能重置整个 namespace。未来模块应保存所选 key 原先的缺省/显式值及 override 状态，只撤销自己建立的覆盖，再恢复原状态。[DeviceConfig override 语义](https://android.googlesource.com/platform/frameworks/base/+/94b4c163b7dfe5ce3607f7bb8456f9573f7de57d/packages/SettingsProvider/src/com/android/providers/settings/DeviceConfigService.java#653)。

`ro.*`、Zygote/SurfaceFlinger 启动属性与 DeviceConfig 的即时监听项要分开处理：有些必须在启动前生效，卸载后也需重启；LMKD 和 DnsResolver 有各自刷新路径。属性存在和进程正在使用它是两件事。量测应在相同应用、画质、温度、网络条件下进行，关注对应工作负载的尾延迟、功耗和错误率，而不是把所有开关同时打开后只看跑分。

原包的停 thermal-engine、杀 mi_thermald、提高热阈值、关闭电流限制、伪装 tcpdump/cnss_diag、修改证明服务地址与关闭 CT 服务，不属于本清单建议。这些改动的性能归因与安全/诊断边界由专项分析处理，未来配套模块不应将其混入默认优化。

本文确认的是静态消费者、参数语义和候选合理性；**所有性能收益均未经固定 HyperOS OTA 真机对照验证**。下一步由用户选择候选，再准备对应单项、可回滚的实验方案。
