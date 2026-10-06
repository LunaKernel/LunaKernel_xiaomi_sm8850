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

C 使用固定 `-march` 和 `-mtune=oryon-1`；Rust 使用 `target-cpu=generic`、`tune-cpu=oryon-1` 与固定 ISA 列表。全部参数在 `.env`；Kbuild 保持内核 SIMD 和分支保护约束，Rust 特性列表以 `-neon` 结束。保留 O2、CFI、Rust inline helpers 与 `LTO_NONE`。

AutoFDO 使用固定 common 自带的 `gki/aarch64/afdo/kernel.afdo`，实际 C/Rust 命令必须带 sample-use 参数。构建前验证摘要、Git blob 和 LLVM 可读性；缺失或不匹配失败。该 profile 来自 Pixel 工作负载，不能据此宣称小米实测性能收益。

增量构建树位于 `work/cache/kernel/`，项目 ccache 位于 `work/cache/ccache/`；不因目录整理运行 clean/mrproper。源码、官方审计仓库及当前下载缓存可复用，`init.sh` 不应为已有完整对象重复下载。迁移绝对路径可能使部分编译记录失效，由下次必要构建正常处理，不改写旧命令伪造缓存命中。

## 交付与身份

内核产物写入 `kernel_out/luna-xiaomi17-g<8位提交>-YYYYMMDD-HHMM/`，时间为上海时区。同名目录拒绝覆盖，文件仍为：

```text
luna-xiaomi17-g<8位提交>-YYYYMMDD.zip
Image-luna-xiaomi17-g<8位提交>-YYYYMMDD
```

完整审计归档、工作日志和 `.build-artifacts` 清单位于 `work/audit/<同名目录>/`；Manager、IPSet 与 SUSFS 配套产物位于 `work/components/<同名目录>/`。清单绑定全部交付文件的 SHA-256 和项目相对路径，OrbStack 保持这些目录关系。

AnyKernel3 由固定官方脚本、[`ak3_template/luna.patch`](../ak3_template/luna.patch)、BusyBox 和 MagiskBoot 组装，仅替换 Image。KernelSU 保持 built-in，Manager 使用同提交官方 CI 签名 APK；首次获取需要已认证的 gh，不需要本地 Gradle 构建。

构建只接受干净项目提交；成功后状态为 `awaiting-device`，不等同于实机验收。内核产物保留最新三套，第四套经用户确认验收后再清理最旧一套；构建不会提前删除旧内核产物。构建审计（含日志、失败快照）、回移审计及配套组件按类别各保留 `.env` 的 `WORK_HISTORY_KEEP=3` 份，生成流程退出或宿主导入完成后自动清理超额记录。构建记录按目录时间排序，回移审计按快照日期排序，同快照复用目录。审计被轮换掉的旧内核不再构成可重新发布的完整集合。外部 `evidence/` 由用户手动管理。
