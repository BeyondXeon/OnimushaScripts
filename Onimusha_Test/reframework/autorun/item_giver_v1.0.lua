-- Item Giver v1.0 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- Consolidated stable (was v1.9).
--
-- Grants through the live helper (SaveDataManager -> get_Helper -> get__Item):
--   "To Box"  storage (pick it up at any box menu in-game).
--   "Give"    direct handover; bag-type items go through the medicine-bag
--             path automatically.
-- Counts re-read from the live game every few seconds, quantity is one
-- exclusive pick (x1 x2 x3 x5 x10), and the status line wraps instead of
-- running off the menu border.
--
-- Menu: REFramework -> ScriptRunner -> "ItemGiver v1.9".

local MOD, VERSION = "ItemGiver", "1.0"
local TAG = "[" .. MOD .. "] "

local function L(msg) log.info(TAG .. tostring(msg)) end

local function try_call(obj, name, ...)
    if obj == nil then return nil end
    local ok, r = pcall(obj.call, obj, name, ...)
    if ok then return r end
    return nil
end

local function try_field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(obj.get_field, obj, name)
    if ok then return r end
    return nil
end

local function is_obj(v)
    if v == nil then return false end
    local ok, td = pcall(function() return v:get_type_definition() end)
    if not ok or td == nil then return false end
    return pcall(function() return v:get_address() end)
end

local function singleton(name)
    local s = nil
    pcall(function() s = sdk.get_managed_singleton(name) end)
    if s == nil then
        pcall(function()
            local short = name:match("^app%.(.+)$")
            if short then s = sdk.get_managed_singleton(sdk.game_namespace(short)) end
        end)
    end
    return s
end

local helper = nil
local function resolve_helper()
    if helper ~= nil then
        local ok = pcall(function() return helper:get_address() end)
        if ok then return helper end
        helper = nil
    end
    local mgr = singleton("app.SaveDataManager")
    if mgr ~= nil then
        local shp = try_call(mgr, "get_Helper") or try_field(mgr, "_Helper")
        if shp ~= nil and is_obj(shp) then
            local h = try_call(shp, "get__Item") or try_field(shp, "_Item")
            if h ~= nil and is_obj(h) then
                helper = h
                return helper
            end
        end
    end
    return nil
end

-- Refined categories (specific before general in the matcher below).
local CATS = { "Consumables", "Materials", "Keys", "Genma Notes",
    "Old Drawings", "Outfits", "Gear", "Weapons", "Appearances", "Charms",
    "Bags & Pouches", "Skills", "Other" }
local function category_of(name, id)
    local n = name:lower()
    local function has(...)
        for _, k in ipairs({ ... }) do
            if n:find(k, 1, true) then return true end
        end
        return false
    end
    if has("genma note") then return "Genma Notes" end
    if has("old drawing") then return "Old Drawings" end
    if has("sword appearance") then return "Appearances" end
    if has("outfit", "haori", "kimono", "costume", "armor", "attire", "garb") then return "Outfits" end
    if has("gauntlet") then return "Gear" end
    if has("sword", "bow", "wind-whipper", "shakers", "flashing void",
        "two celestials", "flute") then
        return "Weapons"
    end
    if has("amulet", "charm", "talisman", "beads", "horn token") then return "Charms" end
    if has("pouch") then return "Bags & Pouches" end
    if has("new skill") then return "Skills" end
    if has("key") then return "Keys" end
    if has("oni cloth", "stimulant", "restorative", "whetstone", "rice ball",
        "miracle cure", "squeezer", "sucker", "mirror of revival",
        "soul crystal", "still water", "hozuki") then
        return "Consumables"
    end
    if has("cloth", "leather", "iron", "silk", "hemp", "malicite", "horn",
        "shard", "treasure") then
        return "Materials"
    end
    return "Other"
end

