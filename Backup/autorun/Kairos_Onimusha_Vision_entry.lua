if not __sl_entries or not __sl_entries["Kairos_Onimusha_Vision"] then
    error("Entry function for `Kairos_Onimusha_Vision` not found.\nMake sure you installed Kairos_Onimusha_Vision.dll correctly.")
end
local main_getter = __sl_entries["Kairos_Onimusha_Vision"]
main_getter()()