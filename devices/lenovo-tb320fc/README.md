# 联想拯救者 Y700 二代

ArmadaOS Freedom 为 Y700 二代提供 kShimC 多系统启动、Steam 游戏模式和面向平板的输入与外设支持。本页记录 TB320FC 的功能状态、已知问题和开发入口。

| 项目 | 配置 |
|---|---|
| 型号 | TB320FC |
| SoC | Qualcomm SM8475（第一代骁龙 8+，内部代号 Cape/CapeP） |
| 设备树标识 | `lenovo,tb320fc`、`qcom,sm8475` |
| 内核 | ArmadaOS Freedom 统一 Linux 7.2.6 + tb320fc 覆盖层（`KERNEL_OVERLAYS=tb320fc`，release `7.2.6-tb320fc`） |
| Armada Control 配置 | `lenovo-tb320fc`，无风扇平板 |

## 功能状态

| 功能 | 当前状态 |
|---|---|
| kShimC 启动菜单 | 已实机验证：runtime 自己做 NVT host-download，菜单吃触摸，270° 旋转与中文都在（A176-A180）；板上 `boot_b` 是 c61e、`boot_a` 是 a61 |
| Android 启动 | 已实机验证：活动槽 `b` + 菜单选 `Android（机身）`，安卓正常进系统（A180，2026-11-24 复测）；要求 bootloader 已解锁（AVB `NONE` 重封） |
| 机身 Linux | 已实机验证：`boot_b` → initramfs → UFS 根 `y700root-ufs`（`/dev/sda16`）→ systemd，不插 TF 卡直接进 Plasma Mobile 桌面 |
| 触屏 | 已实机验证：NT36523N host-download SPI 固件加载成功，输入挂在真实 DSI 面板上（A98-A103），方向正确、可拖窗口，熄屏恢复后仍可用 |
| 触屏/手写笔 | 已实机验证：NT36523N host-download SPI 固件加载成功，输入挂在真实 DSI 面板上（A98-A103），方向正确、可拖窗口，熄屏恢复后仍可用 |
| GPU/显示 | 已实机验证：Adreno 730 + GMU + gpucc + adreno-SMMU 全部绑定，`renderD128` 存在，weston `GL renderer: FD730`（GPU 固件必须进 initramfs，见 `boot/a-series/kernel/patches/a104-build.sh`） |
| Wi-Fi | 已实机验证：WCN6855 走 `ath11k_pci`（`.ko`，根挂载后 insmod），已能连网；死结是 boot DTB 里 `pcie@1c00000` 缺 `iommu-map`，A130 修好后端到端通了，路线见根目录 `qca6490.md` 与 `PROGRESS.md` A120-A130 |
| 音频 | 已实机验证：ADSP(AudioReach) + `q6apm`/`q6prm` + `snd-sc8280xp`(lenovo,y700-sndcard) + 两片 CS35L45，立体声外放出声；拓扑与 UCM 已进 `system_files`，开机自动写功放路由（A131-A141），A143 起开机不再播放测试音 ；A184 起路由写两遍（`passes=2`）且只保留一个写者（A185 把 payload 的 `y700-audio`/`y700-power` mask 掉），两只功放稳定出声 |
| 电池/充电 | 已实机验证：ADSP PMIC GLINK 路线（`pmic_glink` + `qcom_battmgr` + `ucsi_glink`，不改 DT），`/sys/class/power_supply` 齐全、USB-C 已按 PD/PPS 11 V · 3 A 充电（A142）；固件给的 charge/energy/power 三个数是坏的，A145-A146 起由内核派生，桌面读数与剩余时间正常 |
| 触觉反馈 | PM8008（i2c5）尚无主线消费方，节点保持禁用 |
| 内置手柄 | 本机无内置手柄，`ARMADA_BUILTIN_GAMEPAD=0`，不等待 CompositeDevice |

启动链、显示/触摸、GPU、kShimC 菜单与 Android 启动均已实机验证（见根目录 `PROGRESS.md` A97-A105、A176-A187）。镜像层面的工作（live 逆向、boot 镜像解码、打包往返与 dry-run 全链路）已完成，见[二代引导文档](boot/README.md)。

## 槽位与活动槽（A187）

两个槽的语义是固定的，别按"槽 a = 安卓"去理解 —— 这几天每次"进不去安卓"都是这个假设造成的：

