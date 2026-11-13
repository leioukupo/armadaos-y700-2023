#!/usr/bin/env python3
# Y700-A146: the SM8450 ADSP answers BATT_POWER_NOW about six times too high, so
# work the wattage out from the current that same firmware reports times the
# battery voltage.  Applies on top of the A145 patch.
import sys

MARK = "Y700-A146"
EDITS = [
(
"""static const u8 sm8350_bat_derived_props[] = {
	BATT_CAPACITY,
	BATT_VOLT_NOW,
	BATT_CHG_COUNTER,
};""",
"""static const u8 sm8350_bat_derived_props[] = {
	BATT_CAPACITY,
	BATT_VOLT_NOW,
	BATT_CHG_COUNTER,
	/* Y700-A146: the derived power_now needs the current too */
	BATT_CURR_NOW,
};"""
),
(
"""	return psp == POWER_SUPPLY_PROP_CHARGE_NOW ||
	       psp == POWER_SUPPLY_PROP_CHARGE_FULL ||
	       psp == POWER_SUPPLY_PROP_ENERGY_NOW ||
	       psp == POWER_SUPPLY_PROP_ENERGY_FULL;""",
"""	return psp == POWER_SUPPLY_PROP_CHARGE_NOW ||
	       psp == POWER_SUPPLY_PROP_CHARGE_FULL ||
	       psp == POWER_SUPPLY_PROP_ENERGY_NOW ||
	       psp == POWER_SUPPLY_PROP_ENERGY_FULL ||
	       psp == POWER_SUPPLY_PROP_POWER_NOW;"""
),
(
"""		unsigned long long full_uah;

		if (!charge_uah || !voltage_uv || !percent || percent == (unsigned int)-1)
			return -ENODATA;""",
"""		unsigned long long full_uah;

		/*
		 * %s: the firmware power_now is off by roughly a factor of six -
		 * it answers 34.3 W while the very same firmware reports a 1.30 A
		 * discharge at 4.22 V.  Plasma takes power_now as EnergyRate, so
		 * the desktop promised 25 minutes on a nearly full cell.  Compute
		 * the wattage from the current and the battery voltage instead;
		 * the derived update above already fetches both.
		 */
		if (psp == POWER_SUPPLY_PROP_POWER_NOW) {
			long long current_ua = battmgr->status.current_now;

			if (current_ua == 0 || current_ua == -1 || !voltage_uv)
				return -ENODATA;

			if (current_ua < 0)
				current_ua = -current_ua;

			val->intval = div_u64((unsigned long long)current_ua * voltage_uv,
					     1000000);
			return 0;
		}

		if (!charge_uah || !voltage_uv || !percent || percent == (unsigned int)-1)
			return -ENODATA;""" % MARK
),
(
"""	dev_info(dev, "Y700-A145 battmgr derives the charge and energy pair from the coulomb counter\\n");""",
"""	dev_info(dev, "Y700-A145 battmgr derives the charge and energy pair from the coulomb counter\\n");
	dev_info(dev, "Y700-A146 battmgr derives power_now from the current and the battery voltage\\n");"""
),
]

def main():
    path = sys.argv[1]
    src = open(path, encoding="utf-8").read()
    if MARK in src:
        if src.count(MARK) >= 3:
            print("A146_ALREADY_APPLIED")
            return 0
        print("A146_PARTIAL_PATCH_BAIL")
        return 1
    if "sm8350_bat_is_derived" not in src:
        print("A146_NEEDS_A145_FIRST")
        return 1
    for i, (old, new) in enumerate(EDITS):
        n = src.count(old)
        if n != 1:
            print("A146_ANCHOR_NOT_UNIQUE edit=%d count=%d" % (i, n))
            return 1
        src = src.replace(old, new, 1)
    open(path, "w", encoding="utf-8").write(src)
    print("A146_PATCH_OK marks=%d bytes=%d" % (src.count(MARK), len(src)))
    return 0

if __name__ == "__main__":
    sys.exit(main())