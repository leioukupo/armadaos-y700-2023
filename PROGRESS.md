# Y700 二代 (TB320FC / SM8475) 移植进度

目标：在 ArmadaOS Freedom（Linux 7.2.6 + kShimC 双系统）中新增对 **联想拯救者 Y700 二代 (TB320FC, PRC, 板级代号 `capep`)** 的支持。
硬约束：不得破坏现有 Android（Magisk root，BL 已解锁，A/B）；Android 保留 128 GB，其余全部给第二系统。

## 设备确认（live 实测，adb serial HA1WZJJ5）

- SoC: SM8475 = 第一代骁龙 8+（Qualcomm 内部代号 **Cape/CapeP**，msm-id 0x213，machine `CAPEP`）
- 内存 16GB；CPU 1×X2 + 3×A710 + 4×A510 (Kryo 780)；GPU Adreno 730
- live DTB = vendor_boot 第 3 个 (vb_02, "CapeP SoC") + dtbo_14 ("Cape MTP with PM8008")
- 显示: **Novatek NT36523N 1600×2560 FHD+ 144 Hz**（双 DSI bonded 2×800、C-PHY 3 lane、DSC 8bpc、外置 KTZ8866 背光）；面板供电已从 live regulator 树解码
- 触摸/笔: Novatek NVT36xxx host-download SPI（SPI4）
- PMIC: SPMI0: pmk8350@0 / pm8350@1 / pm8350c@2 / pm8350b@3 / pmr735a@4 / pmr735b@5 / pm8450@7；I2C: PM8008 @0x8/0x9（触觉，无主线消费方，禁用）
- 音频: WCD938x + CS35L45×2 + FSA4480；Wi-Fi: QCA6490（无主线驱动，PCIe/i2c 禁用）

## 状态总览

| 阶段 | 状态 |
|---|---|
| 0. live 设备逆向 (DTB/vendor_boot/boot 镜像解码) | ✅ 完成 |
| 1. `packages/kernel/dts/sm8475.dtsi`（派生自 mainline sm8450.dtsi 7.2.6） | ✅ 完成 |
| 2. 板级 DTS `sm8475-lenovo-tb320fc.dts` + kShim 交接 `.dts.patch` | ✅ 完成（离线验证） |
| 3. NT36523N 面板驱动（0224）+ NVT36xxx host-download 触摸驱动（0225） | ✅ 补丁已写，未实机 |
| 4. kShimC `tb320fc_android_defconfig`（270°/中文/星图/UFS native/EDL） | ✅ 完成 |
| 5. 二代 MZ/PE boot 打包器 `devices/lenovo-tb320fc/boot/build_android_boot.py` | ✅ 完成：实物 round-trip 18/18 + dummy 全链路 60/60 |
| 6. kShimC 二代入口协议补丁（自适应二/四代布局） | ✅ 完成：5 处编辑，`git apply --check` 通过，round-trip 字节一致 |
| 7. 系统集成 (edl-devices.json / sm8475.toml / lenovo-tb320fc.conf) | ✅ 完成（43 个 edl 测试通过） |
| 8. 文档与构建脚本（设备 README / boot README / build.sh） | ✅ 完成 |
| 9a. 远端编译 kShimC runtime（onesh MCP → comfyui-root） | ✅ 4MiB 通过，Gen2 补丁生效，sha 07068f0b… |
| 9b. 远端交叉编译内核 7.2.6 + 0224/0225 + TB320FC DTB（comfyui-root） | 🔄 v4 构建中（job b7a8ac36；v3 失败：0224 多行调用多一个括号、0225 七处 7.2.6 API 变化，均已修） |
| 9c. ArmadaOS 镜像 / EDL 安装包（podman 构建链） | ⏳ 待 9a/9b 产物 |
| 10. 实机：备份 boot/dtbo/vendor_boot → 刷 packed boot → 菜单验证 → 回 Android → `armada-installer install --userdata-gib 128` | ⏳ 等第 9 步产物 |

## 关键技术发现