| 活动槽 | boot 内容 | base（菜单默认项） | 能去哪 |
|---|---|---|---|
| `a` | `boot_a-c61a.img`（sha `00ec152d…`） | ArmadaOS（机身） | 只有 ArmadaOS |
| `b` | `boot_b-c61e.img`（sha `1f4c808d…`） | Android（机身） | 安卓 + route A 进 ArmadaOS（菜单带触摸） |

日常把活动槽留在 `b`：两套系统都能从一个菜单进，不用碰 fastboot。

活动槽不在 `misc`（整 1 MiB 只有偏移 8 处一个 `-bootloader` 残留和 0x8000 处 5 个字节，`--set-active` 前后逐字节相同），也不是 EFI 变量（两个系统里都没有 `/sys/firmware/efi/efivars`）。它就是承载 `boot_a/boot_b` 的那个 UFS LU 的 **GPT 分区条目属性位**：bit48-51 优先级、52 successful、53 boot-failed、55 dont-boot-again。本机 27 对 `_a/_b` 分区都带这些位，`fastboot --set-active` 会同时改主备两份 GPT。

要紧的是**失败的启动会自己降权**：连续失败的槽 priority 递减并被打上 `dont-boot-again`；两边都被降权之后 XBL 没有可试的对象，屏幕就停在 fastboot 界面。这是"选过一次 ArmadaOS 之后启动项消失"的机制，与 `y700-*` 单元被 mask 无关 —— mask 状态下 ArmadaOS 照样正常起（A187 实测）。但**别把"一直回 fastboot"一律归到降权头上**：A203 实测属性位完全正常（`boot_b` Flags `0x002f000000000000` = priority 15、`dont-boot-again` 已清）时照样起不来，还有 `misc` 里的 `ffbm-00` 锁和电池过放两条独立原因，见下面「开机回 fastboot 的取证顺序」。

`/usr/libexec/tb320fc/slot-attrs` 是这一层的读数与修复工具：

    slot-attrs report                    # 只读，列出每对分区的 prio/flags
    slot-attrs set --slot b              # dry-run，列出将要写入的条目
    slot-attrs set --slot b --commit     # 真写：重算主备 CRC32、读回校验、留 pre-dump

语义是幂等的：把每对里较高的优先级给目标槽、较低的给另一个，并清掉目标槽的 `dont-boot-again`/`boot-failed`、置上 `successful`；对已经首选的槽跑一遍会直接报 `already_preferred=1`，一个字节都不写。主备两份拷贝任一 CRC 不过、或两份不一致时它直接拒绝 —— 不猜哪半边可信。于是"卡在 fastboot、但另一个槽的系统还能 SSH"这种情况不用再把手放到板子上。测试见 `tests/tb320fc-slot-attrs-test.sh`（合成 GPT，21 项，覆盖写入路径、幂等、两类拒绝）。

两个坑：`fastboot getvar all` 会把这台 XBL 的 fastboot 会话彻底卡死（之后连 `getvar unlocked` 都不回话，只能重新复位），要读数就发单条 `getvar`；`getvar current-slot` 同样不实现，会挂住。`fastboot --set-active` 在 platform-tools 34 只认 `--set-active=b`，写成 `--set-active b` 会报 unknown command。另外 `18d1:d00d` 是这台机器在 fastboot 下的 USB ID（`lsusb` 别名写成 "Xiaomi Mi/Redmi 2 (fastboot)"），别把它当成"已经进系统"。

### 开机回 fastboot 的取证顺序（A203）

四条原因都会产生同一个现象，按下面的顺序查，每一步都有只读手段：

