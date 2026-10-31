# Y700 二代引导构建与打包

适用于 TB320FC / SM8475。二代与五代共用 [kShimC 源码树](../../lenovo-tb323fu/boot/kshim-success-source/README.md)，使用 `tb320fc_android_defconfig` profile；打包用本目录的 MZ/PE 感知独立驱动。

| 用途 | 构建入口 |
|---|---|
| 原厂 Android + kShimC 菜单 | 本目录的 [build_android_boot.py](build_android_boot.py) |
| 4 MiB runtime | kshim 源码树的 `tools/build_runtime.py` |
| AVB 重封 | `packages/kshim-tools/vendor/avbtool.py` |
| 远端端到端 | 本目录的 [build.sh](build.sh) |

打包产物只含原厂 Android 基座与 kShimC runtime，不含 Linux 内核/DTB/initramfs；机身 Linux 由系统安装器另行处理。

## 二代内核是 MZ/PE 格式（与四/五代的关键差异）

96 MiB `ANDROID!` v4 容器（header_size 0x630、version @0x28 = 4、内核从 0x1000 开始）里的内核**不是裸 ARM64 Image**：

```
0x00  64B MZ stub（e_lfanew = 0x40）
0x40  PE 签名 + 20B COFF（machine 0xAA64、sizeofopt=0 decoy）
0x54  160B 扩展头：
      +0x00 u16 0x00A0 自身长度
      +0x04 u16 0x020B "PE32+" magic
      +0x0C u32 0x350000 image-base 类 decoy
      +0x14 u32 entry RVA（stock 为 0x24703E8）
0xF4  decoy 节表
```

XBL 平拷贝整段（文件偏移 == 虚拟偏移）并跳转 entry；entry 首字 `0xD102C3FF`（sub x19,sp,#0x2c）是真 prologue。四/五代的打包器只认裸 `ARM\x64`，**不能复用**。

stock 实测的其它容器事实：

- `0x0C` = debug-ramdisk 大小（0x1D6760）、`0x10` = 其加载地址（0x1A000176）
- 内核尾部（自 kernel 相对 0x2C9C000 起约 2.1 MB）是原厂 debug-ramdisk（含 `debug_ramdisk` 字符串）；内核最后非零字节 0x2C9A3D6
- 原厂 vbmeta 在 kernel 相对 0x2E67600（896 B，AVB 算法 `NONE`），footer 在镜像尾部（major 1）

## 打包布局

打包只改容器头的 `kernel_size` 字段（改成 packed 总长）。布局（kernel 相对偏移）：

| 偏移 | 内容 |
|---|---|
| 0 | stock 内核（入口区 5 个 u64 字被原地改写） |
| 0x2C9A3E4 | kShimC runtime，4 MiB（覆盖原厂 debug-ramdisk 区） |
| 0x309A3E4 | manifest（约 0.1 KiB） |

### 入口区协议

入口区位于内核 entry RVA（stock 0x24703E8）处，**不在镜像头部**。kShimC 以 PC 相对方式定位它（BL 距离 0x00C29FF4，在 ±0x08000000 内）。5 个 u64 字：

| 字 | stock 值 | 打包后 |
|---|---|---|
| +0x00 | prologue 首字 | 到 shim 入口的 `B`（进 Android 前恢复原值） |
| +0x10 | — | packed 总长 |
| +0x20 | — | manifest 偏移（相对入口区） |
| +0x28 | — | manifest 大小 |
| +0x30 | — | shim 偏移（相对入口区） |

原始 5 字保存在 manifest 的 `MANIFEST_BASE_IMAGE` backup 槽位。kShimC 按判据区分布局：word0 是 branch、word1 非 branch、backup word0 非 branch → 二代布局（先恢复 5 字、从 +0 进入）；word1 是 branch → 经典布局（从 +4 进入），四/五代行为完全不变。

### manifest

magic `0x464D504B`、版本 0.1、entry_count 2、default 0：

| # | 类型 | flags | offset | size | alignment |
|---|---|---|---|---|---|
| 0 | LINUX | BASE_IMAGE\|EXEC | 0 | 0x2C9A3E4 | 21 |
| 1 | SHIM | EXEC | 0x829FF4（= shim_off − entry_rva） | 0x400000 | 2 |

## AVB 重封

用 stock 镜像解析 salt、rollback index/位置与 properties，再以 avbtool `add_hash_footer --algorithm NONE` 重新挂 footer（新 vbmeta 放在新 ois = 4K 对齐后的 packed 长度之后）。不保留 Lenovo 原厂签名，要求 bootloader 解锁。

## 用法

```sh
# 1) runtime（需要 CrDK 的 Linux 构建机，依赖见 kshim-success-source/DEPENDENCIES.md）
cd <kshim 源码树>
python3 tools/build_runtime.py --config configs/tb320fc_android_defconfig --out out/runtime
# 产物 out/runtime/kShimC.bin，必须恰好 4 MiB

# 2) 打包
python3 <repo>/devices/lenovo-tb320fc/boot/build_android_boot.py \
  --stock-boot <本机 boot_a.img（96 MiB）> \
  --runtime    out/runtime/kShimC.bin \
  --avbtool    <repo>/packages/kshim-tools/vendor/avbtool.py \
  --out        boot-packed.img

# 3) stock 模型离线自检（零依赖，验证逆向模型）
python3 build_android_boot.py --stock-boot boot_a.img --round-trip-only
```

`--stock-boot` 必须恰好 100663296 字节。打包脚本自带全套校验（round-trip、布局、AVB、manifest ABI），报告写到 `<out>.report.json` 与 `kshim-packer-logs/`。

## 远端端到端构建

`build.sh` 在构建容器 `/work` 里运行，输入约定：

- `source.tar`：kshim 源码树（解包到 `source/`）
- `inputs/boot-stock.img`：本机 `boot_a.img`
- `inputs/avbtool.py`：仓库的 avbtool
- `build_android_boot.py`、`kshim-gen2-entry-protocol.patch`：与 build.sh 同级

步骤：解包 → `git apply` 打 kShimC 补丁 → stock round-trip 自检 → 构建 4 MiB runtime → 打包 → 证据落 `evidence/`，全部通过则写 `build.exit = 0`。

## kShimC 补丁

[kshim-gen2-entry-protocol.patch](../patches/boot/kshim-gen2-entry-protocol.patch) 对 `src/core/main.c` 做 5 处编辑：新增布局自适应 helper（`word_is_branch` + `base_image_entry_offset`），并在 m30 reject/ok、内存 handoff 失败、正常 Linux 四条 handoff 路径改用该 helper 计算入口偏移。已用 `git apply --check` 验证，round-trip 字节一致。
