# A226 救援包：把 LUN4 的 11 个扇区写回去

板子（TB320FC / fastboot 序列号 `HA1WZJJ5`）现在的状态：停在 PBL crashdump，USB 上只有 `05c6:900e`。
崩的是 **XBL**，所以 ABL 从来没跑起来 —— 没有 fastboot、没有 recovery、没有 boot qmmi/boot FFBM 那个五选项菜单，
`fastboot oem reboot-edl` 自然也不存在；音量键（VolDown / VolUp / 双键 / 冷上电长按 30 s）经实测都不是这台机的 EDL 触发。
唯一入口是**拆后盖短接 EDL 测试点后上电**，让机子枚举成 `05c6:9008`。原因和完整复盘见 PROGRESS A226、`install/README.md` §0。

## 包里的东西

| 文件 | 是什么 |
|---|---|
| `gptbak/prim4.bin` (24576 B) | 钉槽**之前**（2026-11-26 17:13 现场 dump）的 LUN4 primary 表，从 **LBA0** 起 = protective MBR + header@1 + 96 条条目@2..4 |
| `gptbak/back4.bin` (20480 B) | 同一时刻的 LUN4 备份表，从 **LBA1572859** 起（`alt4=1572863`，backup entries 从 alt-4 起，共 5 扇区）|
| `gptbak/prim0.bin` / `back0.bin` | LUN0 的两份表。本次没被改过，纯保险 |
| `undo-pin.sh` | 写回流程：先读回验明确实是 firehose/UFS 模式，再 `ws 0` / `ws 1572859`，逐字节 `cmp`，最后 reset |
| `watch-edl-mode.sh` | 守着 USB：见 `05c6:9008` 就自动跑上面整套；见 `18d1:d00d` 就 `fastboot --set-active=a` + reboot |
| `krash-cycle.py` | 崩溃后几秒的 Sahara HELLO 窗口里发 `RESET_REQ`。只能当"无限重启按钮"，**没有任何写能力** |
| `SHA256SUMS` | 上面文件的哈希（原件同时在 comfyui `/srv/y700/rescue-kit`）|

## 拿到 9008 之后（在能插板子的那台 Linux 上，装好 bkerler/edl 的 venv）

```sh
LOADER=/path/xbl_s_devprg_ns.melf DURATION=1800 bash install/rescue/watch-edl-mode.sh
```

手动等价（一条都别跳，尤其第一条的验模式）：

```sh
E="edl.py --loader=$LOADER --memory=ufshcd"
$E rs 0 6 /tmp/chk.bin --lun=4
dd if=/tmp/chk.bin bs=4096 skip=1 count=1 2>/dev/null | grep -q EFI || { echo "不是 firehose/UFS 模式，别写"; exit 1; }
$E ws 0 gptbak/prim4.bin --lun=4
$E ws 1572859 gptbak/back4.bin --lun=4
$E rs 0 6 /tmp/ok4.bin --lun=4 && cmp /tmp/ok4.bin gptbak/prim4.bin && echo PRIMARY_OK
$E rs 1572859 5 /tmp/okb.bin --lun=4 && cmp /tmp/okb.bin gptbak/back4.bin && echo BACKUP_OK
edl.py --loader=$LOADER reset
```

两个必须记住的坑：
- **`ws 0`，不是 `ws 1`**。`prim4.bin` 从 LBA0 起、含 protective MBR；从 LBA1 写会把 MBR 盖到 GPT header 上，表直接损坏，二次变砖。
- 在 crashdump 会话里 `edl.py --memory=ufshcd rs/ws ...` 会**静默退化成 DDR 内存转储**，参数被吃掉、进度条照样 100%。所以写之前必须先读回、确认偏移 4096 处有 `EFI PART`。

写成功 + reset 之后应该直接出 Lenovo logo 进安卓（`_a` 那套固件 + rom 的 `boot_a`）。root 会丢（救援前那块 boot_a 是 rom 原装的），要 root 再按 `install/README.md` §2 的 Magisk 流程来一遍。
接着重装 ArmadaOS 走 `install/README.md` §4，并且**只用 `PIN=a`**：rom 只把固件写进 `_a`，`uefi_b/tz_b/abl_b` 是零，钉到 b 就是这次变砖的原因。

## 给维修店的说法

高通平台的标准做法：后盖拆开，主板上有一对 EDL/download 测试点，短接后上电（或短接瞬间插 USB），机器在 PC 上枚举成 `05c6:9008` 即可。整个修复只需要接上 USB 后跑 1 分钟命令，不拆屏幕、不换件。