1. **供电**。低电量下 ABL 拒绝拉起任何系统，但 fastboot/EDL 还能用；电量再掉连 fastboot 都不枚举（`lsusb` 里没有 `18d1:d00d`，所有 `getvar` 都 `<waiting>`）。长时间把平板挂在 PC 的数据口（尤其非充电口）跑刷写，电池会被耗光 —— 先充 ≥40 min 再谈别的。
2. **`misc` 的 FFBM 锁**。`misc`（LUN 0，`0x15d88000`）开头是 `ffbm-00` 时，ABL 每次都跳那个 `boot qmmi / boot FFBM / POWER OFF / RECOVERY MODE / RESTART BOOTLOADER` 菜单，与槽位、镜像内容无关。清零：`edl ws 89480 zeros_1m.bin --lun=0`（4 KiB 扇区 × 256），写完读回比对 sha。
3. **GPT 属性位**。`slot-attrs report`（板内）或 EDL `printgpt --lun=4` 看 `boot_a/boot_b` 的 Flags；`fastboot --set-active=<slot>` 会把目标槽 priority 抬到 15 并清掉 `dont-boot-again`。
4. **分区内容**。EDL 读回算 sha 与本机存档对拍（A203 实测 `r boot_b` 读回 100663296 字节 == `boot_b-c61e.img` 的 `1f4c808d…`，顺带证明 `fastboot flash boot_b` 没有盖到另一个槽）。
5. **data/FBE 状态**。前四条全绿、镜像内容也全对之后，还剩 `userdata`+`metadata` 这一条：`super` 换了版本、`userdata` 容量被改过、或 `metadata` 里留着旧 FBE keyblob，init 都会在挂载 data 时失败，而 ABL 层的表现和"完全起不来"一模一样。这台机器没有日志通道可判（`logfs`/`logdump`/`qmcs` 全是空的），别绕，直接擦：`fastboot erase userdata`、`erase metadata`、`erase misc`，再 `--set-active=<slot>`。UFS 上 `erase` 走 UNMAP，450 GiB 只花 2.1 s。

对照实验必须同版本：手头的 `zui_15.0.737` EDL 包与机器原装（`oemowninfo` 里是 `ZUI_16.0.688_250125`，Android 14）差一代，所以拿包内单个 `boot.img` 去判"能不能起"是无效实验（A203 踩过）—— 要判就整槽全刷，而且全刷完必须按上面第 5 条擦 data（A204 走通了，见下）。也别整包 `qfil`：`patch*.xml` 会拿包内那份按小容量盘生成的 LUN 0 GPT 覆盖设备表（`userdata` 长度是 0），要改容量就照 A204 那样在设备自己的表上做手术并分片写主备。

EDL 在二代的可用姿势：loader 用 **`xbl_s_devprg_ns.melf`**（`contents.xml` 里的 `<device_programmer>`；用 `prog_firehose_ddr.elf` 会在 Sahara 阶段报 `0x29`）；进 9008 只有 **`fastboot oem reboot-edl`** 可靠（`fastboot reboot edl`、`fastboot oem edl` 都不支持）；`edl reset` 不能带 `--memory=ufshcd`；boot 系列分区在 **LUN 4**（`boot_b` = `0x5b6ef000` → 起始扇区 374511），`super`/`misc`/`userdata`/`linuxroot`（Type `EFI_LINUX_DAYA`）在 **LUN 0**。

### 全量回安卓（EDL 全覆盖，A204）

"所有空间给安卓、ArmadaOS 不再存在"这条路的完整走法已实机成功：起进 ZUI 15.0.737 首次引导，`lsusb` 出现 `17ef:7e51 Lenovo Legion Tab Y700`（MTP），`userdata` 450.1 GiB，GPT 里已经没有 `linuxroot`。A203 归因的"电池过放"是错的 —— 电量 3696–3707 mV、属性位正常、`misc` 干净、镜像 sha 全对，机器照样每次回 fastboot。

1. 按 rom 自己的 `start_sector` 写全部 52 条镜像（`rawprogram1/2/3` + `rawprogram_unsparse0/4`，LUN 用 `--lun=` 指定），**不要**整包 `qfil`：它的 `patch*.xml` 会用 rom 自带的 LUN 0 GPT 覆盖，而那份 GPT 是按小容量盘生成的（`userdata` 长度为 0），会把分区表写坏。
2. GPT 用设备自己那份改：删掉 `linuxroot` 条目，把 `userdata` 末扇区改到 `121268218`（450.1 GiB），主备两份都重算 CRC32。备份表必须**分片写** —— 先写条目（`@121268219`）再写头（`@121268223`），10 扇区一把写会被 firehose 拒绝。
3. 别漏 rom 自己的一条：`rawprogram3.xml` 用 `zeros_5sectors.bin` 把 **LUN 3 的 `ddr`**（`@64`，256 扇区）清零 —— 那是 XBL 缓存的 DDR 训练参数，rom 作者的意图就是抹掉它强制重训。批量脚本按"文件名为空就跳过"筛 `rawprogram` 时容易把它丢掉（那个文件只有 5 扇区，实际要写满 1 MiB 零）。
4. 最后一步不能省：**擦 `userdata` + `metadata` + `misc`，再 `--set-active`**。只做 1–3 时机器仍然每次回 fastboot；rom 自带的 `userdata_*.img`/`metadata.img` 是老几何的 data 与旧 FBE metadata，跟改过容量的分区配不上，擦掉让 init 自己格式化才起得来。

