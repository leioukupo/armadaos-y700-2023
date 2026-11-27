# TB320FC（Y700 二代）装机 / 还原 — 材料都在这一目录

这里放的是**上机操作**的全部脚本：EDL 全量还原、GPT 重建/切分/槽位钉住、root 镜像与 boot 载荷写入并读回校验、在机分区备份。
镜像与 rootfs 的构建脚本不在这里，在 `devices/lenovo-tb320fc/rootfs/`（`build-ufs-root.sh`、`ostree-first-root.sh`、`stage-adopt-bundle.sh`、`pack-image-state.sh`、`armada-ostree-*.sh`）；kShimC 的槽位打包工具在 `devices/lenovo-tb320fc/boot/kshim-slots/`。

> 先读 §0。这台机器的很多坑是"看起来是 A 其实是 B"，照抄别的机型的流程会直接把自己锁死。

## 0. 这台机器的硬事实（实测，别再重新发现一遍）

| 事实 | 后果 |
|---|---|
| fastboot 序列号 `HA1WZJJ5`；USB 上 `18d1:d00d` 就是它的 fastboot | 判"进系统了"要看 `17ef:xxxx`（MTP）或 adb，不是 `d00d` |
| UFS 有 6 个 LUN，**逻辑块 4 KiB**；`boot/…` 在 **LUN4**，`super/misc/metadata/userdata` 在 **LUN0** | `edl.py ws/rs` 的 sector 是 4 KiB 单位；`printgpt` 的 Offset ÷ 4096 = 起始 sector |
| `boot_a` lba=108422（LUN4，96 MiB）、`boot_b` lba=374511 | A 槽=ArmadaOS 载荷，B 槽=Android（kShimC 的约定） |
| `fastboot getvar all` 会把这台 XBL 卡死；`slot-bootable:*`、`fetch`、`oem help` 未实现 | 只能单条 getvar；**没法从 fastboot 把分区读出来备份** |
| `fastboot set_active a`（不带 `--`）会卡死 ABL，只能长按电源硬断电 | 一律 `fastboot --set-active=a` |
| `fastboot reboot recovery` 不写 misc，而是进 FFBM/firehose（`05c6:9008` 常驻） | 想出厂清除只能 `erase`，别指望 recovery 菜单 |
| 进 EDL：`fastboot oem reboot-edl`（`reboot edl` / `oem edl` 都是 unknown） | — |
| **没有任何 ABL 日志通道**（logfs 空 FAT12、logdump 全零、qmcs 空、spunvm 全零、uefivarstore 里没有 boot-next） | 起不来只能靠屏幕 + 排除法，见 §6 |
| GPT 属性位：Flags 的 **bit48-51=priority、bit52-55=retry、bit55=dont-boot-again** | 槽位状态是**磁盘上的 GPT 标志**，不是 misc |
| rom 的 `rawprogram4.xml` 里 `uefi_b/tz_b/abl_b/boot_b/devcfg_b` 全是 `filename=""` | **只做 rom 还原之后 `_b` 固件是零**。把 `_a` 标成 dont-boot-again（= 钉到 b）等于让 XBL 读零 → XBL 自己崩，直接进 PBL crashdump |
| crashdump（`05c6:900e`）的 Sahara 是**只读**：上传 loader → `0x93011004`，command mode → `END_TRANSFER`，`SAHARA_RESET_STATE_MACHINE(0x13)` → 也只是 `END_TRANSFER`；只有 `SAHARA_RESET_REQ(0x7)` 有效 | 能无限次软件重启（崩后几秒内 HELLO 窗口才 live），但**拿不到任何写权限**；XBL 崩了就没有 ABL，于是 fastboot / recovery / 那个五选项菜单全都不存在 |
| **音量键不是 EDL 触发**：冷上电（先长按 Power 20 s 真断电，再插线）分别按住 VolDown / VolUp / 双键 30 s，四种都是 20 s 后枚举 `05c6:900e` | 进 EDL 只有两条路：`fastboot oem reboot-edl`（需要 ABL 活着）或**拆后盖短接 EDL 测试点**。热复位不重采样按键，所以"按住键 + Sahara RESET"也无效 |
| 在 crashdump 会话里 `edl.py --memory=ufshcd rs/ws ...` 会**静默退化成 DDR 内存转储**，`rs/ws` 的参数被忽略 | 任何写之前先 `rs 0 6 /tmp/chk.bin --lun=4`，再确认偏移 4096 处有 `EFI PART`，否则就是在往空气里写 |
| `rs 0 6 primN.bin` 从 **LBA0** 开始，含 protective MBR | 写回必须 `ws 0`。`ws 1` 会把 MBR 那 4 KiB 盖到 GPT header 上 = 表直接损坏，二次变砖 |
| firehose 会话空闲几分钟就掉，掉之后 `rs` 会**静默不产出文件** | 分段做，每段先确认 `Mode detected: firehose`，再查文件大小 |
| `edl.py ws` 按 `os.stat(file).st_size` **逐字节流**，不认识 hole；而 ext4 每个 flex group 开头都有 inode table，322 GiB 的根只用 14 GiB 也一路写到最后一个 group | 直接刷稀疏镜像 = 几小时零字节。**先把文件系统缩到装得下（`ostree-first-root.sh` 末尾 resize2fs），上板第一次启动由 `armada-growfs.service` 在线长回整分区** |
| `e2image -r` 的 dump 也是稀疏到整个分区，而且**不含数据块** | 它既不小（照样 322 GiB 的 st_size）也不能刷：文件内容读回来全是零。`ufs-install.sh` 会显式忽略它 |

