# A 系列：把主线 Linux 一路引导到用户态（A1 → A35）

这里是 2026-11 那一轮 bring-up 的可复现快照。完整逐轮过程在仓库根的 `PROGRESS.md`
（按项目约定它是本地文件，`_` 前缀的临时脚本也不入库）。

## 现在到哪了

- **A34**：SD 卡（sdc2，`mmc@8804000`）在 **PIO 模式**下完全可用 ——
  `mmc0: SDHCI controller on 8804000.mmc using PIO` → `new UHS-I speed SDR104 SDXC card` →
  `mmcblk0: mmc0:544c USD00 58.9 GiB` → `p1 p2 p3 p4`。整份启动日志（`y700-boot.txt`，259,109 B）
  写进卡上的 FAT 卷再回读校验。这是第一个“initcalls 全部跑完 + 用户态活着 + 日志可回读”的里程碑，
  从此不再靠拍屏幕照片调试。
- **A35**：initramfs `switch_root` 进入卡上 ext4（p4，label `y700root`）里的 Alpine 3.24.4 aarch64
  rootfs，验证 stage-2 用户态真正接管。内核源码与 DTB 相对 A34 没有改动。

## 目录内容

- `mk_round.sh` —— 一轮（A35）的全流程驱动：config 断言 → DTB 手术 → initramfs cpio → `Image` →
  e15 boot.img 打包。每一步都带 `grep` 断言，任何前置条件不满足就整轮失败；成功标志是 `A35_ALL_OK`。
  文件头的大段注释就是各轮（A21/A22/A23/A24/A29/A33/A34）的推理链，是这份快照最有价值的部分。
- `patch_round.py` —— 给 initramfs `/init` 打补丁的两阶段写法（先把所有 `count==1` 校验完，再落盘）。
- `bootimg/mk_a1_dtb.py` —— 从 Lenovo 原厂 DTB 出发做设备树手术（见下节）。
- `bootimg/build_e15.py`、`bootimg/mk_e15_stub.py`、`bootimg/e15_layout.py` —— 把 kernel + dtb +
  ramdisk 装进 Android boot.img（GKI v4 header，保留 AVB footer）的打包器与 4 KiB 入口 stub。
- `initramfs/init` —— 诊断用 initramfs 的 PID 1（361 行）：SD 控制器 unbind/bind 重试、rescan、挂载、
  写日志、`switch_root` 交接；任何一步失败都退回 hold 循环，日志照旧写卡。
- `rootfs/init` —— 卡上 root 里的 stage-2 `/init`：挂 devtmpfs/proc/sys、挂 FAT 分区做日志出口、
  写 `y700-root.txt`、每 5 s 写一次心跳。
- `kernel/y700_ramlog.c` —— 我们加的内核文件：把 printk 记录镜像进三个 DRAM ring（其中一个在固件
  自己的 camera_region 里），跨 ABL 看门狗复位存活，下一轮启动在 initcall level 0 回放上一轮的最后几页。
- `kernel/LOCAL-KERNEL-MARKERS.txt` —— asphalt-linux 源码树里所有 `Y700-*` / `y700_*` 标记的行。
  那棵树不是 git 仓库（tarball 解出来的），所以这份索引就是本地改动的等价 diff。
- `kernel/config-essentials.txt`、`kernel/config-full.txt.gz` —— 该轮内核配置快照。

## 关键结论（为什么是这些改动）

1. **ABL 看门狗**：整机在 212–220 s 被固件复位。之前所谓“死在 9.25 s / 219 s”其实是自家分页控制台在
   `mdelay()` 里等拍照；`y700_pause=0` 之后所有 initcalls 在 2.19 s 跑完，于是才有约 200 s 真余量。
2. **interconnect@1700000（aggre2-noc）**：探针开始 10 ms 内必炸。做法是把 provider 节点 disable 并且
   **删掉全部 38 处 consumer 引用**（只 disable 不够：`sdhci-msm` 的 `dev_pm_opp_of_find_icc_paths()`、
   `qcom_scm`、`ufs-qcom` 会因为缺 path 而无限 `EPROBE_DEFER`），并让 `qcom_scm` 把“没有 path”当“不投票”。
3. **PDC（`interrupt-controller@b220000`）**：一旦 enable，`pinctrl@f100000` 探针 10 ms 内复位整板
   （`qcom-pdc.c` 会去戳 ABL 留在 down 状态的 0x0b220000 interconnect 窗口）。禁 PDC + 删 TLMM 的
   `wakeup-parent`，把 SPMI 中断改挂 GIC，TLMM 才绑得上，sdc2 才拿得到 pinctrl。
4. **SD 的 DMA/SMMU**：`strip_iommu_refs()` 剥掉 34 处 `iommus`/`iommu-map` 并 disable 了
   `iommu@15000000`，但硬件 SMMU 仍在翻译 stream `0x4a0`（节点带 `qcom,preserve-boot-mappings`，
   ABL 建的映射还在），于是 DMA 描述符/缓冲落到未映射 IOVA → 必炸。A34 在 `sdhci-msm.c` 里
   `host->quirks |= SDHCI_QUIRK_BROKEN_DMA | SDHCI_QUIRK_BROKEN_ADMA` 强制 PIO 就绕开了；
   想恢复 DMA，得放开 SMMU 节点并只给 mmc 放回 `iommus = <0x41 0x4a0 0x00>`。
5. **DTB 手术顺序**（`mk_a1_dtb.py`）：reserved-memory（ramoops/y700log/y700logc/splash/kshim）→
   关无关节点 → icc off + SPMI irq 改指 → 删 `wakeup-parent` → UFS freq-table 降频 → regulator 全
   always-on → 剥 iommu 引用 → SD 删 `required-opps`/`non-removable`/`cd-gpios` 加
   `broken-cd;` 与 `max-frequency = <25000000>` → 禁 `smp2p-*` 与 bluetooth 的 geni-uart。
6. **UFS 还没编进内核**：`mk_round.sh` 显式 disable `SCSI_UFSHCD/SCSI_UFSHCD_PLATFORM/SCSI_UFS_QCOM`。
   要把根放到机身存储，就得打开这三个 + `phy@1d80000`（`qcom,sm8475-qmp-ufs-phy`）并解决 SMMU。

## 安全边界

全程只写 `boot_b`，`boot_a` 从未碰过。回滚 = `fastboot set_active a`，或把 `boot_b-stock.img`
刷回去。Android 系统分区（128 GB 预算）不受影响。

## 复现

构建机上 `bash mk_round.sh`（脚本里 `K=` 是内核树、`B=` 是工作目录，都是绝对路径，按本机改）。
成功后产物 `boot-b-a35.img`：100,663,296 B，
sha256 `19b62405ac055c8eae1531eef69cb84669a41fbd63823ec9ad59fbca8096dd24`，
刷入 = `fastboot flash boot_b boot-b-a35.img && fastboot reboot`。
