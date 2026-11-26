# TB320FC 双槽 kShimC（A/B slot）

`boot/README.md` 讲的是**怎么把 runtime 打进一个 96 MiB `ANDROID!` v4 容器**；本目录讲的是**这台机器有两个 boot 槽、每个槽装什么、怎么刷、怎么回滚**，也就是 A177-A181 那一段实际上跑通的流程。二者关系：打包器还是 `../build_android_boot.py`，runtime 还是 kshim 源码树编出来的 4 MiB `kShimC.bin`。

| 文件 | 用途 |
|---|---|
| `configs/tb320fc_ufs_b_defconfig` | `boot_b`（原厂 Android 当 base）profile：菜单能起安卓，也能 route A 起机身 ArmadaOS |
| `configs/tb320fc_ufs_a2_defconfig` | `boot_a`（机身 ArmadaOS 当 base）profile：菜单起 ArmadaOS，带同一套触摸引擎 |
| `build_runtime.sh` | 编一个槽的 runtime，强制 4 MiB / 无未决符号 / 内嵌 NVT 固件，打印 sha256 |
| `pack_slot.sh` | 打包 `boot_a` / `boot_b`，并和参考 report 逐字段比 layout/avb |
| `compare_reports.py` | 两份 `*.img.report.json` 的 diff（`checks` 计数 + `layout`/`avb` 差异） |
| `flash_slot.sh` | 在板子上（跑着任一系统时）写另一个/自己的 boot 分区：先存回滚副本，dd 后读回整分区 sha256 |

## 两个槽各自是什么

| | `boot_a` | `boot_b` |
|---|---|---|
| base image | 机身 ArmadaOS（内核自带 appended DTB，`root=UUID`） | 原厂 Android（GKI 内核 + 1584 B generic ramdisk） |
| profile | `tb320fc_ufs_a2_defconfig` | `tb320fc_ufs_b_defconfig` |
| `MENU_BASE_ANDROID` | 关（base 不是安卓，别写错措辞） | 开 |
| `UFS_PAYLOAD_BOOT`（route A） | 开过，**结论是不适用**，见下 | 开：这是"从安卓槽一键进 ArmadaOS"的实现 |
| 菜单里的条目 | `ArmadaOS（机身）` | 安卓 + `ArmadaOS（机身）` |
| 打包 base-name | `ArmadaOS（机身）` | `Android（机身）` |
| 日常建议 | 只在需要"直达 ArmadaOS（不 stage）"时用 | **默认活动槽用它**（一个菜单起两个系统） |

manifest 里 base 的名字**不是装饰**：kshim 在 `src/core/main.c` 里明确"staged 副本用对方槽自己 manifest 给的 base 名，这个菜单从不替别人起名字"。所以菜单上看到的 `ArmadaOS（机身）` 就是 `boot_a` 打包时传的 `--base-name`；想让 A 槽菜单显示 `Android（机身）`，得改的是 **`boot_b` 的 `--base-name`**，不是 A 的配置。

## 端到端

```sh
# 0) 一次性：把本目录的 profile 铺进 kshim 源码树（build_runtime.sh 会自动做并核对 sha）
# 1) 编 runtime（构建机 comfyui）
sh devices/lenovo-tb320fc/boot/kshim-slots/build_runtime.sh c61 b
sh devices/lenovo-tb320fc/boot/kshim-slots/build_runtime.sh a61 a
# 2) 打包（stock-boot 必须是本机新鲜备份：A 用 boot_a-live.img，B 用 boot_b-live.img）
sh .../pack_slot.sh b /root/y700-artifacts/kshim-tb320fc-c61.bin /srv/y700/g4/a149/boot_b-c61e.img
sh .../pack_slot.sh a /root/y700-artifacts/kshim-tb320fc-a61.bin /srv/y700/g4/a149/boot_a-c61a.img
# 3) 上板（不需要 fastboot：板子跑着任一系统时 boot_* 都只是没挂载的块设备）
scp flash_slot.sh boot_*.img 到板上 /tmp，root 执行：
bash flash_slot.sh a /tmp/boot_a-c61a.img 00ec152d...   # 第 3 参数 = 期望的镜像 sha256
```