- 二代容器内核是 **MZ/PE 格式**（64B MZ stub + 20B COFF + 160B 扩展头，entry RVA 0x24703E8；首字 `0xD102C3FF` 真 prologue），XBL 平拷贝（文件偏移 == 虚拟偏移）并跳 entry；四代是裸 `ARM\x64` Image，打包器不能共用。
- 容器头 v4（96 MiB）：`kernel_size`@0x08（stock 0x2C9A3E4）、debug-ramdisk 大小@0x0C（0x1D6760）/加载地址@0x10（0x1A000176）、`header_size`@0x14=1584、`version`@0x28=4；内核自 0x1000。
- stock 内核尾部（0x2C9C000 起约 2.1 MB）是原厂 debug-ramdisk；原厂 vbmeta 在 0x2E67600（896B，AVB `NONE`），footer major 1。
- 打包布局：`[stock 内核（入口区改）][4 MiB runtime][manifest]`，只改头 `kernel_size`。入口区（entry RVA 处）5 个 u64 字原地改写：+0x00=BL→shim、+0x10=packed 总长、+0x20=manifest 偏移、+0x28=manifest 大小、+0x30=shim 偏移；原值存 manifest 的 `MANIFEST_BASE_IMAGE` backup 槽位。
- kShimC runtime 自适应判据：word0 是 branch、word1 非 branch、backup word0 非 branch → 二代布局（恢复 5 字后从 +0 进入）；word1 是 branch → 经典布局（+4），四/五代行为不变。

## 日志




- v4 过程踩坑（已修）：
  1. tar 重建时目录项 typeflag 误写成 0（应为 5/DIRTYPE）→ 解包 No such directory；重建时显式设 DIRTYPE
  2. 0225 nt36xxx.c 的 hunk 头重建为 @@ -0,0 +3480 @@（缺 1,）→ GNU patch 宽松模式只应用了首行，编译出 1 行文件报 unterminated comment；已改为 @@ -0,0 +1,3480 @@
- v4 第三次构建 job 12eae942-fbad-4cc5-aae8-ac84277eab74 运行中（tar sha 4db35cda…）

### 2026-10-29 下午3（v3 构建失败 → v4 修复：0224 括号 + 0225 API 适配）

- v3 job 929ae03c 失败，错误两类：
  - 0224 panel-novatek-nt36523.c：31 处多行 mipi_dsi_dual_dcs_write_seq_multi 调用结尾是 ));（多一个括号，对 7.2.6 的 do-while 变参宏是语法错误）；单行调用 )); 形态正确。v4 去掉多出的括号，459 个调用全部括号配平
  - 0225 nt36xxx.c（7.2.6 API 变化）：
    1. CONFIG_SPI_MT65XX=y 时 mtk_chip_config 的 rx_mlsb/tx_mlsb/cs_pol 成员已删除 → 删除该 MediaTek 专用块（定义+使用）
    2. of_get_named_gpio_flags 已从主线删除 → 新增 nvt_of_get_named_gpio_flags 直接读 legacy 属性（DTB 的 novatek,reset/irq-gpio 为 [phandle int flags] 三 cell）
    3. TOOL_TYPE_STYLUS 来自 vendor touch_common.h → #define 映射为 BTN_TOOL_PEN
    4. active_panel 声明在 >=5.10 分支依赖 QCOM_PANEL_EVENT_NOTIFIER（不存在）→ 改为无条件声明，并加 #include <drm/drm_panel.h>（7.2.6 公开声明 of_drm_find_panel）
    5. spi_device.master 已移除 → 7.2.6 用 controller 成员 + SPI_CONTROLLER_HALF_DUPLEX
    6. spi_driver.remove 回调须 void → nvt_ts_remove 改 void
    7. 删除 vendor 的 MODULE_IMPORT_NS(VFS_internal_...) hack
- 7.2.6 关键确认：include/drm/drm_panel.h:339 有 of_drm_find_panel；struct spi_device 带 controller 指针（spi.c:581 赋值）；legacy GPIO（GPIOLIB_LEGACY=y）仍在，驱动其余 gpio_* 调用无需改
- kernel-pkg-v4.tar sha 5fa31286…（8550400B）+ remote_build_kernel_v4.sh sha e3003d2f… 已传远端
- v4 构建 job b7a8ac36-ed82-4cd4…（实际 ID b7a8ac36-ed82-4c78-9091-f2cfd7970962）运行中；ccache 大部分命中，预期 5-15 分钟

