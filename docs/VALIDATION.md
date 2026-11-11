# 当前基线与验收

当前源码基线为官方九月 r15 / Linux 6.12.92 / KMI 6，仅交付 4 KiB；Rust Binder 内置，C Binder 关闭，ROM 同名模块被屏蔽。KernelSU `dbb73665` 与 SUSFS v2.4.0 `395a8c0c` 新候选已通过完整 CI 并交付 Telegram，状态为 `awaiting-device`，尚未经实机验收。用户于 2026-11-08 确认 `6.12.92-android16-luna-g1d3c30f1-4k` 在 `OS4.0.6.0.XPCCNXM` 上完成严格实机验收；同日只读核对确认设备运行身份一致。

已验收项目提交为 `1d3c30f1945ad2c70bbf084886339649b3017123`，使用 KSU `51c21786`（32712 / UAPI 6）、SUSFS `6b60a30`、BBG `028ff7f`、Clang r596125 / LLVM 22 与 Rust 1.97.0-dev。验收记录绑定该提交与下述 Image 摘要。

对应构建审计保存完整配置、模块、导出及 STG 快照。r11 的官方 `dw_pcie_rp` 位域变化已审查，不影响当时固定 OTA 的消费者类型图；两个 C Binder tracepoint 没有目标消费者，保持未导出。历史版本的差异和排查过程从 Git 历史检出。

LLVM 23 不在当前基线中：此前实测 `net_ns_type_operations` CRC 从 `1cffd49b` 变为 `5cd5fc70`，gendwarfksyms 类型串存在分隔符差异，不满足固定 OTA 闭包。保留已验证的 LLVM 22 配对；未来升级必须重新证明兼容性。

AutoFDO 的官方单路径增广参数已消除当前输入下 `filemap.o` 的异常编译耗时，实际 C/Rust 参数独立审计。具体策略见 [BUILDING.md](BUILDING.md)。

## 当前待验候选

构建提交为 `d004b436eb09726443dcaf9e2f81a1f4bb0ee2e7`，使用正式 r15 / `4d7e81fff9326105dd9fc69cd7b7a07f7164fbd1`、KernelSU `dbb73665`（32727 / UAPI 6）、SUSFS v2.4.0 `395a8c0c`、BBG `028ff7fd`。本轮精简组件适配，恢复 SUSFS 官方完整 SELinux 隐藏链并保留已确认安全修复；另回移 12 个官方小米 vendor hooks/ABI 提交，新增 14 hooks、28 项 vendor symbol-list、42 个实际 GPL 导出，不内置厂商策略、不宣称实测性能收益。回移共 70 个逻辑项、40 个独立项。