## 1. 目录内容

| 脚本 | 在哪跑 | 干什么 |
|---|---|---|
| `board-backup.sh` | **板子上**（安卓 root 或 ArmadaOS sudo） | 把 boot/vendor_boot/init_boot/dtbo/vbmeta/abl/xbl/misc + super 头 64 MiB + GPT 文本 dump 出来并 sha256。**任何 boot_*/vbmeta_* 写入之前必须先跑它** |
| `rom-flash.sh` | 构建机（板子在 9008） | 按 rom 自己的 rawprogram 逐条写（可续写，进度在 `done.txt`）。刻意跳过 rom 的 `gpt_*`，并把 `zeros_5sectors.bin` 单独处理 |
| `edl-restore.sh` | 构建机 | 全量回安卓：备份在机 GPT → `rom-flash.sh` → 清 DDR 训练缓存 → **用在机 GPT 重建 stock LUN0** → 校验 → **擦 userdata/metadata/misc** → reset |
| `gpt-stock.py` | 构建机 | 把在机 dump 改成 stock 形状：删 `linuxroot`、`userdata` 顶到 last usable LBA，重算 entriesCRC / headerCRC |
| `gpt-slice-pin.py` | 构建机 | 重装前的切分（userdata 缩到 128 GiB、腾出 `linuxroot`）+ 把 LUN4 所有 `_a/_b` 对的属性钉到目标槽（**不要用 firehose `setactiveslot`**，它把 dont-boot-again 写到另一侧）。**`--pin b` 现在必须带 `--i-verified-b-firmware`**，钉槽成功后顺手在 work 目录写 `undo-pin.sh`（先读回验明 firehose，再 `ws 0` 原样复原 + 比对 + reset） |
| `ufs-install.sh` | 构建机 | 一次装完：dump GPT → 切分+钉槽 → 写 GPT → 写 root（只写到最后一个数据 extent）→ 写 boot 载荷 → 读回校验（boot 全量、root 头尾各 64 MiB）→ 打印 root 的 LABEL/UUID 好和载荷 cmdline 对一遍 |

## 2. 不通用的输入：怎么提取你自己的

这些文件都不在仓库里，也不能替别人生成。每一件都写了"从哪来 / 怎么提 / 为什么不能用现成的替代"。

