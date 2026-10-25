# 构建 Luna Kernel

使用 x86_64 Linux；macOS 通过已配置的 OrbStack Linux 执行相同流程。主机需要 Bash、Git、curl、tar、bzip2、xz、unzip、7-Zip、patch、Python 3、GNU coreutils 和常规内核构建依赖。源码与缓存占用数十 GiB。

所有 pin、构建身份和参考摘要以 [`.env`](../.env) 为准。固定源码的差异必须由补丁脚本精确证明；禁止手改构建配置、符号表或包内容绕过检查。

## 输入与流程

发布构建需要 `evidence/os4/system_dlkm.img`。构建校验固定 `.9` OTA 镜像的大小、摘要、AVB hashtree、EROFS 内容及 stock 模块清单；该镜像不进入刷机包。重建 stock 清单还需要同一 OTA 的 `boot.img`、`vendor_boot.img` 和 `vendor_dlkm.img`。

重建清单所用的原始固定 fsck.erofs、kmod 及其 libc++ 运行库保存在 `work/tools/stock-evidence/`；`init.sh` 按 Git blob 与 SHA-256 准备这三个文件，来源 pin 在 `.env`。

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

`init.sh` 复用并校验固定源码与工具；`patch.sh` 应用官方内核回移；`patch_external.sh` 接入已准备的组件，不下载；`build.sh` 编译并执行模块闭包、关键配置和独立快照审计，不准备源码。补丁脚本必须幂等。

## 编译策略

固定 AOSP Clang r596125 / 22.0.2、Rust 1.97.0-dev（LLVM 22）、bindgen 0.72.1、kernel build-tools、宿主 bc，以及 IPSet 使用的 NDK r30 / API 35。Clang、Rust 各自保留独立 LLVM 库，并验证官方 Git 对象、明确检出树与安装树摘要。

C 使用固定 `-march` 和 `-mtune=oryon-1`；Rust 使用 `target-cpu=generic`、`tune-cpu=oryon-1` 与固定 ISA 列表。全部参数在 `.env`；Kbuild 保持内核 SIMD 和分支保护约束，Rust 使用 softfloat，特性列表以 `-strict-align,-neon` 结束，允许普通内存非对齐访问；当前 Rust 对 strict-align 的不稳定特性警告保留。早期启动 C 的严格对齐保持原生规则。保留 O2、CFI、Rust inline helpers 与 `LTO_NONE`，以及上游已有的局部优化等级、汇编和链接布局。

Binder 仅使用内置 Rust 实现：`ANDROID_BINDER_IPC_RUST=y`，关闭 C Binder 及其专用 Binderfs 配置，Rust 驱动自行注册 Binderfs。该模式不需要 C 驱动解析 `binder.impl=rust`，也不同时内置两套同名 tracepoint。`module_blacklist=rust_binder` 只拒绝 ROM 中的旧 `.ko`，内置驱动通过 initcall 正常初始化。构建检查本次 `modules.builtin`、`modules.order`、`System.map` 和实际命令行；旧 `.ko` 的完整 234 项需求仍保留审计，其余 stock 模块继续严格检查 ABI/KMI，刷机包仍仅替换 Image。

QCOM/Xiaomi 全量参考清单与固定 OTA 的实际模块闭包分开检查。参考清单中的未导出项完整保留于审计，`vendor-kmi.full.tsv` 对应 CRC 记为 `-`；参考摘要变化仍阻止打包，必须审查并更新。实际模块需要的符号缺失、CRC、provider、导出类型或 namespace 变化仍立即拒绝。

C Binder 源码保留在固定 common 中，可用于重新构建回退版本。当前两套 tracepoint 对象含 111 个重复全局符号，不能原样同时内置；官方共存机制使用 C 内置、Rust 模块。当前 Image-only、Rust 内置方案保持单一实现，不引入模块交付或私有 tracepoint 改名层。

AutoFDO 使用固定 common 自带的 `gki/aarch64/afdo/kernel.afdo`，实际 C/Rust 命令必须带 sample-use 参数。构建前验证摘要、Git blob 和 LLVM 可读性；缺失或不匹配失败。该 profile 来自 Pixel 工作负载，不能据此宣称小米实测性能收益。