固定制作输入为 `916353e9b3417be4a3315c67c9bf07d31bd9b023`，资产为 [ci-deps-v1-916353e](https://github.com/LunaKernel/ci-dependencies/releases/tag/ci-deps-v1-916353e)。官方来源审计、真实发布地址消费、40 组有序 index 闭环、应用幂等和精确源码门禁通过；本地轻量检查通过 104 项测试及 actionlint，[Check #43029807990](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/43029807990) 成功。

[Build Luna Kernel #43029955349](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/43029955349)，attempt 1，事件 `workflow_dispatch`，分支 `main`，完整 SHA 为上述构建提交；build 与 notify 均成功。artifact ID 为 `13858869704`，名称 `luna-d004b436-43029955349-1.tar.gz`，大小 54,326,081 字节；原始下载归档为 TAR，SHA-256 与 API digest 均为 `38a59f8d0bab56660ec03113bda2761fe33eebad3c3d17046a9b6a9fc38ca681`。

build job 用时 6 分 32 秒，其中固定输入初始化 34 秒，补丁应用/编译/审计 4 分 39 秒；notify job 用时 12 秒。ccache、固定下载、官方 Manager、干净 common、回移包及工具链安装缓存均恢复成功。

固定 OTA 的 4090 项完整 tuple、103 项模块顺序、vermagic、内置 Rust Binder 替代和 stock 同名模块屏蔽全部通过；配置、全量导出与 STG 参考全部 MATCH，`drift_count=0`。此前运行 `43027118643` 的漂移已逐项审查：42 个新增导出精确对应 14 tracepoint、14 traceiter、14 static-call key，旧导出的 CRC/provider/export class/namespace 和旧 STG 类型记录不变；已据实更新参考，未放宽目标闭包。机制及原始提交见既有质量与吸收清单。

完整六文件交付已通过项目导入器校验，保存于 `kernel_out/luna-xiaomi17-gd004b436-20261111-2132/` 及同名 `work/audit/`、`work/components/`。原始 Image SHA-256 为 `a2471f75abd23d52c47389b036889fdb4f696414f767bbda637d5e77ebe35938`，AK3 ZIP SHA-256 为 `dac583233b35d89c1b065f96002fc899fcbf3799eb9053df0fcc66ad38e78612`；官方 Manager APK SHA-256 为 `cb6d4d95f8e0411e8822cb5e6d02c597bedfa031d5138867e9cd2b69f678030a`。同次 CI 日志保存在对应审计目录。

Telegram 已发送内核 ZIP（message_id `25`）和官方 Manager（message_id `26`），与本地交付身份一致。状态保持 `awaiting-device`，由用户在小米 17 `pudding` / Android 17 / `OS4.0.6.0.XPCCNXM` 上完成真机验收。

## 前轮待验候选（r15）

构建提交为 `17e768beb96781321725ab50c46bb48ea9d54aa0`，基线为正式 `android16-6.12-2026-09_r15` / `4d7e81fff9326105dd9fc69cd7b7a07f7164fbd1`，使用 KernelSU `dbb73665`（32727 / UAPI 6）、SUSFS v2.4.0 `395a8c0c`、BBG `028ff7fd`。MIDI、F2FS adjusted-write 与 FUSE interrupt/resend 已由 r15 完整吸收，删除重复清单及 pin；剩余 66 个逻辑项、36 个独立项。SUSFS 的 SELinux 代理正确接入当前 KSU 完整实现，保留有效 priority UID 功能及既有安全修复。

固定制作输入为 `0325895b318e295198c812a417132364ffb94127`，回移资产为 [ci-deps-v1-0325895](https://github.com/LunaKernel/ci-dependencies/releases/tag/ci-deps-v1-0325895)。全部官方来源审计、正式消费者应用/幂等/单项撤销/有序重放和精确差异验证通过；从真实发布地址下载并完成完整 `patches/init.sh`，固定工具链、NDK、Manager、AK3 与 OTA 输入均校验成功。标准轻量检查通过 104 项测试及 actionlint；[main 轻量 CI #42980391459](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/42980391459) 成功。

[Build Luna Kernel #42980392805](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/42980392805)，attempt 1，事件 `workflow_dispatch`，分支 `main`，完整 SHA 为上述构建提交；build 与 notify 均成功。精确 artifact ID 为 `13837306974`，名称为 `luna-17e768be-42980392805-1.tar.gz`，大小 54,301,985 字节；原始下载归档为 TAR，SHA-256 与 API digest 均为 `010878cc3705581445f6677448f023aaf62e7193d84c43659acc80955109a2fb`。

build job 用时 5 分 51 秒，其中固定源码/工具初始化 30 秒，补丁应用/编译/门禁 4 分 14 秒（内核构建及审计 3 分 46 秒）；notify job 用时 15 秒。ccache 从 `42978497856-1` 恢复，固定下载、官方 Manager、干净 common、回移包及工具链安装缓存全部恢复成功。

固定 OTA 的 4090 项 vmlinux 依赖及完整 tuple、103 项模块顺序、模块 vermagic、内置 Rust Binder 替代及 stock 同名模块屏蔽全部通过。配置、全量导出与 STG 参考全部 MATCH，`drift_count=0`。此前运行 `42975584587` 暴露的旧输入钩子调用已按新官方静态键路径修复；运行 `42978497856` 中的 VFIO platform 全量漂移已审查，受影响五符号无目标 OTA 消费者。具体机制及证据见既有质量与吸收清单。

完整六文件交付经项目 `release_artifacts.import_archive` 校验导入 `kernel_out/luna-xiaomi17-g17e768be-20261111-1533/`，审计与原始 `release.tsv` 位于同名 `work/audit/`。Image SHA-256 为 `02d86d96aeac84d93b4d8541e3f297b9fff6dfa285e0bded0c6888a67dc4b4c4`，AK3 ZIP SHA-256 为 `6b494bd9a4a60559f5e8c08b046a7ce45e6724b3d036c139936e193a2f1ec286`。官方 Manager 为 `KernelSU_v3.3.1-47-gdbb73665_32727-release.apk`，SHA-256 为 `cb6d4d95f8e0411e8822cb5e6d02c597bedfa031d5138867e9cd2b69f678030a`。

Telegram 已发送 AK3 ZIP（message_id `23`）及官方 Manager（message_id `24`），发送日志与本地交付身份一致。状态保持 `awaiting-device`，由用户在小米 17 `pudding` / Android 17 / `OS4.0.6.0.XPCCNXM` 上完成真机验收。

## 前轮待验候选（r11）

构建提交为 `92d26a486b9a2696b96c6db14b7fda3b2626b92a`，使用 KernelSU `dbb73665`（32727 / UAPI 6）、SUSFS `6b60a30`、BBG `028ff7f`，新增 FUSE interrupt/resend UAF 官方不可拆双提交链。r15 的 F2FS 读取权限缺口与 SUSFS v2.4.0 SELinux 回归尚未修复，继续保留 r11 与 SUSFS v2.3.0；审查依据见既有质量和吸收清单。回移总计 69 个逻辑项、39 个独立项，包含此前 MIDI 与 F2FS adjusted-write 修复。

固定制作输入为 `247b4508c648e2f18e91cc055708b2b5aff2d325`，新回移资产为 [ci-deps-v1-247b450](https://github.com/LunaKernel/ci-dependencies/releases/tag/ci-deps-v1-247b450)。官方来源审计、正式发布地址消费、完整应用/幂等/单项撤销/有序重放通过；最终 FUSE 源码与官方 blob `efd9e26dfd9a6e522d1ac367e3670a299293a8be` 一致。最终标准轻量检查通过 104 项测试及 actionlint；[main 轻量 CI #42964358695](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/42964358695) 成功。

[Build Luna Kernel #42964371049](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/42964371049)，attempt 1，事件 `workflow_dispatch`，分支 `main`，完整 SHA 为上述构建提交；build 与 notify 均成功。精确 artifact ID 为 `13830762242`，名称为 `luna-92d26a48-42964371049-1.tar.gz`，大小为 54,294,178 字节，原始下载归档与 API digest 均为 SHA-256 `361b88b504e8b7788e1f8a0d52ad5a92ba34663f7c40cca7d72c6f516124d7d2`。

build job 用时 5 分 27 秒，其中固定源码/工具初始化 38 秒、补丁应用/编译/门禁 3 分 37 秒；notify job 用时 14 秒。ccache 从前轮 run `42498495826-1` 恢复，干净 common 与工具链命中缓存；新下载、Manager 和回移包首次未命中，验证后已保存。4090 项固定 OTA vmlinux 依赖及完整 tuple、活动模块 vermagic、内置 Rust Binder 替代及 stock 同名模块屏蔽通过；配置、模块顺序、全量导出与 STG 快照全部 MATCH，`drift_count=0`。

完整六文件交付已通过项目 `release_artifacts.import_archive` 校验并导入 `kernel_out/luna-xiaomi17-g92d26a48-20261111-1313/`；审计与原始 `release.tsv` 位于同名 `work/audit/`。Image SHA-256 为 `7d5c72c0d2eba66b78137f64dad60a2d6f1d8d51a2239073148c1b88429c070a`，AK3 ZIP SHA-256 为 `4c95d12bf2cd1550fa770c8af9fa39f0df1f3fb3ccdf45ae803c462320fb0f2e`。官方 Manager 为 `KernelSU_v3.3.1-47-gdbb73665_32727-release.apk`，SHA-256 `cb6d4d95f8e0411e8822cb5e6d02c597bedfa031d5138867e9cd2b69f678030a`。

Telegram 已发送 AK3 ZIP（message_id `21`）及官方 Manager（message_id `22`），notify 日志与本地交付身份一致。状态保持 `awaiting-device`；本候选尚未经真机验收，最后由用户在小米 17 `pudding` / Android 17 / `OS4.0.6.0.XPCCNXM` 上完成，不沿用历史 `accepted` 结论。

## 更早待验候选

构建提交为 `7b083693b7957f8036f94d804ca3ddd418c8f2f6`，使用 KernelSU `730f6446`（32718 / UAPI 6）、SUSFS `6b60a30`、BBG `028ff7f`，并新增 USB MIDI IN request UAF 与 F2FS adjusted write range 官方回移。目标仍为小米 17 `pudding` / Android 17 / `OS4.0.6.0.XPCCNXM`。

[Build Luna Kernel #42498495826](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/actions/runs/42498495826)，attempt 1，事件为 `workflow_dispatch`，分支为 `main`；build 与 notify 均成功。精确 artifact 为 `luna-7b083693-42498495826-1.tar.gz`，下载原始归档 SHA-256 为 `399bd65a7bd87b445163f826f2d55e0a377e5f03dc2ef5e1d91ca894d9decafd`。固定 OTA 的 4090 项 vmlinux 依赖及完整 tuple、活动模块 vermagic、内置 Rust Binder 替代和 stock 同名模块屏蔽门禁通过。

完整产物已通过项目导入器校验并保存于 `kernel_out/luna-xiaomi17-g7b083693-20261109-0010/`；审计与原始 `release.tsv` 位于同名 `work/audit/`。Image SHA-256 为 `941c8d42ee9b3660e40bc2375663aca0aa05ebb7606752c4aa41565f859a990e`，AK3 ZIP SHA-256 为 `457faeb5b0c4bf53d5c5126f60f214b7ca7e82eeed8fc6bbe05bfdc9dd8c6275`。配套官方 Manager APK SHA-256 为 `dfc005ebe0eed0b755872e4af2ebab6edf6aa551abd088e4341669474f745986`。

本轮用户明确授权先 Telegram 交付、后置真机验收。Telegram 已发送 AK3 ZIP（message_id `19`）和官方 Manager（message_id `20`）；当前状态保持 `awaiting-device`，后续真机验收由用户完成。下述历史已验收基准不替代本候选的验收。

## 已验收基准

Image、AnyKernel3 ZIP 与配套官方 Manager APK 位于 `kernel_out/luna-xiaomi17-g1d3c30f1-20261031-0332/`；完整构建审计、交付清单和 `accepted` 状态位于同名 `work/audit/` 目录。Image SHA-256 为 `2bdae1def07346f10da42449130fa00f26a660eabf2415198a9c671464b9f124`。

实机为小米 17 `pudding` / Android 17。身份与启动完成记录位于 `evidence/device/luna-xiaomi17-g1d3c30f1-20261031-0332/`，由 `SHA256SUMS` 校验；严格功能验收由用户确认。

原构建审计针对 `.9` OTA，保持其原始含义。新基线 `OS4.0.6.0.XPCCNXM` 的四镜像、payload 元数据及补充核验记录位于 `evidence/os4.0.6.0/`，大小和摘要逐项匹配同包 manifest，system_dlkm 的 AVB/EROFS 完整性通过。

复用与交付 Image 完全相同的构建缓存完成新 OTA 静态核验：678 个去重模块中 677 个严格闭包，唯一 stock Rust Binder 单独按内置替代审计；4090 项 vmlinux 依赖无缺符号、CRC 或 provider 错误，模块 namespace、GPL 导入及依赖图检查通过。相对旧清单新增 8 项、移除 1 项，共有接口 CRC 未变。stock Rust Binder 的 240 项需求完整保留（166 项匹配、74 项构建上下文符号缺失，无 CRC/provider 异常）；该模块由内置 Rust Binder 替代，模块屏蔽及无 C 初始化函数的证据均通过。

新 4090 项接口及全部可达类型图，从原完整 STG 归档与同 Image 的 vmlinux 两路提取后逐字一致，SHA-256 为 `bfae072ca3f63c7ccbe7526aaea2187f77734e100f3e51c6fb6824f56c8a4654`。本次未重新编译内核，也未改变其配置或优化参数。

历史问题与排查记录保存在 Git 历史和 `evidence/`。每个新 Image 按以下流程独立验收。

## 后续验收

每个新 Image 完成构建门禁后，状态为 `awaiting-device`。实机应记录 uname、/proc/version、boot completed、活动槽、bootconfig/cmdline、模块加载、Binder、BPF、SELinux/LSM、KernelSU/SUSFS/BBG 与 IPSet，以及 dmesg、logcat、pstore。

拒绝 panic、Oops、watchdog、关键模块 ABI/CFI/BTF 加载失败和持续严重硬件错误。环境隐藏的 green/locked 属性须结合 bootconfig 判定；获准 root 的 Seccomp: 0 与普通应用 Seccomp: 2 分别核实。

只有用户确认验收后才将该产物状态改为 `accepted`。第四套内核验收后清理最旧内核产物。工作审计（含日志、失败快照）与配套组件分别自动保留最新三份；外部 `evidence/` 不参与自动清理。
