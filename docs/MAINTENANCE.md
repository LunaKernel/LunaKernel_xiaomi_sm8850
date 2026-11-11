# 常规维护流程

适用于 GKI 基线更新、回移清理和外部组件更新。先阅读 [项目约束](PROJECT_RULES.md)、[构建说明](BUILDING.md) 和 [贡献说明](CONTRIBUTING.md)。主仓、[固定依赖仓](https://github.com/LunaKernel/ci-dependencies)及 [extra-modules](https://github.com/LunaKernel/extra-modules)分别维护消费、制作和模块模板。

常规维护以更新 GKI 基线及依赖、补丁版本为核心目标，优先采用上游完整实现，以最小必要改动完成集成，并清理随升级失去用途的回移和适配。

完整流程为：固定本轮目标 → 更新基线与清理回移 → 更新外部组件 → 制作固定依赖 → CI 构建与 Telegram 交付 → 用户真机验收。

## 1. 准备

1. 检查相关仓库的工作区、分支和远端提交，保护已有改动，记录上次已验收的提交与产物身份。
2. 按本轮授权执行提交、推送、依赖发布与 CI。设备操作与真机验收由用户负责。
3. 本地完成源码审查、补丁演练、来源审计、归档制作和轻量检查；内核、模块及配套工具的实际编译在 GitHub Actions 完成。
4. 在主仓根 `.env` 统一维护 pin；该文件是已授权维护的公开配置。
5. 按逻辑单元提交，使用 Git 历史回退。源码、pin、快照与相关文档在最终测试前同步。

更新受阻时，区分源码、输入和环境原因，根据失败证据尝试解决。数次有依据的尝试仍无果后，停止并汇报原因、已尝试方案、验证结果及未完成目标。

## 2. 选择最新已发布 GKI

从 [官方发布页](https://source.android.com/docs/core/architecture/kernel/gki-android16-6_12-release-builds)枚举已发布、未取消条目，核对构建编号、发布日期与官方源码标签。

候选须满足 `android16-6.12`、Linux `6.12.x`、KMI generation 6 和 4 KiB，分别核对 `Makefile`、`build.config.constants` 与官方构建记录。

官方正式发布版本所包含的补丁视为可信上游内容。

按 Linux 版本号、`rXX` 修订号依次数值降序选取。例如 `6.12.92 r13` 高于 `6.12.81 r41`，同版本内 `r13` 高于 `r11`。

1. 查询官方标签及其 `^{}` 解引用结果，在 common 仓库用 `git rev-parse '<tag>^{commit}'` 得到源码提交，将完整 commit SHA 写入 `COMMON_COMMIT`。核对对象类型为 `commit`，检出后确认 `HEAD` 与该 pin 一致。
2. 同步脚本默认值、版本断言、源码和缓存路径、AutoFDO 身份及相关文档，核对工具链要求。将 `KERNEL_BUILD_TIMESTAMP` 及脚本默认值同步为新 common 的 `git show -s --format=%ci <commit>`。
3. 记录标签、完整源码提交和查询结果，准备 common 源码及审查所需历史。复用已核验的来源缓存，缺失时通过项目或依赖仓的准备入口获取；后续审查、依赖制作与验证使用这组固定输入。

## 3. 审查并清理全部补丁

先审阅新旧 common 之间的提交和源码差异，再从实际应用入口和当前清单枚举完整补丁集合，包括：

- `patches/patch.sh` 的 selected、independent、旧式回移及 Kbuild 回移。
- `patches/patch_external.sh` 的 KMI、SUSFS、KernelSU、BBG 接入和复制文件。
- 依赖仓 AK3 上游模板与 Luna 定制，以及配套组件适配。

逐项结合提交关系、patch-id、最终源码、后续 revert、配置和实际调用路径判定：

| 结论 | 操作 |
| --- | --- |
| 完整吸收 | 删除重复补丁及失去用途的 pin、适配、检查分支 |
| 部分吸收 | 重新整理完整逻辑链，验证剩余前置关系和顺序 |
| 被上游新实现替代 | 使用新实现，清理旧补修 |
| 仍然需要 | 保留来源、目标路径和适用依据 |
| 不适用、有错误或已无实际作用 | 删除并记录简短理由 |

性能项结合机制、生成代码和已有实测评估价值。

将来源、逐项判定和本轮验证结果写入既有清单，注明对应 common 提交，同步数量、版本、路径及实际编译对象。完整补丁集合在第 5 节完成消费验证。

## 4. 更新外部组件

从已采用的官方渠道查询各组件最新候选，与现有 pin 逐项比较，选定并固定本轮目标后准备对应源码：

| 组件 | 上游渠道 | 联动检查 |
| --- | --- | --- |
| KernelSU | `tiann/KernelSU` 的 `main` | 版本、UAPI、签名、preinit 和官方 Manager |
| SUSFS | `simonpunk/susfs4ksu` 的 `gki-android16-6.12` | common 与 KSU 补丁来自同一提交 |
| Baseband Guard | `vc-teahouse/Baseband-guard` 的 `main` | common 接口、KSU 凭据标记与 LSM 接入 |

逐个组件审查版本并按上游实现集成，保留必要的兼容适配和项目定制。清理已吸收的旧适配，沿实际调用链核对既有修复是否生效。

长期定制见 [项目约束](PROJECT_RULES.md#2-来源与改动边界)；逐轮复核临时措施，随上游修复清理重复层。

Manager 选用匹配新 KSU 源码、UAPI 和签名要求的官方 CI 产物，固定 run/artifact、摘要与证书，并完成现有验证。AK3 或 extra-modules 有相关更新时，在所属仓库审查并制作固定输入。

## 5. 制作固定依赖与冻结候选

1. 主仓提交新来源 pin、补丁清单和适配，作为固定制作输入。
2. 按 [依赖仓 README](https://github.com/LunaKernel/ci-dependencies#readme) 从该提交的 Linux LF 检出完成官方来源准备、完整审计和本地制作。仅回移包变化时使用其增量制作入口，复用未变的工具链、AK3 和 OTA 资产。
3. 在干净环境使用正式消费者复核包摘要、manifest 输入绑定和实际内容，逐项核对 `COMMON_COMMIT` 及补丁清单身份与本轮制作输入一致。使用完整 `patches/patch.sh` 和 `patches/patch_external.sh` 完成应用、幂等、撤销、重放及最终源码差异验证。
4. 发布新版本并保留旧资产；主仓回填真实 URL、归档与 manifest 摘要及必要的安装树摘要。从实际发布地址下载，运行 `patches/init.sh` 验证源码与固定依赖能共同完成初始化；固定输入与本地制作结果一致时复用已完成的补丁验证。
5. 完成相关文档与清单修正，执行 `git diff --check` 和 `bash tools/ci/check.sh`（含语法、单元测试与 actionlint）；制作工具变更时执行依赖仓既有轻量检查。通过后提交消费候选并核对工作区。

回移包绑定 `COMMON_COMMIT`，切换 common 后重新制作。provenance 记录制作输入提交；消费 URL/SHA 回填或不影响包输入的文档修改复用原资产。

复用已核验的 `--work` 来源缓存，临时检出与输出另放目录。使用已提交的 LF 内容，记录可复用缓存的 Linux 路径及 WSL 发行版。

验证结果绑定提交与输入；相关输入变化或出现新问题时，重跑受影响检查。

## 6. CI 构建与 Telegram 交付

在 main 手动派发 `build.yml`，执行完整构建、审计、打包与产物上传。build 通过构建与交付门禁后，由 notify 发送内核 ZIP 和官方 Manager 到 Telegram。

记录 run ID、attempt、工作流、事件与完整项目 SHA，持续监控至完成。失败按原因处理：

- 网络或 runner 临时故障：相同输入重试。
- 源码、补丁或依赖问题：修复并提交后重新测试。
- 参考快照 DRIFT：审查保存的差异，更新参考后重新测试。
- 目标 OTA 闭包或关键功能不兼容：修复后再进入发布。

成功候选在 `release.tsv` 中记录为 `awaiting-device`。记录 run URL、关键阶段耗时、缓存命中、精确 artifact、原始 Image SHA-256 和 Telegram 交付结果。代码或构建输入变化后，以新提交重新构建。

通知失败时，在 artifact 有效期内重试 notify，复用同次成功构建的产物；部分发送或响应丢失时先核对交付情况。

## 7. 用户真机验收

Telegram 交付后，由用户按 [真机验证规则](PROJECT_RULES.md#6-真机验证)完成验收，绑定交付 run/attempt/artifact、完整项目提交、原始 Image SHA-256 和目标 OTA。

用户验收通过后，在 [验证记录](VALIDATION.md) 中将对应候选记录为 `accepted`，保留原始构建与产物引用，单独提交验收文档。详细设备日志留在原有证据位置。

以更新目标达成、CI 与 Telegram 交付成功、用户验收通过作为本轮维护完成条件。

## 8. 执行与收尾

按阶段推进。同一候选由一个执行者负责推送、CI 派发与重试；交接时提供仓库路径、授权范围、固定提交、文件归属、已完成验证及剩余事项。

制作命令归依赖仓 README，补丁结论归既有清单，运行证据归 CI。清理本轮自建且无用途的临时文件，保留来源缓存与验收资料。

结束时核对相关仓库状态，按本轮目标逐项报告基线、依赖和补丁版本的更新结果或受阻情况，以及提交、运行与产物链接、验证结果和待验信息。