顺带补的读数点：`uefivarstore`（LUN 4 `@666527`，128 扇区，头是 `PTBL` + EDK2 `VAR2`）里只有 `ConIn/ConOut/ErrOut/HwErrRecSupport/MTC/RTCInfo/RunCycles`，没有任何 fastboot/rescue 变量；`lenovolock` 全零、`xbl_sc_test_mode` 全零。`fastboot reboot recovery` 在这颗 ABL 上不会进 recovery，而是把机器直接送进 FFBM/firehose（`05c6:9008`，edl 侧 `Mode detected: firehose`）。`fetch` 不支持，`slot-retry-count`/`slot-successful`/`slot-suffix` 都没实现 —— 看槽位状态只能读 GPT 属性位。原机固件版本串在 `oemowninfo`（LUN 0 `@8328`）里，判"EDL 包比机器旧"就看这一条（本机是 `ZUI_16.0.688_250125`，包是 15.0.737；两版 xbl 版本串相同，`BOOT.MXF.2.0-00925.2-WAIPIO-1.30409.3`，字节不同，且 XBL/UEFI/ABL 都能加载 → ARB 没被触发）。

## 整机进镜像（A150 起）

A 系列那些「开机后打补丁」的脚本已经不是路线了：本机现在全部走 ArmadaOS 自己的引导，缺的东西都在镜像里。

- **内核**：`packages/kernel` 的 7.2.6 + Freedom 补丁集（301 个补丁）+ `overlays/tb320fc/`（`KERNEL_OVERLAYS=tb320fc`），板级 DTS 用实机验证过的 asphalt 文件，另加两块补丁：battmgr 派生属性、`lenovo,y700-sndcard` 匹配项。见 `packages/kernel/overlays/tb320fc/README.md`。
- **固件**：ADSP、A730 zap/GMU/sqe、CS35L45 保护固件、`novatek_ts_fw.bin` 全部入库在 `system_files/usr/lib/firmware/`，出处写在 `qcom/sm8475/lenovo/tb320fc/NOTICE.lenovo-firmware`。
- **GPU 固件进 initramfs**：`DRM_MSM` 是内建的，GMU/zap 在 initcall 阶段就要取固件，那时还没 switch_root；`system_files/usr/lib/dracut/modules.d/92armada-gpu-firmware` 负责塞进去，`build_files/55-generate-initramfs.sh` 少了就构建失败。
- **开机自动做的四件事**：`tb320fc-{audio,power,wifi,touch}.service`（`40-vendor-system-files.sh` 里 enable），脚本在 `system_files/usr/libexec/tb320fc/`，配置在 `system_files/etc/tb320fc/*.conf`。每个脚本先跑 `board-check`，不是本机就直接退出，所以对其他机型是空操作。
- **桌面自启**：`ARMADA_DEFAULT_SESSION`（`devices/defaults.conf` = `gamemode`，`devices/lenovo-tb320fc.conf` = `desktop`）经 `session-control default-session` 决定 sddm 自动登录的会话；本机进 Plasma 桌面而不是 gamemode，挂起仍是 `ARMADA_SUSPEND_MODE=fake`。

构建入口只有一条：`KERNEL_OVERLAYS=tb320fc bash packages/kernel/scripts/build-kernel.sh`。少了这个变量，`overlays/tb320fc/patches`（battmgr 派生读数、音频卡匹配）与 config 片段都不会打上，而 DTB 照样能编出来 —— 症状是「能开机、电池和声音坏」。另外 `localhost/armada/pkg/kernel:<hash>` 的 tag 只按 `packages/kernel` 的源码算（`packages/package-hash.sh`），换掉 `out/armada-kernel-*.tar.zst` 不会让 tag 变化，所以替换 tarball 之后必须重新 `podman build` 那个 image，并从 image 里把 DTB 抽出来核对，否则 rootfs 装的还是旧内核。

## 存储与双系统

