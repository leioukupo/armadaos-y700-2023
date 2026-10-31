# TB710FU overlay patches

Applied in name order after `patches/series`. `source` and `upstream` follow
the convention of `packages/kernel/PATCHES.md`.

## Board DTS

- `dts/sm8650-lenovo-tb710fu.dts`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/sources/arch/arm64/boot/dts/qcom/sm8650-lenovo-tb710fu.dts
  upstream: unknown
  license: GPL-2.0-only. The file carries no notice of its own; the repository's [LICENSE](https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/LICENSE) (section 3) puts `kernel/sources/` under GPL-2.0. An SPDX line and an origin header were added; the rest is verbatim.
- `dts/sm8650-lenovo-tb710fu-board.dtso`
  source: armada
  notes: kShimC simple-framebuffer template, the 903 MHz GPU level, the unit's own ADSP/CDSP firmware paths, the TB710FU touch compatible; disables the original port's boot-log reservations and iris, and clears another unit's Bluetooth address.

## Display, GPU, backlight

- `patches/0101-dt-bindings-backlight-sy7758-add-follower.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: local
  notes: Documents `silergy,follower`, a second SY7758 that mirrors the primary chip's brightness.
- `patches/0102-backlight-sy7758-follower-chips.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: local
  notes: Follower chips register no backlight device and get every brightness update of the primary; boards with one chip are unchanged. A follower joins the mirror list only after its first brightness write succeeds. Burst mode is turned off on lenovo,tb710fu only.
- `patches/0103-drm-panel-add-novatek-nt36532.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/sources/drivers/gpu/drm/panel/panel-nt36532-wqhd-dual-dsi-dsc.c
  upstream: unknown
  notes: TB710FU NT36532 dual-DSI DSC panel, renamed panel-novatek-nt36532; Chinese comments translated, the empty remove callback and the placeholder module author dropped. Both links attach with devm_mipi_dsi_attach(); the physical size is 274x171 mm (12.7", 16:10) instead of the original 185x150.
- `patches/0104-drm-msm-dsi-bonded-trigger-on-dsi0.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: unknown
  notes: The original swapped the legacy bonded command trigger to DSI_0 for every board; here only lenovo,tb710fu does.
- `patches/0105-drm-msm-dsi-bootloader-controller-phy-state.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: unknown
  notes: Controller/PHY register state, vendor D-PHY timings, rescode and no sw_reset on underflow, gated on lenovo,tb710fu (the original applied them to every 7nm PHY and DSI host). The heartbeat, register dumps and TLMM pad reads are left out; only the 10 s re-application of the controller state remains.
- `patches/0106-drm-msm-dpu-dsc-width-round-up.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: unknown
- `patches/0107-drm-msm-a6xx-a750-without-ifpc.patch`
  source: armada
  upstream: local
  notes: The original disabled IFPC for every A750; a machine-matched catalog entry keeps it for the other SM8650 boards.

## Touch and pen

Novatek NT36532 touch IC with the Lenovo Tab Pen Plus, on SPI4. Its DT
compatible is set by the board overlay; the pen is enabled by the touch
overlay.

- `patches/0201-input-touchscreen-add-nt36532-spi.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/sources/drivers/input/touchscreen/NT36XXX_SPI
  upstream: unknown
  license: GPL-2.0-or-later (the Novatek notice in each file; an SPDX line was added). The repository's [LICENSE](https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/LICENSE) (section 3) keeps `kernel/sources/` under the kernel's terms.
  notes: Novatek vendor driver as carried by the TB710FU port, moved to nt36532/ (module nt36532_ts) with a clean Makefile; matches only `novatek,nt36532-ts-spi`, so it cannot claim the `novatek,NVT-ts-spi` boards of the NT36536 driver (nt36536_ts), and builds as a module only because the vendor sources share global symbol names with it. Fixed on top of the vendor code: bounds on the /proc/NVTSPI, edge_grid_zone and Pen_ID writes (NVTSPI is now root-only), single_release() for single_open() proc files, no world-writable proc nodes, the Android-only `novatek_ts` platform device dropped (it was unregistered more than once), the pen pressure range changed in place, remove/module-init cleanup, and the TB710FU FW health check run under `ts->lock` and stopped across system suspend. The vendor code's remaining warnings are unchanged.
- `dts/sm8650-lenovo-tb710fu-touch.dtso`
  source: armada
  notes: `novatek,pen-support`, as in the vendor dtbo. The driver registers `NVTCapacitivePen`, but the boot firmware update leaves pen scanning off; user space turns it on with `echo 1 > /proc/support_pen` (root).

## Bluetooth and WiFi

WCN7850 on PCIe0 (ath12k) and UART14 (btqca). No DT overlay: the board tree
describes both; the Bluetooth address is cleared by the board overlay.

- `patches/0301-Bluetooth-btqca-dt-bd-address.patch`
  source: armada
  upstream: local
  notes: On lenovo,tb710fu a non-zero DT local-bd-address replaces the serial-derived address (next to 0223 for Baldur).
- `patches/0302-power-sequencing-qcom-wcn-reset-pulse.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: unknown
  notes: Gated on lenovo,tb710fu (unconditional in the original).