### 2026-10-29 下午2（内核 v3 构建启动）

- v2 构建失败根因：packages/kernel/dts/sm8475.dtsi 文件头注释块畸形（*/ 在第 4 行，其后是孤儿 * 行），5-515 行整体落入未闭合大注释，dtc 一直报 516 行 syntax error
- v3（kernel-pkg-v3.tar，sha b9c96625…）三处修复：
  1. sm8475.dtsi：*/ 移到描述块之后，恢复注释边界
  2. 0224-…NT36523N…patch：7.2.6 中 mipi_dsi.h 改名 drm_mipi_dsi.h 并新增 mipi_dsi_dual_dcs_write_seq_multi()；459 个单行调用补齐缺失的 )
  3. 0225-…NVT36xxx…patch：include 改 linux/input.h / linux/of.h（vendor 专有头在主线不存在）
- 远端 comfyui-root 环境完好：miniserve job d3e03ba2（0.0.0.0:4243）+ ufw 临时规则仍在；ccache 1.1G；v3 两文件经本机 8421 miniserve 传到远端，SHA 校验通过
- v3 内核构建 job 929ae03c-62dd-4cd4-a04c-fad206659f56 运行中（fresh 解包 → CRLF 归一 → apt → build-kernel.sh make -j8，ccache 大部分命中）
- 下一步：盯 job 日志 KERNEL_BUILD_DONE/报错 → miniserve 取回 armada-kernel-7.2.6.tar.zst → 9c 镜像打包（podman/BIB）→ 阶段 10 实机

### 2026-10-29 下午（comfyui-root 恢复，内核构建重启）
- comfyui-root 断电重启后 /tmp 清空、Tailscale 一度不通；用户恢复机器，现 ssh/egress/apt/cdn.kernel.org/github 全部可用
- **重建双向 miniserve 通道**：远端 miniserve job `d3e03ba2`（0.0.0.0:4243，服务 /tmp/y700，auth y700:***，ufw 临时规则 4243/tcp←10.1.16.0/21 重启后仍在）；本机 miniserve 0.35.0（pid 31576，0.0.0.0:8421，服务 y700-2nd/serve_out，Windows 临时防火墙规则 `miniserve-temp-y700-pc` 8421/tcp←10.1.16.0/21）。**收尾时两台都要关**
- **kernel-pkg-v2.tar 重建**（sha 285456b8…，8.55MB）：旧 tar 中 3 个过期文件用仓库最新版替换——`dts/sm8475-lenovo-tb320fc.dts`（input.h→input/input.h）、`dts/sm8475.dtsi`（补 `/*` 注释起始）、`config/armada-kernel.config.overrides`（+SM8475 段 7 项）；其余 421 项与仓库逐一 sha 一致
- 远端重传 5 文件（kernel-pkg-v2.tar / remote_build_kernel_v2.sh / linux-7.2.6.tar.xz 160MB / kshim-source.tar / kShimC.bin），sha 全部校验一致
- 内核构建 job `e7626cf6`：fresh 解包 + CRLF 归一 + apt（含 pahole）+ JOBS=8 交叉编译；内核 tarball 走本地缓存免下载