| 输入 | 从哪来 | 怎么提 | 陷阱 |
|---|---|---|---|
| EDL rom（本机用的 `zui_15.0.737`） | Lenovo 官方整包，解压到 `$EDL_ROM` | — | 它是 **Android 13 / ZUI 15** 一代，机内原装是 `ZUI_16.0.688`（从 `oemowninfo` 分区可读，LUN0 lba 8328）。降级要知情 |
| firehose programmer | rom 的 `contents.xml` 里 `<device_programmer>` | `xbl_s_devprg_ns.melf` | **不是** `prog_firehose_ddr.elf`（用它在 Sahara 阶段报 `0x29`） |
| `edl.py` | bkerler/edl | 建个 venv 装依赖即可 | 版本差异会影响 `qfil/ws/rs` 的参数名 |
| 在机 GPT（真正的几何） | 设备自己 | `edl.py rs 0 6 primN.bin --lun=N` + `rs (alt-4) 5 backN.bin --lun=N`；`alt` 从 primary header 偏移 32 读 | rom 的 `gpt_*.img`/`patch*.xml` 带的是包自己的几何，直接写会把备份表写错位置，XBL 认为表损坏 |
| `linuxroot` 分区条目（type/unique GUID） | 原机 GPT 备份（例：`preserive-*/gpt_prim0.bin`） | `gpt-slice-pin.py --ref-gpt <那份 dump>` | 没有参考表时用脚本内置默认（type `0fc63daf-8483-477e-89c4-89b87c83a0b6`，unique `79a8dffb-…`，就是这台机实际用的）；启动链靠 PARTLABEL/文件系统 UUID，unique GUID 不参与 |
| 安卓的 `boot_b/vendor_boot_b/dtbo_b/vbmeta_b` 原样备份 | **只能从跑着的系统里 dd**（fastboot 没有 `fetch`） | `install/board-backup.sh` | 这是 kShimC 打包的 `--stock-boot` base，也是 vbmeta 的唯一回滚点。**rom 里同名文件不是备份**：设备 OTA 过之后二者的 sha 全不同（A203/A204 已实测） |
| kShimC 源码与 runtime | 另一棵源码树（gen2 shim） | `devices/lenovo-tb320fc/boot/kshim-slots/build_runtime.sh <轮次> <a\|b>` → 4 MiB bin | 打包 base 必须是**当天从这台机 dump 的那份**；把已经带 shim 的镜像再打一次 = 叠两层，第二层永远不执行 |
| 内核 payload（7.3.0-rc6 + appended DTB + initramfs） | `packages/kernel/scripts/build-kernel.sh` 的产物 | 组 boot 容器时 vmlinuz 要带 DTB，且 cmdline 里的 `root=` 必须指向本次 root 的 UUID/PARTLABEL | 沿用上一份 boot blob 会因 root UUID 找不到根 → 上电直接回 fastboot（A162） |
| 载荷内核 `vmlinuz`（`build-ufs-root.sh` 的 `VMLINUZ_SRC`） | 板上 boot 分区里那段 kernel：`install/board-backup.sh` 的 boot dump，或 `unpack_bootimg` 拆 `boot_<slot>` 的 kernel 段 | 直接 `dd`/解出 kernel 段存成文件，`VMLINUZ_SRC=` 指过去 | 根镜像里没有任何内核文件（ABL 从裸 boot 分区取内核，镜像里的 kernel 包不带 Image）→ `armada-ostree-adopt.sh` 报 `ostree cannot deploy this tree`，离线采纳第一步就死（A224） |
| 内核模块树 + 打过补丁的 .ko | 你自己的内核构建（`MODS_SRC`、`KO_PATCHED_SRC`，见 `build-ufs-root.sh` 头部） | `build-ufs-root.sh` 会把它们放进 `/var/usrlocal/lib/y700-73mods/$(uname -r)` | 镜像里的内核版本 ≠ 板上跑的内核版本时，模块必须按 `uname -r` 对齐 |
| 容器镜像 + LAN registry + chunkah chunked 目录 | `just build` → `podman push localhost/armada:<tag> 192.168.31.x:5000/armada:<tag>` | `stage-adopt-bundle.sh <tag>` 会拿 registry 的 `manifest.json/config.json` 并按 `layers[0].digest` 取 `base-layer.tar` | 采纳必须在 registry 里能解析到同一份 manifest；chunkah 的 `blobs/sha256/<digest>` 命中就免下载 |
| `factory-etc.tar` / `factory-var.tar` | 镜像自己 | `pack-image-state.sh --image <本地镜像> --out <bundle>`（`build-ufs-root.sh` 已经自动调它） | 缺 `/var` → commit 里 /var 是空骨架 → Armada tools 的 Steam repair 报 `No such file or directory: /var/home/armada`（A221） |
| Magisk 修补过的 boot（拿安卓 root） | 板上提 boot → Magisk App 修补 → 刷回 | `dd if=/dev/block/by-name/boot_b of=/data/local/tmp/boot.img` → 修补 → `fastboot flash boot_b` | 别拿 rom 的 boot.img 去修补：版本与 super 不配套 |