-- The full catalog, swept 1-1000000: every ID whose name resolves.
-- {id, name}. Categories + live counts attach at load.
local CATALOG = {
    { 46, "Unknown" },
    { 336, "Genma Note: Byakue" },
    { 413, "Outfit: Light Kimono 2" },
    { 415, "Cloudbiter Haori" },
    { 1199, "Genma Note: Kogashira" },
    { 1330, "New Charm" },
    { 1593, "Amulet of Introspection" },
    { 2212, "Genma Note: Dokyo" },
    { 2901, "Oni Cloth (Healing)" },
    { 3191, "Rear Gate Key" },
    { 3314, "Oni Gauntlet" },
    { 3821, "Old Drawing No. 3" },
    { 3833, "Genma Note: Sasaki Ganryu" },
    { 5862, "#Rejected# ItemDataText_IT_5862" },
    { 5932, "Outfit: Tasuki Sash" },
    { 6729, "Cotton Cloth" },
    { 6891, "Greater Soul Crystal" },
    { 7374, "The Flashing Void" },
    { 7434, "Lesser Defense Talisman" },
    { 7568, "Leather" },
    { 7749, "Hellfire Haori" },
    { 8085, "Genma Note: Mohja" },
    { 8133, "Striped Haori" },
    { 8259, "Outfit: Bird Call" },
    { 8413, "Earth-Shakers" },
    { 8874, "Sword Appearance: Shishioh" },
    { 8949, "Stage Costume" },
    { 8950, "New Hozuki Pouch" },
    { 8973, "Malicite Mass" },
    { 9109, "Genma Note: Oboro Garasu" },
    { 9253, "Genma Note: Shuten Doji" },
    { 9254, "Oni Attire" },
    { 9487, "Old Drawing No. 1" },
    { 9549, "Oni Haori" },
    { 10152, "Outfit: Elegance" },
    { 10773, "Sword Appearance: Whittled Oar" },
    { 10971, "Genma Note: Daidara" },
    { 11032, "Stimulant" },
    { 11076, "Genma Note: Ifuu" },
    { 11088, "Oni Cloth (Aggressor)" },
    { 11192, "Byakue's Talisman" },
    { 12039, "Blessed Beads" },
    { 12129, "Sword Appearance: Enryuu" },
    { 12597, "Horn Token (Blazing)" },
    { 12633, "Still Water" },
    { 13047, "Genma Note: Hitotsume Sho" },
    { 13169, "Morning Mist Haori" },
    { 13810, "Morning Mist Haori 2" },
    { 14134, "Outfit: Panda Costume" },
    { 14276, "Tempered Iron" },
    { 14370, "Gauntlet-Hiding Haori" },
    { 14381, "Outfit: Master's Garb" },
    { 14445, "Genma Note: Burai" },
    { 14467, "Genma Note: Dohatsu-ten" },
    { 14487, "Fine Silk Cloth" },
    { 14847, "Outfit: Red Armor" },
    { 15298, "Outfit: Snow Camellia" },
    { 15301, "Genma Note: Hirehime" },
    { 15452, "Lesser Soul Crystal" },
    { 15508, "Whetstone" },
    { 15658, "Soul Squeezer" },
    { 15668, "Dohatsu-ten's Horn" },
    { 16329, "Heavy Restorative" },
    { 16424, "Iron" },
    { 16477, "Fireman's Haori 2" },
    { 16480, "Oni Cloth (Regeneration)" },
    { 16820, "Bishamon Sword" },
    { 16890, "Lesser Might Talisman" },
    { 16965, "Sword Appearance: Kikoku" },
    { 17135, "Sword Appearance: Ura-giri" },
    { 17210, "Greater Defense Talisman" },
    { 17802, "No Name" },
    { 18151, "Old Temple Key" },
    { 18152, "Outfit: Master's Garb 2" },
    { 18329, "Oni Haori 2" },
    { 19198, "Mirror of Revival" },
    { 19338, "Wind-Whipper" },
    { 19411, "Prayer Beads" },
    { 19861, "The Two Celestials" },
    { 20080, "Horn Token (Reflex)" },
    { 20119, "Outfit: Oni Dance" },
    { 20845, "Genma Note: Kogai" },
    { 21211, "Genma Note: Greater Nue" },
    { 21678, "Sword Appearance: White Lion" },
    { 21723, "Genma Note: Yoshitsune" },
    { 22003, "Sword Appearance: Mooncrossed" },
    { 22384, "Genma Note: Hitotsume Gasa" },
    { 22388, "New Skill" },
    { 22649, "Genma Note: Chijiko" },
    { 22774, "Old Drawing No. 2" },
    { 22816, "Firebird Flute" },
    { 23169, "Light Kimono" },
    { 23317, "Moonlight Haori" },
    { 23589, "Genma Note: Kubi Akari" },
    { 24143, "Outfit: Warlord's Armor" },
    { 24318, "Master's Haori 2" },
    { 24444, "Genma Note: Nue" },
    { 24482, "Oni Cloth (Resistance)" },
    { 25002, "Dungeon Key" },
    { 25049, "White Rice Ball" },
    { 25428, "Outfit: Goldfish Dance" },
    { 25805, "Genma Note: Rasho-gan" },
    { 26418, "Sword Appearance: Raizan" },
    { 26615, "Hozuki" },
    { 26655, "Master's Haori" },
    { 26749, "Outfit: Flower Dance" },
    { 27243, "Old Drawing No. 5" },
    { 27248, "Oni Treasure" },
    { 27324, "Sun-Dried Hozuki" },
    { 27768, "Sword Appearance: Myogo" },
    { 27860, "Genma Note: Togemaru" },
    { 28035, "Johari Shard" },
    { 28160, "Velvet Haori" },
    { 28336, "Major Miracle Cure" },
    { 28559, "Oni Cloth (Awakening)" },
    { 28576, "Sword Appearance: Bamboo & Panda" },
    { 28716, "Gauntlet-Hiding Haori 2" },
    { 28806, "Soul Sucker" },
    { 28924, "Outfit: Warlord's Armor 2" },
    { 29243, "Oni Gauntlet: Crimson Lotus" },
    { 29547, "Minor Miracle Cure" },
    { 29992, "Sword Appearance: Sealed Curse" },
    { 30419, "Striped Haori 2" },
    { 30505, "Fireman's Haori" },
    { 31281, "Velvet Haori 2" },
    { 31352, "Genma Note: Benkei" },
    { 31493, "Old Drawing No. 4" },
    { 31697, "Mixed Grain Rice Ball" },
    { 32279, "Greater Might Talisman" },
    { 32509, "Outfit: Wataru-kun Costume" },
    { 32699, "Sword Appearance: Sakurahime" },
    { 32727, "Hempen Cloth" },
}