### 2026-10-29（kShimC 打通 + 打包成功）
- kShimC runtime 构建成功：CRLF 规范化 + libfdt sed 幂等化后，`git apply` 打上 Gen2 补丁（5 处），`build_runtime.py --config tb320fc_android_defconfig` → **4194304B，无未定义符号**，validation.json 落 artifacts
- 传输通道：comfyui-root 装 miniserve 0.35.0（job af938a0c，0.0.0.0:4243，basic auth），ufw 临时放行 10.1.16.0/21→4243；本机 10.1.20.93 同网段直传，kShimC.bin/.elf sha 全部一致（用完按用户要求关闭 miniserve + 撤 ufw 规则）
- **本地全链路打包成功**：真实 runtime + 真实 boot_a.img + 仓库 avbtool → `y700-2nd/packtest/boot-packed-real.img`（96MiB），**60/60 项检查通过**（round-trip/布局/AVB NONE 重封/manifest ABI），报告 `pack-real.report.json`
- 内核构建失败根因：远端无 pahole（PAHOLE_VERSION=0 → DEBUG_INFO_BTF 依赖断 → SCHED_CLASS_EXT 连带被否，脚本硬校验失败）；已 apt 装 pahole
- overrides 增加 SM8475 段（SM_GCC/DISPCC/GPUCC/CAMCC/VIDEOCC_8450 + INTERCONNECT_QCOM_SM8450；PINCTRL_SM8450 为 ARCH_QCOM 默认开启）；7.2.6 的 SM8475 全部复用 SM8450 驱动族

- 通过 onessh MCP（`oneshh`，ssh.20010327.xyz，OAuth Bearer）接入 7 台授权主机；选定 **comfyui-root**（100.103.166.118，Ubuntu 24.04 x86_64，16 核 / 14G / 375G 空闲，有 docker）
- kshim 源码树（5.6MB tar，sha 79916f74…）+ kshim 补丁 + 打包器 + `packages/kernel`（8.5MB tar，sha 737690f8…）已分块上传 /tmp/y700/ 并逐字节校验
- 踩坑：仓库工作树是 CRLF（Windows 签出），远端 `patch` 报 "different line endings"；解法 = 解包后对文本文件 `sed 's/\r$//'`（kshim 与 kernel 两个脚本都带）
- 踩坑：DEPENDENCIES.md 的 libfdt `sed` 不幂等（二次运行重复插行 → sha 不匹配）；已改为每次先重新 `git archive` 导出再 sed
- kshim job `e28bcd50`、kernel job `d750e3ee` 在 comfyui-root 后台运行；产物落 /tmp/y700/artifacts/（kShimC.bin 4MiB、armada-kernel-7.2.6.tar.zst）

- 修复 kShimC 补丁的 diff 序列化：不再用 difflib，改在临时 git 仓库里 `git diff` 生成；5 个 hunk 全部合法，真树 `git apply --check` 通过，scratch 应用 round-trip 字节一致
- 新增 `devices/lenovo-tb320fc/README.md`（状态/风险/双系统方案）与 `boot/README.md`（MZ/PE 布局、入口区协议、manifest ABI、AVB 重封、build.sh 输入契约）
- 新增 `devices/lenovo-tb320fc/boot/build.sh`（远端端到端：解包 → 打 kshim 补丁 → stock round-trip → runtime → pack）
- 重写本文件：旧版把面板误写为 Sharp 1440×3120 QHD+（实为 NT36523N 1600×2560 144 Hz）、代号误写 `asphalt`（实为 `capep`）、阶段状态过时

### 2026-10-28
- 确认 live DTB 组合 (vb_02 + dtbo_14)，纠正此前误判（vb_08/Waipio 为四代参考板，非本机）
- 解码全部 13 个基座 DTB + 72 个 dtbo；本机内存映射与 mainline sm8450 一致，仅 TLMM 基址不同（0xF000000 vs 0xF100000）
- 确认 7.2.6 已有 qcom,sm8475 gcc/camcc/dispcc/gpucc/videocc + sm8475 qmp-ufs-phy + socinfo SM8475
- 解码 boot_a.img：ANDROID! v4 容器内核为 **MZ/PE**（非裸 Image），需要 PE 感知的新打包器
- 建立 dtbo_14 完整 fragment 清单；从 FAN789/y700-lineageos24 找到 vendor 内核源码以移植面板驱动

### 2026-10-28（打包器验证）
- 对实物 `y700-2nd/device/boot_a.img` 的 round-trip：18 项检查全过（报告 `y700-2nd/device/round-trip.report.json`）
- dummy 4 MiB runtime + 仓库 avbtool 全链路 dry-run：60 项检查 0 失败，产出 96 MiB 成品（报告 `y700-2nd/packtest/pack.report.json`）
- 确认 entry=0x24703E8 为真入口；debug-ramdisk 区被 runtime 覆盖的风险已记录

