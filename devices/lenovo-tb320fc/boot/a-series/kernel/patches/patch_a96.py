#!/usr/bin/env python3
"""A96: dpu_kms_global_obj_fini() runs twice when dpu_kms_hw_init() bails out.

On A94 the DPU got its DT nodes back and failed exactly where msm says it must:

    msm_dpu ae01000.display-controller: [drm] no IOMMU, bailing out
    [dpu error]dpu_kms_mmu_init failed: -19
    *ERROR* kms hw init failed: -19
    Internal error: Oops: 0000000096000044 [#1] SMP
    pc : drm_atomic_private_obj_fini+0x30/0x90
    lr : dpu_kms_destroy+0x64/0x108

dpu_kms_hw_init() jumps to error:, which calls _dpu_kms_hw_destroy(); then
msm_drm_init() unwinds and dpu_kms_destroy() calls _dpu_kms_hw_destroy() again.
drm_atomic_private_obj_fini() does list_del(), which poisons the node, so the
second call stores through LIST_POISON2 - a level-0 translation fault, matching
the ESR and the disassembly (stp x1,x4,[x0,#8] loads 0xdead000000000100/0122).

That is not just a pretty oops: it killed the kworker running
deferred_probe_work_func, so everything still waiting in the deferred queue -
above all ufshc - never probed.  A94/A95 booted with no /dev/sda at all and the
UFS root was unreachable, which looked like a storage regression.

Finalize the global state once; the state pointer doubles as the flag because
drm_atomic_private_obj_init() fills it and nothing else clears it.
"""
import sys

F = "/tmp/y700/kbuild/asphalt-linux/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c"
OLD = """static void dpu_kms_global_obj_fini(struct dpu_kms *dpu_kms)
{
	drm_atomic_private_obj_fini(&dpu_kms->global_state);
}
"""
NEW = """static void dpu_kms_global_obj_fini(struct dpu_kms *dpu_kms)
{
	/*
	 * A96: dpu_kms_hw_init() error: and msm_drm_uninit() -> dpu_kms_destroy()
	 * both land in _dpu_kms_hw_destroy(), and drm_atomic_private_obj_fini()
	 * poisons the list node it removes.  The second call stored through
	 * LIST_POISON2 and oopsed inside deferred_probe_work_func, which took the
	 * whole deferred queue with it - no UFS, no root.  Finalize once.
	 */
	if (!dpu_kms->global_state.state) {
		DPU_ERROR("global state already finalized, skip fini\\n");
		return;
	}
	drm_atomic_private_obj_fini(&dpu_kms->global_state);
	dpu_kms->global_state.state = NULL;
}
"""

text = open(F, encoding="utf-8").read()
if "global state already finalized" in text:
    print("A96 patch already present")
    sys.exit(0)
if text.count(OLD) != 1:
    print("A96 anchor missing: %d" % text.count(OLD))
    sys.exit(1)
open(F, "w", encoding="utf-8").write(text.replace(OLD, NEW))
print("A96 patched", F)