## 3. 从砖回到安卓（本次实测流程）

```sh
# 0) 备份！跑着的系统里先 board-backup.sh，否则 boot_*/vbmeta_* 没有回滚点
# 1) 进 EDL
fastboot -s HA1WZJJ5 oem reboot-edl
# 2) 全量还原（含 rom 52 条写、DDR 清零、stock GPT、擦 data）
EDL_ROM=/path/rom LOADER=/path/xbl_s_devprg_ns.melf install/edl-restore.sh
```

关键：**擦 `userdata` + `metadata` + `misc` 不是可选项**。rom 自带的 `userdata_*.img`/`metadata.img` 是老几何 + 旧 FBE keyblob，写上去之后每个槽都会回落 fastboot（A204：这就是 Lenovo 那句"恢复出厂设置才能开机"的意思）。

### 3.0 先分清是哪一层崩了（决定 §3 能不能用）

- 屏幕上还有 Lenovo logo / 菜单，USB 上能看到 `18d1:d00d` → ABL 活着，走下面的正常流程。
- USB 只有 `05c6:900e`（crashdump）而且按键全部无效 → **XBL 崩，ABL 根本没跑**。`oem reboot-edl` 不存在，fastboot / recovery / 五选项菜单都不存在，§3 无法开始，只能硬件 EDL（拆后盖短接测试点）。
- 到这一步别再硬按按键耗电池，先长按 Power 关机，等拿到短接条件再动。

拿到 9008 之后，一次钉槽只要 11 个扇区就能复原，备份表起始 LBA 由 `gpt-slice-pin.py` 写进 `undo-pin.sh`：

```sh
LOADER=/path/xbl_s_devprg_ns.melf GPTDIR=$WORK/gptbak sh $WORK/undo-pin.sh
```

另外 rom 的 rawprogram 里 `boot.img/vendor_boot.img/dtbo.img/vbmeta.img` 只落在**一个槽**（本机是 boot_a）。要让另一槽也自洽，得自己补齐：

```sh
for p in boot vendor_boot dtbo vbmeta; do fastboot flash ${p}_b $EDL_ROM/$p.img; done
fastboot --set-active=b
```

## 4. 重装 ArmadaOS，并且**第一次启动就是 ostree 部署**

```sh
# 1) 镜像 + registry
just build                                     # 产 localhost/armada:<tag>
podman push localhost/armada:<tag> 192.168.31.4:5000/armada:<tag>
# 2) bundle（registry 元数据 + base-layer + 板端脚本 + factory-etc/var tar）
devices/lenovo-tb320fc/rootfs/stage-adopt-bundle.sh <tag> --out /srv/y700/bundle
# 3) 扁平 root 镜像（顺手产 factory-*.tar）
# 载荷内核：build-ufs-root 把它放进 /usr/lib/modules/<kver>/vmlinuz，采纳要有它才写得出一致的 BLS
VMLINUZ_SRC=/srv/y700/a207/boot/vmlinuz-7.3.0-rc6-from-boot_a \
devices/lenovo-tb320fc/rootfs/build-ufs-root.sh localhost/armada:<tag> /srv/y700/out
# 4) 离线采纳 + 缩到可刷尺寸：让镜像本身第一次启动就落在 composed 根上
#    默认 SHRINK_MARGIN=8：缩完留 8 GiB 空闲，够第一次启动写 /var（万一 grow 失败也不堵死）
devices/lenovo-tb320fc/rootfs/ostree-first-root.sh /srv/y700/out/root-armada!<tag>.img \
    --image-ref ostree-unverified-image:docker://192.168.31.4:5000/armada:<tag> \
    --bundle /srv/y700/bundle
# 5) 上机（写 linuxroot + boot 载荷 + 钉槽 + 读回校验）
ROOT_IMG=/srv/y700/out/root-armada!<tag>.img BOOT_IMG=/srv/y700/out/boot_a-<轮次>.img \
PIN=a install/ufs-install.sh
```