### 2026-10-29 下午3（内核 7.2.6 构建成功 + 9c 镜像打包开工）

- **内核构建成功（v6）**：job `8401d518` exit 0，`/tmp/y700/artifacts/armada-kernel-7.2.6.tar.zst` 45MB（sha `c781dd9b…`），已取回本机 `y700-2nd/artifacts/`
  - v5（`d1f0d323` 前一次）DTB 已通过（ktz8866 phandle 标签修复生效），modpost 失败：`irq_to_desc` 7.2.6 不再导出给模块
  - v6 修复：0225 补丁 `nvt_irq_enable()` 删除 `irq_to_desc`/`desc->depth` 日志（纯调试用途），hunk 头 3478→3476；本地 git apply round-trip 通过
  - config：SM8475 段新增 `CONFIG_BACKLIGHT_KTZ8866=y`（主线 7.2.6 自带 kinetic,ktz8866 驱动）
  - 产物验证：`vmlinuz`（MZ/PE 78.6MB，与 stock 同格式）、`sm8475-lenovo-tb320fc.dtb`（含 lenovo,tb320fc-nt36523n / kinetic,ktz8866 / novatek,NVT-ts-spi）、`nt36523-spi.ko`（触摸）、面板驱动**内建**（modules.builtin: panel-novatek-nt36523.ko，vmlinuz 内确认 Lenovo 变体字符串）、31 个 DTB / 1596 个模块
- **steamos-manager spec 修复**：`%install` 原来只装 Source2-5，新增 `Source6: sm8475.toml` 与安装行（否则 Y700 设备配置进不了 RPM）
- **9c 镜像打包方案确定**：
  - 流程：`just build`（27 个包 REF，本地只需 kernel+steamos-manager，其余拉 `ghcr.io/armada-os/armada/pkg/<name>:<hash>`）→ BIB raw → make-bootimg + finalize → `output/armada-<ver>.img.gz`
  - 安装路径：SD 卡 raw 镜像 → ABL 选 SD 启动 → live 系统 `armada-installer install --userdata-gib 128`（内部 UFS 与 Android 共存：ESP 512M + BOOT 1G + root ≥32G + Android 128G）
  - **构建环境**：comfyui-root 有 KVM（Ryzen 7700/16 线程/14G/358G 盘）→ 用 **arm64 KVM 客户机**（Ubuntu 24.04 cloud，qcow2 120G，podman/buildah，hostfwd 2222/4244）全原生构建，避免 binfmt 模拟
  - 仓库同步：工作树 tar（2337 文件 + 30 符号链接→POSIX，440MB，sha `360e47ee…`）经本机 8421 miniserve 传输；远端 git init+commit（ARMADA_VERSION 需要 git HEAD）+ freedom-control 浅克隆
- **待办**：
  1. 远端仓库拉取 job `315579e5`、VM 准备 job `dbfee5c3`（进行中）
  2. 起 VM → guest 内：repo 同步 → kernel scratch 镜像（buildah from scratch，/kernel/ = tar.zst+sha256）→ steamos-manager（原生 arm64 dnf builddep+rpmbuild）→ rootfs（podman build --platform linux/arm64 --target armada-rootfs）→ BIB raw
  3. 取回 `armada-*.img.gz` → 阶段 10 实机
  4. 收尾：关远端 miniserve job `d3e03ba2` + ufw 4243 规则、关本机 miniserve pid 31576 + 防火墙规则；（新增）关 VM 的 qemu job + ufw 4244 规则

### 2026-10-29 下午4（设备备份 + boot 预打包 + 构建 VM）