KernelSU 新版内嵌的 preinit runner 是独立的静态 nolibc 用户态程序，其真实命令单独记录，保持官方用户态参数，不使用内核 AutoFDO/ExtTSP。构建检查 arm64 静态 ELF 与 Image 中的嵌入符号；内核对象的原有编译参数门禁保持。

C/Rust 后端启用 ExtTSP 基本块布局，并显式设置 `ext-tsp-apply-without-profile=false`，仅作用于有 profile 的函数。实际命令审计校验两个 LLVM 参数的最终值，防止被后续选项覆盖。Rust 仅 core 通过原生 `RUSTFLAGS_core.o` 使用四线程前端，继续遵循 GNU Make jobserver，所有内核 crate 保持 `codegen-units=1`；宿主工具保持 O2。

增量构建树位于 `work/cache/kernel/`；IPSet/libmnl 位于 `.env` 固定的 `work/cache/userspace/ipset-sm8850/`，复用同一 SoC ISA 与 Oryon-1 调度参数，使用正常用户态 SIMD。其配置身份包含源码、NDK、API、路径及实际构建参数；输入匹配时增量构建，变化时仅重建该用户态缓存。配置成功后记录身份，编译中断可继续；每次交付仍校验 ELF、Android linker、依赖、版本及模块 ZIP 内容。

内核与 NDK 共用 `work/cache/ccache/`，保持压缩和 `.env` 固定的 5 GiB 上限；NDK 缓存身份包含完整工具树摘要。不运行 clean/mrproper，不放宽缓存依赖校验。源码、官方审计仓库及当前下载缓存可复用，`init.sh` 不应为已有完整对象重复下载。迁移绝对路径可能使部分编译记录失效，由下次必要构建正常处理，不改写旧命令伪造缓存命中。

预编译阶段只审计本次已编译的核心 C/Rust/helper 对象及 LLVM 属性；其余旧缓存命令由随后完整 Image/modules 构建更新，完成后仍执行全量编译命令、实际属性及发布闭包检查。

宿主构建回移固定于官方 Kbuild `kbuild-next-speedups` 快照，仅包含 kallsyms token 索引及现有 C/链接器参数探测缓存链。保持 6.12 的 `string` / `default` Kconfig 语法和原参数顺序，工具身份变化由原生 Kconfig 依赖机制重新探测。新增 20 个探测定义，其中固定 Clang 组合序列化 12 项；旧配置值和 W=0/W=1 的 C、汇编、Rust、链接及 PI/EFI 参数已核实等价。kallsyms 加速仅影响符号生成，不能当作完整构建提速比例。

## 交付与身份

内核产物写入 `kernel_out/luna-xiaomi17-g<8位提交>-YYYYMMDD-HHMM/`，时间为上海时区。同名目录拒绝覆盖，文件仍为：

```text
luna-xiaomi17-g<8位提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<8位提交>-YYYYMMDD
```

完整审计归档、工作日志和 `.build-artifacts` 清单位于 `work/audit/<同名目录>/`；IPSet 命令与 KernelSU 模块 ZIP 位于 `work/components/<同名目录>/`。默认交付集合包含 Image、内核 ZIP、审计 ZIP、IPSet 命令与 IPSet 模块 ZIP 共五个文件。清单绑定全部交付文件的 SHA-256 和项目相对路径，OrbStack 保持这些目录关系；历史发布清单按原有文件集合校验。

AnyKernel3 由固定官方脚本、[`ak3_template/luna.patch`](../ak3_template/luna.patch)、BusyBox 和 MagiskBoot 组装，仅替换 Image。KernelSU/SUSFS 保持内核集成；Manager 由用户独立获取匹配内核接口的官方版本。标准流程不下载 Manager，不打包 SUSFS KernelSU 模块或独立 helper。

构建只接受干净项目提交；成功后状态为 `awaiting-device`，不等同于实机验收。内核产物保留最新三套，第四套经用户确认验收后再清理最旧一套；构建不会提前删除旧内核产物。构建审计（含日志、失败快照）、回移审计及配套组件按类别各保留 `.env` 的 `WORK_HISTORY_KEEP=3` 份，生成流程退出或宿主导入完成后自动清理超额记录。构建记录按目录时间排序，回移审计按快照日期排序，同快照复用目录。审计被轮换掉的旧内核不再构成可重新发布的完整集合。外部 `evidence/` 由用户手动管理。
