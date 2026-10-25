# 维护与回移

当前工作分支为 `feat/kmi6-2026-09-r8-rust-binder`，基于官方 `android16-6.12-2026-09_r8`（Linux 6.12.92 / KMI generation 6）。`chore/kmi6-2026-09` 保留上一验收状态；`main` 和 `os3-android16-6.12.23` 保留历史，不重写 Git 历史，不为已有历史另外留备份。

## 来源与审计

内核层次为固定 AOSP common、`patch.sh` 的官方直接回移、`patch_external.sh` 的独立组件及最小兼容层、`build.sh` 的配置与发布检查。来源 pin 与快照以 [`.env`](../.env) 为准。

KernelSU/SUSFS 使用 2026-10-26 核实的官方 main / 对应 6.12 分支快照。最新 KSU 的 kernel、UAPI tree 与 SUSFS 明确同步的提交完全相同；BBG main 未变化。组件吸收与保留依据见 [`3ff9fd3-absorption.tsv`](../patches/susfs/3ff9fd3-absorption.tsv)。先审查残差并证明独立重放，再更新源码、pin 和构建；不能通过重复覆盖修正或扩大允许路径隐藏新差异。

[`patches/backports/`](../patches/backports/) 中保留吸收证明、质量审查和有序回移清单。selected 集合不可拆分；independent 中每份清单只含一个逻辑项，官方不可拆的前置/补修链同清单。新增项须固定来源、完整 commit、日期、patch-id、路径及适配补丁摘要，并证明固定基线缺少该改动、上游无明确回退或回归。

通过临时 Git index 验证单项应用、撤销与完整顺序重放。最终源码字节及链接目标必须与真实补丁流程一致；允许路径、patch-id 或“能够应用”均不能替代逻辑与差异审查。不得把未编译对象计作有效功能。

SM8850 编译链已审查的 Rust 自动导出、私有 DWARF 和非消费者 KCFI 漂移保留在 Git 历史；现行完整快照随每次构建审计归档。固定 OTA 消费接口、相关类型及 CFI 必须兼容，完整快照漂移必须保留、审查并同步刷新参考。

## 提交与验收

提交标题为 `<type>: <准确精炼中文描述>`，类型限 chore、feat、fix、refactor、docs。来源、功能、启动门禁、完整差异审计、打包及文档分开审查。直接回移在正文注明完整上游 commit、实际移植方式、接口影响和验证；独立逻辑项必须可独立回退。

提交前运行 `git diff --check`、相关脚本语法检查和与风险相称的验证。发布仍需完整构建、固定 OTA 模块闭包、镜像完整性、Image-only 打包检查及 [真机验收](VALIDATION.md)。目录或文档变化不能把旧 Image 改名为新提交产物。

本地保留现行工具、必要下载与增量缓存，不保留过时专题报告或重复转储。新发现直接在对话中说明；来源与构建门禁必需的结构化记录继续保留。`evidence/` 的外部 ROM、镜像及日志由用户手动清理。