刷写永远遵守三条：**先备份**（`boot_a-live.img` / `boot_b-live.img` 是打包基准，板上再存一份 pre 副本）、**写后读回整分区 sha256 与镜像比对**、**绝不碰 `misc` 和活动槽**（改活动槽只有 `fastboot --set-active` 这条路，见下）。

## route A 的适用边界（a62 实测，别再试第二次）

route A = 把"另一个槽"的 boot 容器整段读进 loader 预留的 DRAM 窗，然后从那份拷贝进入它的 base 内核，磁盘不写、活动槽不改。它在 `boot_b → 机身 ArmadaOS` 方向上完全成立（板上日志 `kshim: pay valid 1 step 0 slot 0 base 0xab800000 blk 16096`）。

反过来 `boot_a → Android` 结构性不通：`CONFIG_KSHIM_UFS_PAYLOAD_BOOT=y` 打开后，槽识别和读取都对（`kshim: pay valid 0 step 8 slot 1 base 0xac200000 blk 13504`），但 `pay_find_dtb()` 在 staged 副本里找不到有效 DTB，`enum kshim_pay_step` 的 **8 = `KSHIM_PAY_DEVICE_TREE`** ⇒ `pay.valid=0`，菜单里那一行干脆不出现。原因在容器形状：Android 的 DTB/dtbo 在 `dtbo_b`、vendor ramdisk 在 `vendor_boot_b`，`boot_b` 里没有 appended DTB。要打通等于在 shim 里复刻 ABL 的 dtb+dtbo+vendor_ramdisk+`androidboot` cmdline 组装，做坏了就是黑屏假死。

替代方案"菜单里切活动槽再重启"也堵：`/dev/disk/by-partlabel/misc -> /dev/sda7`（1 MiB）前 64 字节是 legacy boot-command 区（平时只残留 `-bootloader`），**没有 VAB 的 `slot_select`，连 magic `misc` 都不在**——这台 XBL 把活动槽存在自己的 NV 里，只有 `fastboot --set-active` 能改。

结论：**route A 只适用于"自带 DTB 且根能自解析"的载荷**。

## 已上机验证

- A 槽与 B 槽的菜单都可**触摸**：runtime 自己完成 NVT host-download（`nvt#13 dl step=13 err=0 ch=12 by=150696`、`nvt#15 crc g=4c0ce2ae/ecb27187 r=…` 与内核加载后完全相同），必须等 `RESET_STATE_RUNNING(0xa3)`（`nvt#25 run st=a3 polls=13`），到位后首读仍可能空，所以 `live` 无条件开（`nvt#21 out st=6 rc=0 live=1`）。菜单 20 ms 轮询实测 `nvt#24 off p=198 g=198 …`。
- 坐标映射用 `KSHIM_TOUCH_ROTATION_0`：`native = raw/10`，再由 `kshim_lvgl_touch` 按 `CONFIG_KSHIM_UI_ROTATION_CCW=270` 转成横屏逻辑坐标；判轴向只用**单点定点** + 日志里的 `raw/nat/ptr` 三套坐标。
- 标题栏干净（`# CONFIG_KSHIM_UFS_TITLE_REPORT is not set`），标题就是 `KShimC 启动器`，不带 "ufs read xxx"。
- 菜单无倒计时（`MENU_ENTRY_DURATION_MS=0`），所以它会等人选；退出路线含 `高级启动模式 → Fastboot`。

## 日志怎么读

载荷内核里的 `y700_ramlog` 会把 shim 的 ring 回放进 dmesg：`dmesg | grep -E 'nvt#|tch#|kshim:'`。两个坑：**同一轮 `bytes=/lines=` 与上一轮完全相同 = 陈旧回放**；环缓冲一行只有约 60 字符，长行会被切掉（`nvt#24` 曾经丢过尾字段）。

## 当前板上状态（2026-11-23，A181 收口）

