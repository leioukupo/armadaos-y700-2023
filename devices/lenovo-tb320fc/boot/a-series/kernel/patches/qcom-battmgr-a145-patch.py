#!/usr/bin/env python3
# Y700-A145: teach qcom_battmgr to answer the charge/energy pair for the
# SM8450 (sm8350 variant) firmware, which never fills power_unit.
import sys

MARK = "Y700-A145"
EDITS = [
(
"""#include <linux/math.h>
#include <linux/units.h>""",
"""#include <linux/math.h>
#include <linux/math64.h>
#include <linux/units.h>"""
),
(
"""	[POWER_SUPPLY_PROP_CHARGE_CONTROL_START_THRESHOLD] = BATT_CHG_CTRL_START_THR,
	[POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD] = BATT_CHG_CTRL_END_THR,
};""",
"""	[POWER_SUPPLY_PROP_CHARGE_CONTROL_START_THRESHOLD] = BATT_CHG_CTRL_START_THR,
	[POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD] = BATT_CHG_CTRL_END_THR,
	/* %s: these four are derived, they just need the coulomb counter fresh */
	[POWER_SUPPLY_PROP_CHARGE_NOW] = BATT_CHG_COUNTER,
	[POWER_SUPPLY_PROP_CHARGE_FULL] = BATT_CHG_COUNTER,
	[POWER_SUPPLY_PROP_ENERGY_NOW] = BATT_CHG_COUNTER,
	[POWER_SUPPLY_PROP_ENERGY_FULL] = BATT_CHG_COUNTER,
};

/*
 * %s: the SOC, the battery voltage and the coulomb counter are the three
 * firmware properties the derived pair is built from.
 */
static const u8 sm8350_bat_derived_props[] = {
	BATT_CAPACITY,
	BATT_VOLT_NOW,
	BATT_CHG_COUNTER,
};

static bool sm8350_bat_is_derived(enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_NOW ||
	       psp == POWER_SUPPLY_PROP_CHARGE_FULL ||
	       psp == POWER_SUPPLY_PROP_ENERGY_NOW ||
	       psp == POWER_SUPPLY_PROP_ENERGY_FULL;
}""" % (MARK, MARK)
),
(
"""	prop = sm8350_bat_prop_map[psp];

	mutex_lock(&battmgr->lock);
	ret = qcom_battmgr_request_property(battmgr, BATTMGR_BAT_PROPERTY_GET, prop, 0);
	mutex_unlock(&battmgr->lock);

	return ret;
}""",
"""	prop = sm8350_bat_prop_map[psp];

	mutex_lock(&battmgr->lock);
	if (sm8350_bat_is_derived(psp)) {
		int i;

		ret = 0;
		for (i = 0; i < ARRAY_SIZE(sm8350_bat_derived_props); ++i) {
			int r = qcom_battmgr_request_property(battmgr, BATTMGR_BAT_PROPERTY_GET,
							      sm8350_bat_derived_props[i], 0);
			if (r < 0)
				ret = r;
		}
	} else {
		ret = qcom_battmgr_request_property(battmgr, BATTMGR_BAT_PROPERTY_GET, prop, 0);
	}
	mutex_unlock(&battmgr->lock);

	return ret;
}"""
),
(
"""	else
		ret = qcom_battmgr_bat_sm8350_update(battmgr, psp);
	if (ret < 0)
		return ret;

	switch (psp) {""",
"""	else
		ret = qcom_battmgr_bat_sm8350_update(battmgr, psp);
	if (ret < 0)
		return ret;

	/*
	 * %s: this firmware answers the per-property protocol and never fills
	 * power_unit, so battmgr->unit stays mWh and the charge/energy cases
	 * below answer -ENODATA.  KDE's Solid power backend works out the
	 * battery level as Energy/EnergyFull, so with no energy pair at all the
	 * desktop believes the cell is empty and pops "battery is very low, the
	 * system will sleep in 60 seconds" whenever it re-checks - for example
	 * right after the panel comes back from a DPMS blank.  The ADSP does
	 * give a SOC and a coulomb counter in uAh, so build the pair from
	 * those.  Kernel units: charge in uAh, energy in uWh.
	 */
	if (battmgr->variant == QCOM_BATTMGR_SM8350 && sm8350_bat_is_derived(psp)) {
		unsigned long long charge_uah = battmgr->info.charge_count;
		unsigned long long voltage_uv = battmgr->status.voltage_now;
		unsigned int percent = battmgr->status.percent;
		unsigned long long full_uah;

		if (!charge_uah || !voltage_uv || !percent || percent == (unsigned int)-1)
			return -ENODATA;

		full_uah = div_u64(charge_uah * 100, percent);

		switch (psp) {
		case POWER_SUPPLY_PROP_CHARGE_NOW:
			val->intval = charge_uah;
			break;
		case POWER_SUPPLY_PROP_CHARGE_FULL:
			val->intval = full_uah;
			break;
		case POWER_SUPPLY_PROP_ENERGY_NOW:
			val->intval = div_u64(charge_uah * voltage_uv, 1000000);
			break;
		default:
			val->intval = div_u64(full_uah * voltage_uv, 1000000);
			break;
		}

		return 0;
	}

	switch (psp) {""" % MARK
),
(
"""	POWER_SUPPLY_PROP_INTERNAL_RESISTANCE,
	POWER_SUPPLY_PROP_STATE_OF_HEALTH,
	POWER_SUPPLY_PROP_POWER_NOW,
};

static const struct power_supply_desc sm8350_bat_psy_desc = {""",
"""	POWER_SUPPLY_PROP_INTERNAL_RESISTANCE,
	POWER_SUPPLY_PROP_STATE_OF_HEALTH,
	POWER_SUPPLY_PROP_POWER_NOW,
	/* %s */
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_ENERGY_NOW,
	POWER_SUPPLY_PROP_ENERGY_FULL,
};

static const struct power_supply_desc sm8350_bat_psy_desc = {""" % MARK
),
(
"""	else
		battmgr->variant = QCOM_BATTMGR_SM8350;""",
"""	else
		battmgr->variant = QCOM_BATTMGR_SM8350;

	dev_info(dev, "Y700-A145 battmgr derives the charge and energy pair from the coulomb counter\\n");"""
),
]

def main():
    path = sys.argv[1]
    src = open(path, encoding="utf-8").read()
    if MARK in src:
        if src.count(MARK) >= 5:
            print("A145_ALREADY_APPLIED")
            return 0
        print("A145_PARTIAL_PATCH_BAIL")
        return 1
    for i, (old, new) in enumerate(EDITS):
        n = src.count(old)
        if n != 1:
            print("A145_ANCHOR_NOT_UNIQUE edit=%d count=%d" % (i, n))
            return 1
        src = src.replace(old, new, 1)
    open(path, "w", encoding="utf-8").write(src)
    print("A145_PATCH_OK marks=%d bytes=%d" % (src.count(MARK), len(src)))
    return 0

if __name__ == "__main__":
    sys.exit(main())