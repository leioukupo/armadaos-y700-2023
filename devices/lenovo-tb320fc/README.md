# 联想拯救者 Y700 二代

ArmadaOS Freedom 为 Y700 二代提供 kShimC 多系统启动、Steam 游戏模式和面向平板的输入与外设支持。本页记录 TB320FC 的功能状态、已知问题和开发入口。

| 项目 | 配置 |
|---|---|
| 型号 | TB320FC |
| SoC | Qualcomm SM8475（第一代骁龙 8+，内部代号 Cape/CapeP） |
| 设备树标识 | `lenovo,tb320fc`、`qcom,sm8475` |
| 内核 | ArmadaOS Freedom 统一 Linux 7.2.6 |
| Armada Control 配置 | `lenovo-tb320fc`，无风扇平板 |

## 功能状态

| 功能 | 当前状态 |
|---|---|
| kShimC 启动菜单 | 未实机验证（270° 旋转、中文、星图主题、电源/高级操作已配置） |
| Android 启动 | 未实机验证；要求 bootloader 已解锁（AVB `NONE` 重封） |
| 机身 Linux | 未实机验证 |
| 触屏/手写笔 | 未实机验证（NVT36xxx host-download SPI 驱动已移植，设备名 `NVTCapacitiveTouchScreen`） |
| Wi-Fi | 已启用（待实机验证）：QCA6490 = WCN6855 包，走主线 `ath11k` PCI 路径，内核 `CONFIG_ATH11K=y`/`CONFIG_ATH11K_PCI=y`，设备树 `&pcie0` + `wifi@0 compatible = "pci17cb,1103"` 已使能并带 10 路 PMU 供电；固件由 `atheros-firmware` 提供（`/usr/lib/firmware/ath11k/WCN6855/hw2.0/{amss,board-2,m3,regdb}.bin.xz`） |
| 触觉反馈 | PM8008（i2c5）尚无主线消费方，节点保持禁用 |
| 内置手柄 | 本机无内置手柄，`ARMADA_BUILTIN_GAMEPAD=0`，不等待 CompositeDevice |

以上功能均**尚未实机验证**。镜像层面的工作（live 逆向、boot 镜像解码、打包往返与 dry-run 全链路）已完成，见[二代引导文档](boot/README.md)。

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
| [DTS 适配补丁](../../packages/kernel/dts/sm8475-lenovo-tb320fc.dts.patch) | kShim 交接（SMMU 解绑等） |
| [基础设备树](../../packages/kernel/dts/sm8475.dtsi) | 派生自主线 sm8450.dtsi |
| [面板驱动补丁](../../packages/kernel/patches/0750-drm-panel-nt36523-add-Lenovo-TB320FC-NT36523N.patch) | NT36523N 面板驱动 |
| [触摸驱动补丁](../../packages/kernel/patches/0751-input-touchscreen-import-Novatek-NVT36xxx-host-download-SPI-driver-for-Lenovo-TB320FC.patch) | NVT36xxx host-download SPI 触摸驱动 |
| [kShimC 补丁](patches/boot/kshim-gen2-entry-protocol.patch) | 二代入口协议（自适应二/四代布局） |
| [boot 打包器](boot/build_android_boot.py) | MZ/PE 感知的二代 boot 打包器 |
| [edl-devices profile](../../build_files/edl-devices.json) | 构建机设备 profile（SM8475/capep） |