第 4 步之后，**不要再在板上跑 `adopt-run-board.sh`**——那是给"扁平根先装、之后采纳"的旧路径留的。采纳离线做的东西（`/ostree/repo`、deployment、origin 的 `container-image-reference`、BLS `/boot/loader.N/entries/ostree-*.conf`、`/init`、`/etc/armada/ostree-boot=yes`）都在镜像里，第一枪就该是 `COMPOSED root=`。

第 4 步的末尾会把镜像**缩小**（resize2fs）而不是做 sha256：稀疏的 322 GiB 镜像刷下去是几小时的零，缩完只剩二十几 GiB 且连续。缩完它自己会再跑一遍 `--check-only` 复验，绿了才打印 `OSTREE_FIRST_OK`。代价在板上：第一次启动 `armada-growfs.service` 在线 `resize2fs` 长回整个 `linuxroot` 分区，长成功就把 marker（`/etc/armada/need-growfs` 与 `/var/lib/armada/need-growfs`，合成根只看得见后者）摘掉，之后永远不再动；长失败也不影响启动，只是根还停在缩小的尺寸。验收时看 `findmnt -no SIZE /` 是不是 ~322 GiB。

起来之后这样验收：

```sh
findmnt -no SOURCE,FSTYPE /          # 期望 /dev/sdXn[/sysroot/ostree/deploy/default/deploy/<id>.0]
cat /etc/armada/ostree-boot          # yes
cat /armada-ostree/boot.log          # 有 COMPOSED root=…，不是 FALLBACK marker
ostree admin status; bootc status    # 有 Version / image reference / rollback
ls /var/home/armada/.local/share/Steam/steam.sh   # factory Steam 在 commit 里，repair 才有的可导
```

## 5. 回滚点清单（每次装机前后各看一眼）

* 板上 `/root/kshim-rollback/` 是 **tmpfs**，重启就没 → 当场 `scp` 回构建机永久目录。
* 构建机上永久保留：当天 dump 的 `boot_*-live.img`、`gptbak/prim*.bin back*.bin`、`alt*`、原机 `preserive-*`（6 个 LUN 的主备 GPT + xbl）。
* `sha256sum` 清单和 `BUNDLE.txt` 一起存，别只存文件。

## 6. 起不来时的排查顺序（无日志，只能排除）

1. `misc`：读回看有没有 `ffbm-00` / legacy boot command（LUN0 lba 89480，256 扇区）；有就清（`erase misc` 或写零）。
2. GPT 属性位：`printgpt --lun=4` 看 `boot_a/boot_b` 的 priority/retry/dont-boot-again；`gpt-slice-pin.py --pin` 修。
3. 内容是否真在目标分区：`rs <lba> <sect>` 读回 sha 比对（这台机器没有任何其它反馈渠道）。
4. 供电：低电量下 ABL 能停在 fastboot 但拒绝拉起系统，形状与"每个槽都失败"完全一样（A203）。先只走充电口充 ≥40 min。
5. **ARB / rollback index**：做过系统更新的机器 RPMB 里的最小回滚索引会抬高，旧 rom 的 `vbmeta` 可能被拒。2026-11-26 这次「rom 全量 + DDR 清零 + stock GPT + 擦 data + 两槽 boot 链成套」之后仍然回 fastboot，剩下的头号嫌疑就是它——验证办法是**只用机内 OTA 那一代的 boot 链**（从在机备份 `board-backup.sh` 的产物刷回）而不是 rom 的，看能不能起。

## 7. 已知不做的

* 手写笔：上游 7.2.6 的内核补丁在二代起不来，已放弃。
* G9 手柄非充电口：route B（自编内核 + 移植 vendor `phy-msm-snps-eusb2` 的 EUD/APB 序列）还没做；现状是充电口可用、非充电口只供电不识别。