- Android 保留 128 GB（`armada-installer install --userdata-gib 128`），其余 UFS 空间全部给第二系统。
- **刷写 boot 前必须先备份**：用 adb/fastboot 备份本机的 `boot_a`、`boot_b`、`dtbo_a`、`dtbo_b`、`vendor_boot_a`、`vendor_boot_b`；打包器输入必须使用本机新鲜备份。
- 本机 BL 已解锁；第二系统 boot 镜像用 AVB `NONE` 重封，不保留原厂 Lenovo 签名。

## 已知风险

- **XBL 平拷贝假设：** 二代内核是 MZ/PE 格式 blob，假设被 XBL 平拷贝（文件偏移 == 虚拟偏移）并从扩展头 entry 跳转；未实机验证。
- **debug-ramdisk 被清除：** stock 内核尾部约 2.1 MB 的 debug-ramdisk（含 `debug_ramdisk` 字符串）会被 kShimC runtime 覆盖；对应头字段 `0x0C`/`0x10` 保留未动，但其原厂用途未知。
- **入口区原地改写：** 内核入口处的 5 个 u64 字被原地改写，要求基图内存可写；原值保存在 manifest 的 backup 槽位，kShimC 在进入 Android 前恢复。
- **boot 镜像不可互刷：** 四代（SM8750）内核是裸 `ARM\x64` Image，二代是 MZ/PE，打包器不同，两代 boot 不能互刷。

## 内核与引导

二代使用 `packages/kernel` 的 Linux 7.2.6 + Freedom 补丁集。SM8475 基础设备树派生自主线 sm8450 家族（`sm8475.dtsi`），板级文件由 live 抓取的 vendor DTB（vendor_boot `vb_02` "CapeP SoC" + `dtbo_14` "Cape MTP with PM8008"）重构。

显示为 Novatek NT36523N 1600×2560 FHD+ 144 Hz 面板（双 DSI bonded 2×800、C-PHY 3 lane、DSC 8bpc、外置 Kinetic KTZ8866 背光）；触摸为 Novatek NVT36xxx host-download SPI（支持手写笔），分别由内核补丁 `0750`、`0751` 引入。

引导构建见[二代引导文档](boot/README.md)；kShimC 复用[五代共享源码树](../lenovo-tb323fu/boot/kshim-success-source/README.md)的 `tb320fc_android_defconfig` 配置。

## 音频

外放链路（AudioReach）：ADSP（`smp2p`/`qcom_q6v5_pas`）→ GPR（本树在 `apr.c` 里）→ `q6prm`/`snd-q6apm` → 机器驱动 `snd-sc8280xp`（`compatible = "lenovo,y700-sndcard"`，`driver_name = "sm8475"`）→ CPU DAI `PRIMARY_MI2S_RX` → I2C 上的两片 CS35L45（带保护 DSP）。

