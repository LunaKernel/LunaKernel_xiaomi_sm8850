# 贡献与维护

变更面向小米 17 `pudding` / HyperOS 4 / Android 17。项目约束见 [PROJECT_RULES.md](PROJECT_RULES.md)，构建方法见 [BUILDING.md](BUILDING.md)。本文中的代码路径相对于仓库根目录。功能或基线变更应说明用途、来源及兼容性影响。

提交时请：

- 保持改动最小、可独立回退；提交标题采用 `<type>: <准确精炼中文描述>`，类型限 `chore`、`feat`、`fix`、`refactor`、`docs`。
- 对上游回移保留完整来源、commit、patch-id 和实际适配方式，不改写上游归属。
- 不向主仓提交源码缓存、工具链、ROM/分区镜像、日志、构建产物或设备数据；固定 OTA 镜像由依赖仓 Release 托管，init 下载校验，仅用于兼容性校验，不进入刷机包。
- 本地至少运行 `git diff --check` 和相关 shell 语法检查，可执行 `bash tools/ci/check.sh` 轻量检查；与风险相称的完整构建及目标 OTA 模块闭包验证统一在 CI 执行。
- 在合并请求中列出验证结果与覆盖范围。

## 来源与回移

内核改动经 `patches/patch.sh` 接入官方 AOSP/Linux 回移；独立组件与必要兼容层由 `patches/patch_external.sh` 接入。源码、工具、配置身份和参考摘要统一维护于 `.env`。依赖制作和来源审计在 [ci-dependencies](https://github.com/LunaKernel/ci-dependencies) 完成；主仓库负责固定包消费与实际构建。

[`patches/backports/`](../patches/backports/) 固定来源、顺序、吸收证明和质量审查。selected 集合不可拆分；independent 每份清单只含一个逻辑项，不可拆的官方前置/补修链放在同一清单。新增回移须固定完整 commit、提交者日期（`git show -s --format=%cs`）、patch-id、路径及适配摘要，核实基线缺失、目标路径相关且无明确回退或回归证据，并用临时 Git index 证明单项应用、撤销及完整顺序重放。

更新外部组件时，按上游设计意图和完整调用链审查项目差异，优先保留完整上游实现，仅做必要适配和有缺陷证据的修复。

KernelSU/SUSFS 按 [集成边界](PROJECT_RULES.md#2-来源与改动边界)配套集成，清理已吸收补修；同步核对官方 Manager 的版本、UAPI 和签名兼容性。

固定 OTA 模块实际消费的接口、相关类型和加载条件必须兼容。全量配置、符号及类型快照的变化须独立审查并更新参考；不得以参考漂移为由放宽目标闭包。交付前完成镜像完整性和 Image-only 打包检查；Telegram 推送后，最后由用户完成 [真机验收](VALIDATION.md)。

main 的 push/PR 运行轻量 CI 检查，完整构建从 main 手动触发。新 Image 构建成功后为 `awaiting-device`。CI 产物与 Telegram 通知配置见 [构建说明](BUILDING.md#github-actions)。

## 许可证与记录

提交贡献即表示你有权提供该内容，并同意按该文件的现有许可证分发。不同许可证的第三方代码必须独立标明来源与许可证，不得通过复制代码规避兼容性审查。

历史状态由 Git 保留；仅保留来源、构建及验收所需记录，不另建重复备份或说明性报告。安全问题按 [`SECURITY.md`](SECURITY.md) 处理。
