[English](README_EN.md)

# Luna Kernel — HyperOS 3 历史分支

这是 Luna Kernel 面向小米 17（`pudding`）HyperOS 3 / Android 16 的历史维护分支。

| 项目 | 固定版本 |
| --- | --- |
| 设备 | 小米 17（`pudding`） |
| 系统 | HyperOS 3 / Android 16 |
| 内核 | Linux 6.12.23、4 KiB |
| AOSP GKI | `android16-6.12-2025-06_r57` @ `a82fc641d6d2c687802606190c0a8c33a4242201` |
| 小米公开基线 | `popsicle-w-oss` @ `45705be1220b4cfa8100516ad86711656c0b634e` |

该分支保留原有 KernelSU、SUSFS、Baseband Guard、ADIOS、TCP Brutal、IPSet 以及已审查的 AOSP/Linux 回移记录，仅用于旧系统维护。HyperOS 4 / Android 17 的当前开发位于 `main`。

## 构建

```bash
./init.sh
./patch.sh
./patch_external.sh
./build.sh
```

AnyKernel3 安装包从固定官方脚本与本分支的 Luna 差异补丁重新组装，只替换 boot 中的 `Image`。刷写前请确认设备和系统版本并备份原始 boot。

## 状态

原 OS3 内核组合曾在小米 17 上完成编译、启动和基础功能验证。公开历史整理改变了项目哈希和打包来源，因此新的归档分支提交不沿用旧产物的发布身份，也不作为当前推荐版本。

## 许可证

项目自有脚本与补丁按 [GPL-2.0-only](LICENSE) 发布。第三方组件继续受各自许可证约束。