- **两个必须同时成立的前提**：`qcom_pd_mapper.ko` 要在 `qcom_q6v5_pas.ko` 之前 insmod，且 boot DTB 里 `gpr/service@1`、`service@2` 的 `qcom,protection-domain` 必须保留。少了 mapper，GPR 服务的 PDR 查找失败，设备根本不会创建；把属性删掉虽然能让设备出现，但 ADSP 侧的 PDR 通知（QMI service 66，`msm/adsp/audio_pd`）没人接，`APM_CMD_GET_SPF_STATE` 每次探针都超时（A138 反证、A140 定案）。
- **拓扑**：`audioreach_tplg_init()` 取 `qcom/<driver_name>/<card_name>-tplg.bin`，本机即 `qcom/sm8475/Lenovo-Y700-tplg.bin`；缺它只有 `ASoC: failed to instantiate card -2`。源文件 `audio_topology/sm8475/Lenovo-Y700.m4`，用 audioreach-topology `993a17dcb672357998a463a73f120064d6c74f4f` + alsa-topology-utils 1.2.16 的 `alsatplg` 生成，成品 10 436 字节。
- **开机必须写的路由**：`PRIMARY_MI2S_RX Audio Mixer MultiMedia1` = 1，两片 CS35L45 的 `DSP1 Firmware`=Protection、`Amplifier Mode`=SPK、`DSP_RX1..8 Source`（ASP_RX1/ASP_RX2/VMON/IMON/VDD_BATTMON/VDD_BSTMON/CLASSH_TGT/VDD_BATTMON）、`DACPCM Source`=DSP_TX1、`DSP1 Preload Switch`=1、`AMP Enable Switch` 先 0 后 1。静音的真正原因是 `SPK1/SPK2 Digital PCM Volume` 复位为 0（= -102.25 dB），而 `mute=1` 的 dBscale 控件拒绝 `-8dB` 这类文本写法，只能写原始值（当前用 400）。
- **UCM**：`Lenovo-Y700` / `HiFi` 用例把上面这套序列编码进 `system_files/usr/share/alsa/ucm2/conf.d/sm8475/Lenovo-Y700.conf` 与 `ucm2/Lenovo/Y700/HiFi.conf`；`/etc/tb320fc/audio.conf` 的 `unmute=on` 让 `/usr/libexec/tb320fc/audio` 每次开机也写一遍，两者互为保险。
- **必须静默**：A143 起默认不放测试音，开机只写功放路由（`/etc/tb320fc/audio.conf` 里不再有 `play`）。要复现测试音就临时 `systemctl restart tb320fc-audio` 之后再手动 `speaker-test`。
- **路由要写两遍**：只在声卡刚出现时写一次，第二片 CS35L45 的 DSP 图常常还没落稳，结果是一只响一只不响，而且**有声/无声两种状态下所有 kcontrol 读数完全一致**。`/etc/tb320fc/audio.conf` 的 `passes=2` + `pass_gap=8` 是关键，日志里每片功放各打一行 `SPK1/SPK2 gate amp=... digvol=...`（A184）。
- **后端第二槽是空的**：`PRIMARY_MI2S_RX Audio Mixer MultiMedia1` 是两元素布尔，读数 `on,off`，第二个元素怎么写都写不上（`1`、`1,1`、numid、`alsactl restore` 都失败）—— stock ADSP 图里 `ASP_RX2` 根本没连线。两只功放的主输入都取 `ASP_RX1`，把任何一只改成 `ASP_RX2` 它就哑（A184）。
- **只允许一个写者**：A 系 boot payload 每次开机还会在 `/etc` 重新装上 `y700-audio.service`/`y700-power.service`，和镜像的 `tb320fc-audio`/`tb320fc-power` 抢同一批控制。`tb320fc-legacy-off.service`（sysinit，`Before=` 两条链和 multi-user）把它们 `disable --now` + `mask`；mask 是 `/dev/null` 符号链接，下一轮 payload 的 `cat >` 写进黑洞，所以不重刷 payload 也能稳住（A185）。
- **`/usr` 会被回滚抹掉**：板上的热修复写进 `/usr` 能活过重启，但回滚或新部署就回到镜像内容。机制是 `system_files/usr/libexec/tb320fc/usr-overlay`：内容存在 stateroot 的 var（`/var/usrlocal/lib/tb320fc-usroverlay/files`），每次开机先于 modules-tree/audio/power/input 回放。mode 由路径决定（libexec/bin/sbin=755，其余 644），内容相同也要修 mode；它还会先更新「正在运行的自己」再 `exec`，否则 shell 会从旧偏移继续读新文件而半路炸掉（A185）。
- **固件**：ADSP（26 个文件 / 13 MB，`adsp.mdt` + `adsp.b*`）与 CS35L45 保护固件（`spk1/spk2-cs35l45-dsp1-spk-prot.wmfw/.bin`）来自 <https://github.com/dianqk/firmware-lenovo-asphalt>（`lenovo/tb320fc/audio/`，原样取自 TB320FC 的 `modem_b`/`vendor`），A150 起**已入库**在 `system_files/usr/lib/firmware/`（`qcom/sm8475/lenovo/tb320fc/`、`cirrus/` 与固件根同名副本），出处与差异写在 `qcom/sm8475/lenovo/tb320fc/NOTICE.lenovo-firmware`；spk2 的 wmfw 在原图里是指向 spk1 的符号链接，入库时按普通副本落地。

构建与诊断脚本：`boot/a-series/kernel/patches/a131..a146-build.sh`（模块与门禁）、`boot/a-series/initramfs/y700-patch-a143.sh`（把 `.ko`/拓扑/UCM 装进根）、`boot/a-series/rootfs/y700-audio-a143.sh`（`/usr/local/bin/y700-audio.sh` + `y700-audio.service`）。

## 电池与充电

官方 Android 的 DTB 里没有任何 charger/fuel-gauge 节点：电量计与 USB-C PD 都在 ADSP 的 **PMIC GLINK** 上。主线不需要改 DT，只要按顺序加载 7 个模块：
`fsa4480 → aux-hpd-bridge → pmic_glink → qcom_battmgr → typec_ucsi → ucsi_glink → pmic_glink_altmode`。

