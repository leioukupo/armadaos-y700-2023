# TB320FC board overlay (Lenovo Legion Y700 Gen2, SM8475)

Build from `packages/kernel` with:

```sh
KERNEL_OVERLAYS=tb320fc ./scripts/build-kernel.sh
```

The kernel release becomes `7.2.6-tb320fc`, so its modules install in their own
`/usr/lib/modules/<release>` directory. The default build is unchanged.

This overlay carries the two board-specific kernel changes that the shared
`patches/`, `dts/` and config fragment do not cover. Everything else about the
board (dual-DSI NT36523N panel, NVT36xxx SPI touch, WCN6855 Wi-Fi power
sequencing, PMIC GLINK, KTZ8866 backlight) is already in the shared tree.

## patches

| Patch | Why |
|---|---|
| `tb320fc-01-qcom-battmgr-derived-props.patch` | The SM8475 ADSP fuel-gauge service answers the per-property protocol but never fills `power_unit`, and its `sm8350_bat_props` table has no `ENERGY_*`; its own `POWER_NOW` is off by an order of magnitude. KDE's Solid backend computes the level from `Energy`/`EnergyFull`, so it reports an empty cell right after the panel wakes from a DPMS blank and powerdevil sleeps the session. The patch batches the four firmware reads (SOC, voltage, coulomb counter, current) that the derived values are built from, and derives `CHARGE_*`/`ENERGY_*`/`POWER_NOW` from them. Measured on device: PROGRESS.md "A145 修法" and "功率也要派生 (A146)". |
| `tb320fc-02-sc8280xp-y700-card.patch` | The AudioReach machine driver takes the topology path from the DT match entry: `qcom/<driver_name>/<card->name>-tplg.bin`, with `card->name` read from the DT `model` (`Lenovo-Y700`, so `qcom/sm8475/Lenovo-Y700-tplg.bin`). Without an entry for `lenovo,y700-sndcard` the card never binds and there is no sound card at all. The MI2S format this driver already sets for `PRIMARY_MI2S_RX` matches the stock topology, and the MI2S input clock comes from the `i2s_clk` clock on the card's DT node. |

## config

`config/tb320fc.config` keeps the ADSP/AudioReach speaker chain and ath11k as
modules. Built-in ath11k probes from the initramfs, where the firmware is not
reachable, and re-binding PCIe0 after that failed probe raises
`PCIE_SOC_GLOBAL_RESET`, which powers the tablet off (PROGRESS.md A120-A130).
The audio chain has to come up in dependency order after the ADSP, which the
core only does from user space once initcalls are done; `usr/libexec/tb320fc/audio`
does it in the running system.

## firmware

Not in the kernel package: the board blobs (`adsp.mdt` + its segments, the
A730 zap shader, the GMU/`sqe` pair, the two CS35L45 protection images and
`novatek_ts_fw.bin`) ship in `system_files/usr/lib/firmware/`, with their
provenance in `system_files/usr/lib/firmware/qcom/sm8475/lenovo/tb320fc/NOTICE.lenovo-firmware`.
The GPU ones have to reach the initramfs as well, because `DRM_MSM` is built-in
and asks for them during initcalls; `system_files/usr/lib/dracut/modules.d/92armada-gpu-firmware`
does that. The ADSP, cs35l45 and touch firmware are requested by modules, so the
real root is enough for them.
## Not here

The board file `dts/sm8475-lenovo-tb320fc.dts` lives in the shared `dts/`
directory, because `system_files/usr/lib/armada/supported-dtbs` selects it by
name and the default build must ship it too. It enables the Adreno A730 (with
the stock zap shader), the ADSP remoteproc with its firmware name, the
AudioReach sound card with two CS35L45 amps, PMIC GLINK with both Type-C
connectors, and the FSA4480 SBU switch. Camera (camss/cci/iris) stays out: no
mainline SM8475 camera stack here.