local items, status = {}, "reading live counts..."
local qty, sel_pos, filter, cur_cat = 1, 1, "", "All"
local QTY_CHOICES = { 1, 2, 3, 5, 10 }
-- Live-count refresh state (declared early: load_catalog writes it).
local refresh_cursor, refresh_tick = nil, 0
local function load_catalog()
    items, sel_pos = {}, 1
    for _, e in ipairs(CATALOG) do
        items[#items + 1] = { id = e[1], name = e[2], cat = category_of(e[2], e[1]),
            count = -1, box = -1 }
    end
    table.sort(items, function(a, b)
        if a.cat ~= b.cat then return a.cat < b.cat end
        return a.id < b.id
    end)
    status = tostring(#items) .. " items built in - reading live counts..."
    refresh_cursor = 1
end

local function counts_of(h, id)
    local c = try_call(h, "getItemCountOfId", id)
    local b = try_call(h, "getItemBoxCountOfId", id)
    return (type(c) == "number") and c or -1, (type(b) == "number") and b or -1
end

-- Direct path: addItem overloads (exact live TDB prototypes, no guessing),
-- then addDirectMedicineBag for bag-type items. Stops at the first path
-- that moves the HELD count; every attempt is reported with before/after.
local function grant_direct(r)
    local h = resolve_helper()
    if h == nil then
        status = "Can't reach your items right now - load your save first."
        return
    end
    local c0, b0 = counts_of(h, r.id)
    local function refresh()
        local c1, b1 = counts_of(h, r.id)
        r.count, r.box = c1, b1
        return c1, b1
    end
    local ok_td, td = pcall(h.get_type_definition, h)
    if ok_td and td ~= nil then
        local okm, methods = pcall(td.get_methods, td)
        if okm and methods ~= nil then
            for _, m in pairs(methods) do
                local mname = nil
                pcall(function() mname = m:get_name() end)
                if mname == "addItem" then
                    local okp, pts = pcall(m.get_param_types, m)
                    if okp and pts ~= nil and #pts == 5 then
                        local parts = {}
                        local okfull = true
                        for _, pt in ipairs(pts) do
                            local okn, pn = pcall(pt.get_full_name, pt)
                            if not okn or type(pn) ~= "string" then okfull = false break end
                            parts[#parts + 1] = pn
                        end
                        if okfull then
                            local proto = "addItem(" .. table.concat(parts, ", ") .. ")"
                            local okc, ret = pcall(h.call, h, proto, r.id, qty, false, false, nil)
                            local c1, b1 = refresh()
                            if okc and c1 > c0 then
                                status = string.format("Gave %d x %s - you now hold %d.",
                                    qty, r.name, c1)
                                L("direct HELD: " .. proto .. " -> " .. tostring(c1))
                                return
                            elseif okc then
                                L("direct ok but held steady (" .. proto .. "); trying bag path")
                            else
                                L("direct err " .. proto .. ": " .. tostring(ret))
                            end
                        end
                    end
                end
            end
        end
    end
    -- Bag-type items (Oni Cloths etc.): direct bag grant, both flag values.
    for _, flag in ipairs({ false, true }) do
        local okc, ret = pcall(h.call, h, "addDirectMedicineBag", r.id, flag)
        local c1, b1 = refresh()
        if okc and c1 > c0 then
            status = string.format("Gave %d x %s - you now hold %d.",
                qty, r.name, c1)
            L("direct BAG(" .. tostring(flag) .. ") -> " .. tostring(c1))
            return
        end
    end
    local c1, b1 = refresh()
    if b1 > b0 then
        status = string.format("That one only goes to the storehouse - %d x %s waiting there (storehouse now %d). Pick it up at any box menu.",
            qty, r.name, b1)
    else
        status = string.format("Couldn't hand over %s - nothing changed. It may need unlocking first.",
            r.name)
    end
    L(status .. " [held=" .. tostring(c1) .. " box=" .. tostring(b1) .. "]")
end

local function grant_box(r)
    local h = resolve_helper()
    if h == nil then
        status = "Can't reach your items right now - load your save first."
        return
    end
    local _, b0 = counts_of(h, r.id)
    local okc, ret = pcall(h.call, h, "addItemToBox", r.id, qty)
    local c1, b1 = counts_of(h, r.id)
    r.count, r.box = c1, b1
    if okc and b1 > b0 then
        status = string.format("Put %d x %s in the storehouse (now %d). Pick it up at any box menu.",
            qty, r.name, b1)
    elseif okc then
        status = string.format("The storehouse didn't take %s - count unchanged at %d.", r.name, b1)
    else
        status = string.format("Couldn't store %s.", r.name)
    end
    L(status .. " [ret=" .. tostring(ret) .. "]")
end

local function combo_items(cat)
    local t = {}
    for _, r in ipairs(items) do
        if (cat == "All" or r.cat == cat)
            and (filter == "" or (tostring(r.id) .. " " .. r.name .. " " .. r.cat):lower():find(filter:lower(), 1, true)) then
            t[#t + 1] = { r = r, label = string.format("%s [%d] - Held %s, Storehouse %s",
                r.name, r.id, tostring(r.count), tostring(r.box)) }
        end
    end
    return t
end

-- Wrapped text that stays inside the menu border. This REFramework build
-- has no text_wrapped API, so lines are broken here at word boundaries.
-- Width 52 matches the Filter/Category/Item row length (calibrated from a
-- user screenshot at 46 -> running ~15% short of that edge).
local WRAP_WIDTH = 52
local function wtext(s)
    s = tostring(s)
    local line = ""
    local function flush()
        if #line > 0 then imgui.text(line) line = "" end
    end
    for word in s:gmatch("%S+") do
        if #line == 0 then
            line = word
        elseif #line + 1 + #word <= WRAP_WIDTH then
            line = line .. " " .. word
        else
            flush()
            -- One over-long token (a long name/code): hard-split it.
            while #word > WRAP_WIDTH do
                imgui.text(word:sub(1, WRAP_WIDTH))
                word = word:sub(WRAP_WIDTH + 1)
            end
            line = word
        end
    end
    flush()
end

-- Live counts: refreshes every row in small slices so the game never hitches.
-- Runs on demand (button), after Reload, and automatically every ~5 seconds.
local function refresh_step()
    local h = resolve_helper()
    if h == nil or #items == 0 then
        refresh_cursor = nil
        return
    end
    if refresh_cursor == nil then return end
    local stop = math.min(refresh_cursor + 29, #items)
    for i = refresh_cursor, stop do
        local r = items[i]
        local c, b = counts_of(h, r.id)
        r.count, r.box = c, b
    end
    refresh_cursor = (stop >= #items) and nil or (stop + 1)
end

re.on_frame(function()
    refresh_tick = refresh_tick + 1
    if refresh_tick % 300 == 0 and refresh_cursor == nil and #items > 0 then
        refresh_cursor = 1 -- background re-read every ~5s
    end
    if refresh_cursor ~= nil then refresh_step() end
end)

local ui_threw, use_combo = false, true
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        wtext("Status: " .. status)
        imgui.text("How many:")
        for _, q in ipairs(QTY_CHOICES) do
            imgui.same_line()
            local chq, vq = imgui.checkbox("x" .. tostring(q), qty == q)
            if chq and vq then qty = q end
        end
        local chf, vf = imgui.input_text("Filter", filter)
        if chf then filter = vf sel_pos = 1 end
        -- Category picker, then items inside it.
        local catchanged, catpos = false, 1
        do
            local clabels = { "All" }
            for _, c in ipairs(CATS) do clabels[#clabels + 1] = c end
            for i, c in ipairs(clabels) do
                if c == cur_cat then catpos = i break end
            end
            local okc, chc, vci = pcall(imgui.combo, "Category", catpos, clabels)
            if okc and type(vci) == "number" and chc then
                cur_cat = clabels[vci] or "All"
                sel_pos = 1
            end
        end
        local list = combo_items(cur_cat)
        if #items == 0 then
            wtext("No items. Tell me - the built-in list should never be empty.")
        elseif use_combo then
            if #list == 0 then
                wtext("No match. Clear the filter or pick another category.")
            else
                if sel_pos > #list then sel_pos = #list end
                local labels = {}
                for i, e in ipairs(list) do labels[i] = e.label end
                local okc, chc, vci = pcall(imgui.combo, "Item", sel_pos, labels)
                if okc and type(vci) == "number" then
                    if chc then sel_pos = vci end
                    local r = list[sel_pos] and list[sel_pos].r or nil
                    if r ~= nil then
                        if imgui.button("Give to Box") then grant_box(r) end
                        imgui.same_line()
                        if imgui.button("Give Direct") then grant_direct(r) end
                    end
                else
                    use_combo = false -- no combo API in this build: fall back
                end
            end
        end
        if not use_combo and #items > 0 then
            local shown = 0
            for _, e in ipairs(list) do
                shown = shown + 1
                if shown > 60 then
                    imgui.text("... refine the filter")
                    break
                end
                if imgui.button("Give##" .. tostring(e.r.id)) then grant_box(e.r) end
                imgui.same_line()
                imgui.text(e.label)
            end
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    helper = nil
    sel_pos = 1
    cur_cat = "All"
    load_catalog()
end)

load_catalog()
L("loaded v" .. VERSION)
