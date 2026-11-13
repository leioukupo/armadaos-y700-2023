def iommu_cells_by_phandle(text):
    """phandle -> #iommu-cells, for every node that declares both.

    A decompiled node is brace-flat and the SMMU nodes of this board have no
    children, so one brace-free slice is the whole node.
    """
    out = {}
    for blk in re.findall(r"\{[^{}]*#iommu-cells[^{}]*\}", text):
        cells = re.search(r"#iommu-cells = <([^>]+)>;", blk)
        ph = re.search(r"phandle = <([^>]+)>;", blk)
        if cells and ph:
            out[ph.group(1)] = int(cells.group(1), 0)
    return out



def iommu_ref_phandles(text, prop, vals):
    """Every phandle an iommus / iommu-map property line references.

    A map property is a list of (rid-base, phandle, #iommu-cells specifier
    cells, rid-length) entries, so its stride is 3 + #iommu-cells of the target
    node - the stride drivers/of/base.c::of_map_id() and
    qcom_pcie_config_sid_1_9_0() (drivers/pci/controller/dwc/pcie-qcom.c) use.
    The vendor apps SMMU declares #iommu-cells = <2>, so the stride on this
    board is 5, and the old stride of 4 read

        iommu-map = <0x00 0x44 0x1c00 0x00 0x01 0x100 0x44 0x1c01 0x00 0x01>;

    as the phandles 0x44, 0x100 and 0x01.  None of them is the kept apps SMMU,
    so pcie@1c00000 and pcie@1c08000 lost the property even with the SMMU
    enabled.  qcom_pcie_config_sid_1_9_0() then returns 0 without touching
    PARF_BDF_TO_SID_CFG, the host leaves the BDF-to-SID table in bypass, and the
    WCN6855 endpoint reaches the SMMU on a stream that owns no context bank.
    Enumeration, BAR sizing, MSI and the MHI BHI handshake all survive that,
    because none of them writes to host memory; the first copy-engine DMA after
    ath11k has downloaded amss.bin is aborted.  That is the silent reset of
    A122-A124 and A129 (firmware inside the initramfs, dead 3-5 s in) and of
    A121 and A128 (insmod after the root is up, dead on the spot), while A126
    (ATH11K_PCI=y with no firmware in reach) stops at -110 without a DMA and
    boots.
    """
    if prop == "iommus":
        return vals[0::3]
    cells = iommu_cells_by_phandle(text)
    ph = vals[1] if len(vals) > 1 else None
    if ph in cells:
        stride = 3 + cells[ph]
        if len(vals) % stride == 0:
            got = [vals[i + 1] for i in range(0, len(vals), stride)]
            if got and all(g == ph for g in got):
                return got
        if cells[ph] == 2 and len(vals) % 4 == 0:
            # the 4-cell layout of_check_bad_map() tolerates, kept for parity
            got = [vals[i + 1] for i in range(0, len(vals), 4)]
            tail = [vals[i + 3] for i in range(0, len(vals), 4)]
            if got and all(g == ph for g in got) and all(t == "0x01" for t in tail):
                return got
    raise AssertionError("unparsable %s property: %s" % (prop, " ".join(vals)))


