# 官方 AutoFDO 与低开销回移

本轮以项目 `3ecabf887690a000de0fe2f767ad5b358e210a75` 的源码、Image 与完整验证快照为对照，保持 Linux 6.12.92 / KMI6、固定 HyperOS 4 OTA、组件和工具链。目标是减少完成同样工作的开销，保证基础流畅性并略偏省电；不调整调频、温控、回收参数或安全/诊断能力，不宣称未经测量的续航或整机加速。

## 官方 profile

使用固定 common `0316e9866fdf55601aae97b14ee08d1b38a3916c` 自带的 `gki/aarch64/afdo/kernel.afdo`：4078600 字节，SHA-256 `9a4d8b3859ea48b4ac51960f70ebe7d7f008f3680342289ef318a8c30d8aac02`。文件身份由 `.env` 固定，不下载另一个 profile。

该提交的 README 记录 profile 由 Google 在 Pixel 10 的 6.12.90 内核上采集，覆盖热门应用启动和操作；官方 `kernel_aarch64` 构建明确传入该文件。它不是小米的实测 profile，Pixel 基准不能外推为本产品收益。[AOSP 官方说明](https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/gki/aarch64/afdo/README.md)

此前 Luna 只有 `CONFIG_AUTOFDO_CLANG=y`，实际 C/Rust 命令没有 sample-use 参数，未使用此 profile。现在统一 make 参数显式传入固定绝对路径的 `CLANG_AUTOFDO_PROFILE`，继续使用 `LTO_NONE`。不需要用户先采样，也不要求改变内核或模块交付边界。官方 profile 的 symbol-list section 为空，未增加 sample-accurate 参数，不把项目新增函数缺少样本视为明确冷路径。

`init.sh` 校验现有文件摘要；`build.sh` 在任何 make 编译前校验摘要、固定 Git blob 身份和固定 LLVM 的读取能力。缺失、错误路径、错误 pin 或无法读取均失败，不静默退回普通编译。构建后检查调度、页缓存、F2FS NAT 和 Rust kernel 实际 `.cmd` 的 sample-use 参数，并随兼容性审计包保存 profile 身份、格式信息和完整命令。

## 两个官方回移逻辑项

| 项目 | 官方主线提交 | 保留理由 |
| --- | --- | --- |
| 页缓存读取 | `e1c345582c979ed44f881dec0b3137d862097c6b` | 读取最后需要的 folio 后退出，省去额外 XArray 查找；保留 RCU、引用获取和重试、uptodate/readahead 边界。空范围仍返回空 batch。 |
| F2FS NAT 变脏链 | `0349b7f95c806ea30d558c7fec9502f4470fb1b6` → `40aa9e1223fd38e65ac72373e642c7638a3b4752` | `/data` 的 NAT 变脏路径避免无效 clean LRU 移动；新条目避免先插入 clean list 再转移。配套修改计数与自链表初始化，保留现有条目和 checkpoint/flags 语义。 |

三个提交均从本地固定的 Linux 官方主线审计仓库取出，原样应用，没有上下文适配。页缓存作者 Chi Zhiling，Andrew Morton 合入；NAT 作者 wangzijie，Chao Yu 评审、Jaegeuk Kim 合入。分别进入 630/640 独立清单并固定 SHA-256、完整提交、日期、patch-id 与路径；NAT 链同清单顺序应用、逆序撤销。直接回移现在为 63 个逻辑项，独立清单为 33 个；质量清单增加这两项和 AutoFDO，共 98 条记录。

NAT 静态审查核对两个立即变脏入口的 `for_dirty`；新条目只增加 TOTAL，然后增加 DIRTY，不错误减去尚未增加的 RECLAIMABLE；既有 clean/dirty 和 NEW_ADDR 路径继续正确计数及维护链表。后续 `238e14eb`、`019f9dda`、`7633a738` 处理既有 checkpoint/atomic 标记竞争，其 Fixes 指向更早的实现，不是本次 NAT 优化引入的回归；本轮不混入这些清单外候选。

固定 mainline/stable/AOSP 历史及当前 common 中未识别针对这三个提交的回退或补修。小量远端补充检索找到 F2FS 维护者的接受记录，但最新路径日志请求未能取得完整结果，不能声称已穷尽固定审计点之后的所有历史。风险判断来自当前路径、锁/引用/计数机制和已合入官方历史，仍需构建与实机验收。

两项均只改变内部实现，不改变配置、UAPI、syscall、公开结构或磁盘格式。MGLRU `526660b950a4` 暂不纳入，避免为少量检查增加维护层；其它条件性调优不随本轮接入。

## 验证与发布

脚本语法、差异检查、官方来源、独立项单独应用/撤销、顺序重放与脚本幂等性必须通过。完整源码重放从固定 common/KSU/BBG 提交开始，逐层重现最终文件与链接；本轮重放覆盖 common 98、KSU 29、BBG 4 个文件/链接，共 740 处最终差异块，最终字节及链接目标均精确匹配。逐块归属文件摘要为 `695523ecf64a45c1346e68751d2002ffcaacdcaac806606136be956cba4cdd18`。旧证据和本轮原始结果存放于 `kernel_out/autofdo-backport-audit/`，不得提交源码树、日志或产物。

复用既有输出和只读 ccache，不 clean/mrproper。AutoFDO 改变多数内核对象的编译参数，一次必要重编译无法用普通小增量替代；所有改动合并验证，避免逐补丁编译。

构建必须通过固定 4083 项 OTA tuple、102 个严格 system_dlkm 模块与精确 Rust Binder 167/67 例外，保持关键配置、LSM 和 Image-only 边界。消费者 STG 单独比较，完整快照漂移必须保留、审查后才更新参考；不得通过关闭门禁来完成打包。候选提交在固定 OTA 上的真机启动、功能、流畅性和功耗验证仍是发布条件。