| 分区 | 内容 | sha256 |
|---|---|---|
| `boot_a` | a61（c61 的 A 槽孪生，含触摸、标题干净） | `00ec152d8d2ab237f9e2b989a5554e55f96af68d7ee529011faa2b9060c81927` |
| `boot_b` | c61e | `1f4c808d397bf040e3fecbed5d794e57c5f912c7d17a756387c87994db8c0560` |
| 活动槽 | `b`（`fastboot set_active b`，XBL NV 持久） | — |
| runtime | `kshim-tb320fc-c61.bin` / `kshim-tb320fc-a61.bin` | `5e5aa69900d6ae5c835ae8d0ac342d58147bbc583b972ee70806f58536db936e` / `53f576d623b5563ec4b1e7de2868b600ccb0592752bb4c4bd1c85f5e4b4e024e` |
| 回滚点 | comfyui `g4/a182/boot_a-dump.img`（刷前 c41a）、`g4/a149/boot_a-live.img`（`2d1d27f5…`）、`g4/a149/boot_b-live.img`（`ccfa6bbc…`） | — |
| 实验产物（不刷） | `g4/a149/boot_a-c62a.img`（route A on）、`boot_b-c61f.img`（base-name 改标签） | `4134fa16…` / `f936be38…` |

## 自检（这套脚本已经自证过）

- `./build_runtime.sh a61 a` 与 `./build_runtime.sh c61 b` 复现出板上正在用的两份 runtime，**逐字节相同**：`53f576d623b556…`（a61）/ `5e5aa69900d6ae…`（c61）。
- `./pack_slot.sh a /root/y700-artifacts/kshim-tb320fc-a61.bin /tmp/repro-boot_a.img` 复现 `boot_a-c61a.img` = `00ec152d…`，与板上分区读回值一致；`compare_reports.py` 对它判 `REPORT_MATCH`（119/119）。
- `./pack_slot.sh b`（默认 `Android（机身）`）复现的是 c61f `f936be38…`；和 c61e 严格比会报 `layout.packed_size 8454348 -> 8454352`，加 `--allow packed_size` 才 `REPORT_MATCH` —— 这两行合起来就是"只改标签"的指纹。
- `flash_slot.sh` 的三道门在板上实测都在**写之前**退出 1：镜像 sha 不符（`SOURCE_SHA_FAIL`）、板上状态与计划不符（`PRE_SHA_MISMATCH`）、槽名解析不到；跑完 `boot_a` 仍是 `00ec152d…`。

## 写这套脚本时又踩到的三个坑

- `set -o pipefail` + `nm … | grep -q …`：grep 一命中就退出，nm 被 SIGPIPE 打死（141），整条管道算失败 —— 符号检查于是**永远报缺符号**；同一写法反过来也能让检查**永远通过**（上一代脚本的 `grep CMakeFiles/kShimC.dir/flags.make` 就是这么一直"没问题"的）。先把 `nm` 输出落文件再 grep。
- `KSHIM_DIAG_*` / `KSHIM_QUIRK_CNTPCT_DISABLE` / `KSHIM_GEN2_ENTRY_VIA_HEADER` 是 **CMake 选项，不是 defconfig 符号**：漏传它们，`generated/include/config.h` 一模一样、代码布局却变，sha 就对不上板上那份（第一版就"复现失败"在这里）。`build_runtime.sh` 现在自带板上验证过的那组默认值，额外参数排在后面覆盖它。
- 必须用 **bash** 跑：构建机的 `sh` 是 dash，`set -o pipefail` 直接 `Illegal option`。

## 别踩过的坑（已固化进脚本）

- `kshim-gen2` 构建脚本里那句 `grep CMakeFiles/kShimC.dir/flags.make` 一直是空跑：Ninja 的对象目录叫 `kShimC.elf.dir`，而且这些 `-D` 不在那儿。**配置凭据看 `build/<name>/generated/include/config.h`**，两版之间直接 diff 它。
- 打包报告只能跟**同槽**的历史 report 比：A 槽 `shim_off=61669376 / manifest_off=65863680 / tail_off=65933312`，B 槽是另一套数字。
- 板子的 UFS 盘符每轮会漂（`sde13` 变 `sdd13`），永远用 `readlink -f /dev/disk/by-partlabel/boot_<slot>`。
- `set_active` 会把目标槽的 `retry-count` 重置、`successful` 清零（实测 b：`2/yes → 7/no`），系统正常开机后自己会报 boot completed，不影响使用。
