# 维护与回移

## 分支

- `main`：小米 17 HyperOS 4 / Android 17，AOSP r21 主线。
- `os3-android16-6.12.23`：HyperOS 3 / Android 16 历史维护分支。

不保留已经被 r21 完全取代的中间基线分支。旧私有仓库及其历史标签不属于公开仓库。

## 改动分层

内核改动按以下顺序生成：

1. 固定 AOSP common。
2. [`patch.sh`](../patch.sh) 中有明确官方来源的内核修复与改进。
3. [`patch_external.sh`](../patch_external.sh) 中固定版本的独立组件及最小兼容补丁。
4. [`build.sh`](../build.sh) 生成配置并执行目标 OTA 模块闭包和发布门禁。

不要把生成后的源码差异、`.config`、`Module.symvers` 或产物反向提交到项目。

## 回移记录

[`patches/backports/r21-selected-backports.tsv`](../patches/backports/r21-selected-backports.tsv) 是随基线整体携带的有序官方回移集合。

[`patches/backports/r21-independent/`](../patches/backports/r21-independent/) 中每个 TSV 只描述一个可独立回退的逻辑项。不可拆分的官方前置/补修链可以放在同一清单，但不得混入无关提交。

每条记录必须固定：

- 官方来源仓库与 ref。
- 完整上游 commit、日期、patch-id 和受影响路径。
- 必要时使用的项目适配补丁、SHA-256 与 patch-id。

新增回移前，应证明当前固定基线确实缺少该改动，检查上游后续修正或回退，并运行临时 Git index 的单项 apply、reverse、replay 与全量顺序重放。不能用“补丁能应用”代替逻辑审查。

## 提交

标题格式：

```text
<type>: <准确精炼中文描述>
```

`type` 只使用 `chore`、`feat`、`fix`、`refactor`、`docs`。官方回移在标题中注明来源，例如：

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
