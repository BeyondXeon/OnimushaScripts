if not __sl_entries or not __sl_entries["Kairos_Onimusha_BowCharge"] then
    error("Entry function for `Kairos_Onimusha_BowCharge` not found.\nMake sure you installed Kairos_Onimusha_BowCharge.dll correctly.")
end
local main_getter = __sl_entries["Kairos_Onimusha_BowCharge"]
main_getter()()