- **设备新鲜备份**（`y700-2nd/device-backup-20261029/`）：boot_a/boot_b（96MiB，ANDROID!）、dtbo_a/b（24MiB+）、vendor_boot_a/b（96MiB，VNDRBOOT）；boot 分区块设备为 96MiB+80B，尾部 80B 属相邻分区，已截断到恰好 96MiB；与旧备份 `device/boot_a.img` 前 96MiB 逐字节一致
- **阶段 10 boot 预打包完成**：`packtest/boot-packed-20261029.img`（96MiB，60/60 检查通过）= 今天 boot_a + kShimC（07068f0b…）+ AVB NONE 重封；镜像就绪后即可 fastboot 刷
- **kShimC 结论**：kShimC 是通用 shim（读 bootloader 传参/DT，不嵌 DTB），`sm8475-lenovo-tb320fc.kshim.dts` 仅是参考镜像，现有 kShimC.bin 无需重编
- **9c 构建 VM**：comfyui（Ryzen 7700/16t/14G/358G 盘）KVM + **Fedora 44 aarch64 Base qcow2**（Tuna 源 528MB；cloud-images.ubuntu.com 不稳定已弃用）；nbd 预注入 ssh key + Tuna dnf 源 + sshd enable；cloud-init cdrom 装 podman/buildah；qemu 8 vCPU/8G，hostfwd 2222/4244，ufw 放行 4244
- 本机 shell 偏好：**PowerShell 7（pwsh）**
- 待办：VM 起来 → guest 拉仓库+内核产物 → kernel/steamos-manager 镜像 → rootfs → BIB → 取回 img.gz → 阶段 10

### 2026-10-29 晚（第十二次接手：UEFI 固件 + 构建 VM 真正启动）

- **onesh 新密钥可用**（旧 token 过期）；远端 `/tmp/y700` 完整保留（repo/440MB、artifacts/45MB、kbuild、vm/）；远端 miniserve 4243 进程存活（job 记录因 token 轮换丢失，无碍）
- **UEFI 固件解决**：Ubuntu noble 无 edk2-aarch64；Debian 包名是 **`qemu-efi-aarch64`**（pool/main/e/edk2/，Tuna 可达），edk2 2025.02，dpkg -x 出 `AAVMF/AAVMF_CODE.no-secboot.fd` + `AAVMF_VARS.fd`（各 64MB，64M vars）→ `/tmp/y700/vm/edk2extract/`
- **镜像布局真相**：Fedora 44 Cloud 是 btrfs **子卷布局**（top: root/boot/home/var；OS 内容在 `root` 子卷 = 顶层的 `/root` 目录）：sshd.service、cloud-init 全家、dnf5/podman/growpart 都在 OS 子卷里（之前查顶层 /usr 报 NO_SSHD_UNIT 是路径错）
- **launch3 job `a6212438`**：nbd 定制完成（parted GPT 警告未扩分区、tuna.repo/authorized_keys 写错层），qemu 起 12s 即 GUEST_DIED（无 sshd unit symlink + 分区未扩）
- **launch4 job `5bcc3df3`（运行中）**：sgdisk -e 扩分区到 120G + btrfs resize max；authorized_keys→OS `/root/.ssh`、tuna.repo→OS `/etc/yum.repos.d`、sshd wants symlink；ESP/grub 加 `console=ttyS0`；cloud-init cdrom（git/zstd/openssh-server/growpart + miniserve + runcmd growpart/btrfs resize）；ufw 4244；AAVMF pflash 启动
- **待办**：确认 VM 存活 → ssh 2222 → 9c_g1（repo+kernel-artifacts+miniserve4244）→ g2a → g2b → g2c → 取回 img.gz → 阶段 10 实机 → 收尾清理
- **launch11 成功（外援配方）**：`-drive if=none` + `virtio-blk-device,bootindex=1` + pflash 成对（no-secboot CODE + VARS 副本）+ 串口 ttyAMA0（PL011，之前误改 ttyS0）+ TCG（x86 无 aarch64 KVM，约 4 分钟到 login）→ **guest 开机成功**（`armada-build login:`、sshd active、btrfs / 已 120G——之前 sgdisk -e 其实已写入 GPT，kernel 读取正常）
- **NoCloud 光盘生效**：fedora 用户（wheel+sudo）已建、zstd/growpart 已装、git 安装中；tuna 源工作（海外 mirror 超时自动回退）
- 9c 脚本（g1/g2a/g2b/g2c）已 scp 到 guest /root/；g1 将拉 repo-worktree.tar（440MB，PC 8421）+ 内核产物（comfyui 4243）+ freedom-control 克隆 + 起 miniserve 4244