- `qcom_battmgr`/`ucsi_glink`/`pmic_glink_altmode` 都是 `pmic_glink` 的 aux-device，必须排在它后面；rpmsg 通道 `PMIC_RTR_ADSP_APPS` 由 ADSP 主动开，DT 里没有 glink 子节点也能匹配（前提是 ADSP 已经跑起来，见[音频](#音频)）。
- `qcom_battmgr_of_variants` 没有 sm8450 条目，会回落 `QCOM_BATTMGR_SM8350`，所以 psy 名字是 `qcom-battmgr-bat` / `-usb` / `-wls`（不是 `battery`），桌面集成要按这个名找。
- `CONFIG_DRM_AUX_HPD_BRIDGE=m` 就必须带 `drivers/gpu/drm/bridge/aux-hpd-bridge.ko`，缺它 `pmic_glink_altmode` 这一环起不来。
- 实机读数（A142）：`status=Charging`、`charge_type=Fast`、SOH 91%、cycle 563、model `ALIUM_..._3600MAH`；`qcom-battmgr-usb` `online=1`、`voltage_max=11 V`、`input_current_limit=3 A`；`typec port1 power_operation_mode=usb_power_delivery`；电池侧 4.25 V · 5.0 A。
- **更高功率不在 Linux 这侧**：PD/PPS 档位由 ADSP 固件请求，`qcom_battmgr.c` 没有 `property_set`（`input_current_limit` 只读，写入 `Permission denied`），这棵树也没有 UCSI 字符设备与 debugfs，用户态无法请求更高 PDO；11 V · 3 A = 33 W 已是本机官方档位，换更大功率的充电头也不会变。真要超过它只能改 ADSP 充电固件，那会偏离不破坏 Android 的前提。
- 脚本：`boot/a-series/rootfs/y700-power-a143.sh` 装成 `/usr/local/bin/y700-power.sh`，`y700-power.service` 排在 `y700-audio.service` 之后（ADSP 已热），日志 `/var/log/y700-power.txt`，标记 `Y700-A143-PWR` + `MARK-1`（电量/状态）与 `MARK-2`（PD 档位）。

### 电量百分比不是内核说的那个数（A145）

SM8450 的 ADSP 只回答「逐属性 GET」，响应里从不填 `power_unit`，于是 `battmgr->unit` 停在 0（= mWh）：
`qcom_battmgr_bat_get_property()` 里所有 `if (unit != mAh) return -ENODATA` 的分支把 `CHARGE_NOW`/`CHARGE_FULL` 全吃掉，
而 `sm8350_bat_props[]` 里根本没有 `ENERGY_*`。结果 upower 只看到 `Energy=0 / EnergyFull=0`。
Plasma 面板用 upower 的 `Percentage`（来自 `CAPACITY`，所以图标一直是对的），但 Solid/powerdevil 的 `batteryRemainingTime`
按 `Energy/EnergyFull` 算百分比，得到 0 ⇒ 每次重新查询（典型触发：DPMS 熄屏后点亮）就弹「电池电量极低，系统将在 60 秒后睡眠」并真的挂起。

- 修法：只改驱动。SM8350 变体下用 `BATT_CHG_COUNTER`(µAh) + `BATT_CAPACITY`(%) + `BATT_VOLT_NOW`(µV) 派生 charge/energy 一对，
  内核单位约定 charge 用 µAh、energy 用 µWh = µAh × µV / 1e6；派生属性一次发「三连 GET」，保证三个数同批新鲜。
- 补丁：`boot/a-series/kernel/patches/qcom-battmgr-a145-patch.py`；构建轮 `a145-build.sh` 的门禁要求源码含
  `sm8350_bat_is_derived(psp)`，且 `qcom_battmgr.ko` 与 `usr/initramfs_data.cpio` 都含 `Y700-A145 battmgr derives` 标记。
- 实机：`charge_now=3516240 charge_full=3588000 energy_now=14944020 energy_full=15249000`，upower
  `Energy=14.93 Wh / EnergyFull=15.23 Wh`，`batteryRemainingTime` 不再是 0，熄屏复测不再弹窗。

### 功率也要派生（A146）

固件自报 `power_now=34.3 W`，而它自己给的 `current_now=-1.302 A`、`voltage_now=4.223 V` 只有 5.5 W，差一个数量级。
upower 直接把 `POWER_NOW` 当 `energy-rate`，于是「快满了却只剩 25 分钟」。

- 修法：SM8350 变体下 `POWER_NOW` 也走派生，`= |current_now| × voltage_now / 1e6`；
  `sm8350_bat_derived_props[]` 多带一个 `BATT_CURR_NOW`。
- 补丁：`boot/a-series/kernel/patches/qcom-battmgr-a146-patch.py`（叠在 A145 之上），构建轮 `a146-build.sh`。

### `.ko` 每次开机都会被重新铺

`/usr/lib/y700/*.ko` 由 initramfs 里的 `y700-patch.sh` 每次开机铺上去，只替换根文件系统里的 `.ko` 会在下一次开机被盖掉 ——
电池、音频这类驱动修复必须重出 boot 镜像才生效。


## 在设备上构建镜像

二代 57 GB eMMC 装不下单次 RUN 的 rootfs 提交（build 容器 diff + layer blob + 解包层需要约三份 ~12 GB），所以 rootfs 分成 5 段 RUN 分层提交：`10a-core` → `10b-desktop + 10c-apps` → `20 + 30` → `40 + 45 + 46` → `50-80`；`build_files/build.sh` 接受步骤号前缀，无参数时仍按原顺序跑全部步骤（上游 CI 的行为不变）。

- `/mirror` 是构建机提供的只读 bind mount：`gh-fetch.sh`、`10a/10c` 会优先读取其中预置的资产（terra RPM、FEX Arch rootfs、fedora-multimedia、heroic RPM），没有该挂载时自动回退到网络源。
- GitHub 资产可经一个上游 HTTP 代理下载：`build_files/gh-proxy.conf`（单行 `http://host:port`）或环境变量 `ARMADA_HTTP_PROXY`；该 conf 属于本地环境，不入库。
- `bootc-image-builder` 打包在 57 GB eMMC 上需要 zram 暂存（实测峰值 ~34 GB），成品 raw 38 GB、gz 约 7.2 GB。
- ESP 上的 `/KERNEL`（内核 + initramfs + `supported-dtbs`，含 `sm8475-lenovo-tb320fc`）由二代 boot 打包流程写入，见[二代引导文档](boot/README.md)。
## 源码与来源

| 文件 | 用途 |
|---|---|
| [设备配置](../../system_files/usr/lib/armada/devices/lenovo-tb320fc.conf) | 机型识别、270° 旋转、触屏选择 |
| [板级 DTS](../../packages/kernel/dts/sm8475-lenovo-tb320fc.dts) | 由 live vendor 设备树重构 |
| [tb320fc 内核覆盖层](../../packages/kernel/overlays/tb320fc/) | battmgr 派生属性、`lenovo,y700-sndcard` 匹配项、config 片段 |
| [基础设备树](../../packages/kernel/dts/sm8475.dtsi) | 派生自主线 sm8450.dtsi |
| [面板驱动补丁](../../packages/kernel/patches/0750-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch) | NT36523N 面板驱动 |
| [触摸驱动补丁](../../packages/kernel/patches/0751-input-touchscreen-import-Novatek-NVT36xxx-host-download-SPI-driver-for-Lenovo-TB320FC.patch) | NVT36xxx host-download SPI 触摸驱动 |
| [Y700 音频拓扑源](../../audio_topology/sm8475/Lenovo-Y700.m4) | AudioReach 拓扑（m4），生成 `Lenovo-Y700-tplg.bin` |
| [音频拓扑成品](../../system_files/usr/lib/firmware/qcom/sm8475/Lenovo-Y700-tplg.bin) | AudioReach 拓扑 blob |
| [UCM 用例](../../system_files/usr/share/alsa/ucm2/Lenovo/Y700/HiFi.conf) | `Lenovo-Y700`/HiFi 功放路由序列 |
| [/usr 覆盖层推送工具](usr-overlay/push.sh) | 把 `system_files/` 的板级修复同时写进 stage 与当前部署，并退役 `/usr/local` 副本、`/etc` 旧单元和 ExecStart drop-in（A185） |
| [kShimC 补丁](patches/boot/kshim-gen2-entry-protocol.patch) | 二代入口协议（自适应二/四代布局） |
| [boot 打包器](boot/build_android_boot.py) | MZ/PE 感知的二代 boot 打包器 |
| [edl-devices profile](../../build_files/edl-devices.json) | 构建机设备 profile（SM8475/capep） |
