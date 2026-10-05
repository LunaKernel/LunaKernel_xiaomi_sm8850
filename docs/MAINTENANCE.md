# 维护与回移

## 分支

- `main`：小米 17 HyperOS 4 / Android 17，历史 AOSP r21 主线。
- `chore/kmi6-2026-09`：九月发布分支迁移，Linux 6.12.92 / KMI generation 6。
- `os3-android16-6.12.23`：HyperOS 3 / Android 16 历史维护分支。

迁移审计见 [九月 KMI6 记录](KMI6-2026-09-MIGRATION.md)。旧私有仓库及其历史标签不属于公开仓库。

## 改动分层

内核改动按以下顺序生成：

1. 固定 AOSP common。
2. [`patch.sh`](../patch.sh) 中有明确官方来源的内核修复与改进。
3. [`patch_external.sh`](../patch_external.sh) 中固定版本的独立组件及最小兼容补丁。
4. [`build.sh`](../build.sh) 生成配置并执行目标 OTA 模块闭包和发布门禁。

不要把生成后的源码差异、`.config`、`Module.symvers` 或产物反向提交到项目。

## 回移记录

[`patches/backports/kmi6-2026-09-selected-backports.tsv`](../patches/backports/kmi6-2026-09-selected-backports.tsv) 是随基线整体携带的有序官方回移集合。

[`patches/backports/kmi6-2026-09-independent/`](../patches/backports/kmi6-2026-09-independent/) 中每个 TSV 只描述一个可独立回退的逻辑项，可包含不可拆分的官方前置/补修链，不得混入无关提交。

每条记录必须固定：

- 官方来源仓库与 ref。
- 完整上游 commit、日期、patch-id 和受影响路径。
- 必要时使用的项目适配补丁、SHA-256 与 patch-id。

新增回移前，应证明固定基线缺少该改动，检查上游后续修正或回退，并通过临时 Git index 执行单项 apply、reverse、replay 与全量顺序重放。不能用“补丁能应用”代替逻辑审查。

## 提交

标题格式为 `<type>: <准确精炼中文描述>`，`type` 限 `chore`、`feat`、`fix`、`refactor`、`docs`。官方回移需注明来源，例如：

```text
fix: 修复 IPv4 分片 MTU 下限校验（回移 Linux stable）
```

提交正文记录完整上游 commit、实际移植方式、接口影响和已执行验证。一个独立回移对应一个项目提交，确保可以单独审计和回退。

## 发布前检查

1. `git diff --check` 与所有 shell 语法检查通过。
2. 所有回移清单通过来源、单项撤销和顺序重放检查。
3. 完整构建、目标 OTA 模块闭包、关键配置和差异审计通过。
4. AnyKernel3 文件白名单、脚本摘要与 Image-only 边界通过。
5. 公共引用不包含密钥、日志、ROM/分区镜像、构建目录或历史预制 ZIP。
6. 真机完成与 [`VALIDATION.md`](VALIDATION.md) 一致的验收。

本分支全量补丁的必要性、跨层去重和实际构建路径审计见 [九月补丁质量审计](PATCH-QUALITY-2026-09.md) 与对应结构化清单；吸收证明不能替代保留理由。

后续接入的官方 AutoFDO、页缓存读取和 F2FS NAT 优化见 [接入与风险审查](AUTOFDO-2026-09.md)。profile 随固定 common 提供，由 `.env` pin 和构建实际命令共同验证；不要求额外下载或真机采样。它会改变大部分对象的编译参数，应合并安排必要重编译，不能以只开启配置开关代替接入。
