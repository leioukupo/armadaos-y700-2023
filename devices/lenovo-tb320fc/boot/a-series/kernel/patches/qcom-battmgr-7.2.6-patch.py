#!/usr/bin/env python3
# TB320FC: teach qcom_battmgr to answer the charge/energy pair and POWER_NOW for
# the SM8450-family (sm8350 variant) firmware, which answers the per-property
# protocol and never fills power_unit.
#
# This is the Freedom-kernel (7.2.6) port of the on-device A145/A146 fix that
# was developed against asphalt-linux 7.3.0-rc6; the anchors differ because the
# 7.2.6 prop map carries the CONSTANT_CHARGE_CURRENT_* entries and already maps
# CHARGE_NOW to the coulomb counter.  PROGRESS.md "A145 修法" / "功率也要派生
# (A146)" records the measurements; the derived value is what upower and KDE's
# Solid backend read, and without it the desktop believes the cell is empty
# right after a DPMS wake.
import sys

MARK = "TB320FC-BATGMGR-v1"
PATH = "drivers/power/supply/qcom_battmgr.c"

EDITS = [
(
"""#include <linux/math.h>
#include <linux/units.h>""",
"""#include <linux/math.h>
#include <linux/math64.h>
#include <linux/units.h>"""
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
	/* %s: derived from the coulomb counter, not answered by the firmware */
	POWER_SUPPLY_PROP_ENERGY_NOW,
	POWER_SUPPLY_PROP_ENERGY_FULL,
};

static const struct power_supply_desc sm8350_bat_psy_desc = {""" % MARK
),
(
"""	[POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT] = BATT_CHG_CTRL_LIM,
	[POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX] = BATT_CHG_CTRL_LIM_MAX,
};""",
"""	[POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT] = BATT_CHG_CTRL_LIM,
	[POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX] = BATT_CHG_CTRL_LIM_MAX,
	/* %s: derived properties still need a valid map slot */
	[POWER_SUPPLY_PROP_ENERGY_NOW] = BATT_CHG_COUNTER,
	[POWER_SUPPLY_PROP_ENERGY_FULL] = BATT_CHG_COUNTER,
};

/*
 * %s: the request that answers a derived property is a batch: the SOC, the
 * battery voltage, the coulomb counter and the current are the four firmware
 * properties the derived values are built from, and they have to come back
 * from the same query round to stay mutually consistent.
 */
static const u8 sm8350_bat_derived_props[] = {
	BATT_CAPACITY,
	BATT_VOLT_NOW,
	BATT_CHG_COUNTER,
	BATT_CURR_NOW,
};

static bool sm8350_bat_is_derived(enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_NOW ||
	       psp == POWER_SUPPLY_PROP_CHARGE_FULL ||
	       psp == POWER_SUPPLY_PROP_ENERGY_NOW ||
	       psp == POWER_SUPPLY_PROP_ENERGY_FULL ||
	       psp == POWER_SUPPLY_PROP_POWER_NOW;
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
	 * %s: this ADSP never fills power_unit, so battmgr->unit stays mWh and
	 * every 'if (unit != mAh) return -ENODATA' below eats the charge pair -
	 * and sm8350_bat_props has no ENERGY_* at all.  KDE's Solid backend
	 * computes the level from Energy/EnergyFull, so it reports an empty cell
	 * and powerdevil sleeps the session whenever it re-queries (typically
	 * right after the panel wakes from a DPMS blank).  The firmware does
	 * give a SOC percentage, a µAh coulomb counter and a µV voltage, so
	 * build the pair from those.  Kernel units: charge µAh, energy µWh.
	 */
	if (battmgr->variant == QCOM_BATTMGR_SM8350 && sm8350_bat_is_derived(psp)) {
		unsigned long long charge_uah = battmgr->info.charge_count;
		unsigned long long voltage_uv = battmgr->status.voltage_now;
		unsigned int percent = battmgr->status.percent;
		unsigned long long full_uah;

		if (psp == POWER_SUPPLY_PROP_POWER_NOW) {
			long long current_ua = battmgr->status.current_now;
			long long current_ma;

			if (!voltage_uv || !current_ua)
				return -ENODATA;
			/*
			 * The firmware's own POWER_NOW is off by an order of
			 * magnitude (it claimed 34.3 W while its own current and
			 * voltage give 5.5 W), so derive it as well.  upower reads
			 * POWER_NOW as energy-rate, and a wrong value there shows
			 * up as nonsense time-to-empty.
			 */
			if (current_ua < 0)
				current_ua = -current_ua;
			current_ma = div_u64(current_ua, 1000);
			val->intval = (unsigned int)(current_ma * voltage_uv / 1000);
			return 0;
		}

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
]

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else PATH
    with open(path, "r") as f:
        text = f.read()
    if MARK in text:
        print("ALREADY_PATCHED")
        return 0
    for idx, (old, new) in enumerate(EDITS):
        count = text.count(old)
        if count != 1:
            print("ANCHOR_FAIL edit=%d count=%d" % (idx, count))
            return 1
        text = text.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(text)
    print("PATCHED edits=%d mark=%s" % (len(EDITS), MARK))
    return 0

if __name__ == "__main__":
    sys.exit(main())