- `patches/0304-wifi-ath12k-wcn7850-workarounds.patch`
  source: https://github.com/MeteoricmeteorLL/tb710fu-linux/blob/16e800d4f6e5cf4a8517900a9e11eec0ebc91bd3/kernel/patches/TB710FU-full-tree.diff
  upstream: unknown
  notes: Only what is active on the running unit, gated on lenovo,tb710fu (cached in ath12k_base at allocation, not looked up per packet): CE polling while HTC/WMI wait before the device is registered, firmware log off, STA power save off, hardware-crypto encrypt type. The group-frame IV flags of the original are left out: with the current firmware group frames arrive with their IV (mDNS, DHCP and ARP tested), and mac80211 keeps checking their PN. The periodic CE/DP poller, the A-MPDU refusal, the dedup and reorder switches and the debug counters of the original are left out. board_name is a read-only module parameter; it also names the first regdb lookup, which falls back to the bus name.

## Speakers

Four Awinic AW882xx amplifiers on i2c_hub_4 fed by SECONDARY_TDM_RX_0
(8 x 32-bit slots, slots 0-3). The amplifier driver is the shared
out-of-tree aw882xx.

- `patches/0401-ASoC-qcom-common-add-DAI-node-TDM-slot-helpers.patch`
  source: https://git.kernel.org/torvalds/c/1e844ecbc9cb
  upstream: https://git.kernel.org/torvalds/c/1e844ecbc9cb
- `patches/0402-ASoC-qcom-common-distinguish-missing-and-invalid-TDM-slots.patch`
  source: https://git.kernel.org/torvalds/c/0a9e00d5ebdf
  upstream: https://git.kernel.org/torvalds/c/0a9e00d5ebdf
- `patches/0403-ASoC-qcom-q6apm-lpass-dais-add-TDM-DAI-operations.patch`
  source: https://git.kernel.org/torvalds/c/4d0840175893
  upstream: local (adapted from 4d0840175893 by Prasad Kumpatla)
  notes: Rewritten for this tree, which has no MI2S clock control (no set_sysclk); also records the TDM interface derived from the DAI id.
- `patches/0404-ASoC-qcom-audioreach-configure-TDM-sink-endpoint.patch`
  source: armada
  upstream: local
  notes: MODULE_ID_TDM_SINK with PARAM_ID_TDM_INTF_CFG, matching what the vendor AudioReach userspace sends on TB710FU (traced on the unit); replaces the original port's full 7.3 sound/soc/qcom backport. Needs a topology whose speaker endpoint is MODULE_ID_TDM_SINK (0x0700100E); a topology with I2S_SINK never reaches this code.
- `patches/0405-ASoC-qcom-q6apm-four-speakers.patch`
  source: armada
  upstream: local
  notes: On lenovo,tb710fu the stream MFC/data-logging modules run at 4ch/S32 and the MFC maps FL FR FL FR, so the stereo stream reaches all four TDM slots. This applies to every MFC on the board; the card has the speaker link only, and a capture or second playback link would have to narrow it.
- `patches/0406-ASoC-dt-bindings-qcom-sm8250-add-tb710fu-card.patch`
  source: armada
  upstream: local
- `patches/0407-ASoC-qcom-sc8280xp-add-tb710fu-card.patch`
  source: armada
  upstream: local
  notes: TDM BE fixup (4ch/S32) and DSP_B/IB_NF CPU format for `lenovo,tb710fu-sndcard` only. The TDM endpoint has no bit-clock inversion setting, so IB_NF is sent as plain DSP_B; the values match what the vendor userspace programs.
- `dts/sm8650-lenovo-tb710fu-audio.dtso`
  source: armada
  notes: TDM1 pins, the four amplifiers (reset GPIOs, sound channels) and the sound card, as on the vendor Android.
