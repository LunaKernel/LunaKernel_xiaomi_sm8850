# 九月 KernelSU / SUSFS 配套更新审计

## 固定来源

当前分支为 `chore/kmi6-2026-09`。AOSP Linux 6.12.92 / KMI6、固定 HyperOS 4 OTA、小米 SoC、BBG、IPSet 和工具链不变；直接修复仍是九月去重后的 62 个逻辑项。

| 组件 | 固定版本 | 选择依据 |
| --- | --- | --- |
| KernelSU | `623eba3e092b911a3a7389b7d87622a5835d2f3a`，`v3.3.0-50-g623eba3e`，32651 | [SUSFS 官方同步提交 acaa547](https://gitlab.com/simonpunk/susfs4ksu/-/commit/acaa54751730196129fc3da740da08447d6ee679) 明确配套该提交 |
| SUSFS common / KSU 兼容补丁 / helper | `b213c54126fb243595ce7876e91d84d6e0861fec`，v2.3.0 | 2026-10-05 查询的 `gki-android16-6.12` 分支头 |
| Baseband Guard | `a54e0dc6cf0aff4dd87fec49644a02d2eb612905` | 2026-10-05 查询的 main 分支头，项目保护层不变 |

KernelSU main 查询值为 `cd4af89c43005f33df91ba7cb66e00e67a4d0c1b`。本轮按已确认的决定固定 SUSFS 配套提交，不追到不匹配的更新版本；不能称为“所有开发分支都是最新”。KernelSU 完整 Git 计数为 2651，保持官方 `30000 + count` 版本计算、built-in、原有三处 BBG 授权凭据标记及全部安全门禁。

## Manager 与 UAPI

KernelSU UAPI 从 2 升到 4：3 引入 su-session driver FD，4 增加 bundled 标志。`GET_INFO` 四个 u32 的布局与 legacy 入口保留；SUSFS 官方层去掉 LKM/late-load 相关实现，本项目 built-in 不设置这些标志。app profile、授权、挂载策略和 FD wrapper 使用同提交用户态，未另行改写官方 UAPI。

Manager 来自同提交的[官方 Build Manager 工作流](https://github.com/tiann/KernelSU/actions/runs/35851273666)，`push/main`、`success`、head SHA 与 KernelSU pin 完全一致。使用最终重打包签名的 `manager` artifact `10745463923`，包含 arm64 ksud；没有使用中间 `manager-gradle` 或 PR 临时签名 APK，也没有本地编译 APK。

- ZIP：12893330 字节，SHA-256 `1d39b92d76cdfbf99d648acacb3ef398afa6f5aa5089614b580456bdabce0942`，与 GitHub artifact digest 一致。
- APK：`KernelSU_v3.3.0-50-g623eba3e_32651-release.apk`，SHA-256 `1c7cec1aa8a1d6bd023efdf31dd9f5fa5deb5e84acc904ae1b8e3a5097171b45`，manifest version code 32651。
- APK v2 签名块证书：长度 0x033b，SHA-256 `c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6`，与固定 KernelSU Kbuild 官方身份一致。

`.env` 固定来源、ZIP 和 APK 摘要；init 按提交缓存，已有正确 APK 时离线复用，否则用已认证 gh 获取固定 artifact 并验证工作流/提交/摘要。官方 artifact 有到期时间，过期且无缓存时应失败，不能改用来源不明的 APK。build 校验 APK 摘要与源码 UAPI 4，随候选产物交付。

## 补修吸收与剩余层

[完整上游提交清单](../patches/susfs/b213c54-upstream-commits.tsv) 覆盖 KernelSU 50 个和 SUSFS 26 个提交；[逐项逻辑审计](../patches/susfs/b213c54-absorption.tsv) 覆盖既有 common / KernelSU / BBG 修正、上下文及拒绝项。

三个补修已被吸收并删除：KSTAT 标记错误返回、KSTAT update 未命中释放、enabled_features 分配失败 NULL 解引用。cmdline 重试重复输出已进入上游；仍保留首次分配与读写互斥，避免并发首次分配漏失、指针竞争及输出内容混杂。其余输入边界、路径列表去重、KSTAT 完整键匹配、SUS_MAP 在 GUP 前查 VMA、日志默认关闭、fsnotify 引用清理及失败降级仍未完整吸收。

KSTAT 上游重构新增有效 statfs 与 proc fd 查询，沿用已有完整 inode/dev 键校验；statfs 同时核对 is_fuse，避免哈希桶碰撞串用条目。新 execve 上下文保留官方 `is_su_session` 与 post-execve 钩子，驱动 FD 安装跟随实际 su 会话结果。pkg_observer 的 free_mark、boot_event/dispatch 原子单次门闩及 sulog strscpy 修正仍需携带。必要的空白规范化用于通过源码 `git diff --check`，不计作功能修复。

RISC-V LKM、arm64 动态 syscall hook/patch memory、symbol resolver 等 object 被官方 SUSFS Kbuild 移除，相关上游修复不能计作本组合的有效功能。有效的 SELinux policy RCU/ebitmap/avtab 修复、Manager APK 扫描、授权 profile capabilities、FD wrapper/su-session 逻辑保留官方实现。KernelSU 不增加 LSM，BBG 仍占一个槽。

## OPEN_REDIRECT 继续关闭

[2a764bb](https://gitlab.com/simonpunk/susfs4ksu/-/commit/2a764bb08aa832aec6f87545c9c85467c5d1405f) 已修复 do_o_path/do_tmpfile 的悬空 nd->name；[cc99f24](https://gitlab.com/simonpunk/susfs4ksu/-/commit/cc99f24e67633686a45cb9ab37a652de4e7fdf83) 已在释放重定向 filename 前恢复旧 nd->name。path_init 的 ERR_PTR 由 link_path_walk 处理，不属于缺少错误检查。

但 b213c54 的 `susfs_open_redirect_spoof_vfs_readlink()` 在成功 copy_to_user 后仍返回 0；官方 vfs_readlink 钩子直接返回该结果。readlink 应返回实际复制字节数，短 buffer 应截断复制而非 ENAMETOOLONG。因此上游尚未完整修复，按已确认决定等待上游，不能恢复构建支持或以项目补修提前开启。配置与最终 object 符号守卫继续证明 OPEN_REDIRECT 未编入 Image。

官方 fdinfo 改动也仍不适用：inotify anon_inode 路径不能代表被观察挂载，三参数 callback 不兼容 FANOTIFY。继续排除整个 fs/notify/fdinfo.c 块，精确证明该文件为固定 AOSP 原样。

## 验证与交付边界

旧接入层先通过固定补丁 reverse-apply 和完整差异指纹证明，再逐项撤销；不 reset 源码，不改变直接回移层。新补丁先在临时源码树应用及撤销验证，再接入实际树；更新 SHA-256、patch-id、SUSFS 修正源码摘要与精确源码差异指纹。独立回移仍须逐项撤销、单项应用及完整重放。

本轮复用原 Git 对象、工具链和 `kernel_out/.build-kmi6-2026-09`，仅精准补取新提交与官方 Manager，不 clean/mrproper。干净项目提交增量构建执行固定 OTA 4083 项依赖 tuple、system_dlkm 镜像完整性、102 模块严格闭包、Rust Binder 精确 167/67 例外、关键配置、LSM 及功能 object 检查；本轮完整快照与漂移报告由构建审计归档保存。出现参考漂移必须先审查再更新 pin，零未确认漂移后才能打包。

旧完整快照及本轮取证保留在 `kernel_out/components-623eba3e-audit/`。所有包仍为候选，未 push、未刷机、未完成同 OTA 真机复测；需单独验证新版 su-session、Manager 授权、SUSFS/KSTAT/挂载隐藏、BBG、SELinux/LSM 和 IPSet。
