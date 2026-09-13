-- FindHealthOffset v1.0 -- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- Read-only HP-path finder. Replaces the old raw-offset scanner, which could
-- not work in this REFramework build:
--   re.get_player / re.read_float / re.write_float do not exist here
--   (zero working scripts in reframework/autorun use them),
--   imgui.* may only run inside re.on_draw_ui,
--   and RE Engine exposes the player as managed objects, not a raw address.
--
-- How to use:
--   1. Copy this file to the game folder's reframework/autorun/ (do that manually).
--   2. Launch game, press Insert -> ScriptRunner -> Reset Scripts.
--   3. Open "FindHealthOffset v1.0" node. At full HP press "Snapshot A".
--   4. Take damage in game, press "Snapshot B (after damage)".
--   5. The Diff list shows which numeric fields changed -> that is the HP path
--      to use in the invincibility mod. Paste the result back here.
-- Menu: REFramework -> ScriptRunner -> "FindHealthOffset v1.0". No config file.

local MOD, VERSION = "FindHealthOffset", "1.0"
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

local KEYWORDS = { "hp", "health", "life", "vital", "hitpoint", "hit_point" }

local function matches_keyword(name)
    if type(name) ~= "string" then return false end
    local n = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if n:find(k, 1, true) then return true end
    end
    return false
end

-- Same player lookup the working mods use (AttackSpeed / run_speed / faster_interactions).
local function resolve_player()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    if pm == nil then return nil, "no app.PlayerManager singleton" end
    local mi = try_call(pm, "getControllingPlayer")
    if mi == nil then
        local info = try_call(pm, "getControllingPlayerInfo")
        if info ~= nil then mi = info end
    end
    if mi == nil then return nil, "no controlling player yet (load a save / enter gameplay)" end
    local chara = try_call(mi, "get_Character")
    local entity = try_call(mi, "get_CharacterEntity")
    local go = try_call(mi, "get_Object")
    if chara == nil and entity == nil then return nil, "player objects not ready yet" end
    return { mi = mi, chara = chara, entity = entity, go = go }, nil
end

local function type_name_of(obj)
    if obj == nil then return "nil" end
    local ok, td = pcall(obj.get_type_definition, obj)
    if ok and td ~= nil then
        local okn, n = pcall(td.get_full_name, td)
        if okn and n then return tostring(n) end
    end
    return "?"
end

-- Collect numeric fields + zero-arg numeric getters whose names look HP-related.
local function scan_hp_candidates(obj, label, out)
    if obj == nil then return end
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if not ok_td or td == nil then return end
    local okf, fields = pcall(td.get_fields, td)
    if okf and fields ~= nil then
        for _, f in ipairs(fields) do
            local fname = nil
            pcall(function() fname = f:get_name() end)
            if fname ~= nil and matches_keyword(fname) then
                local v = try_field(obj, fname)
                if type(v) == "number" then
                    out[#out + 1] = { path = label .. "." .. fname, kind = "field", value = v }
                end
            end
        end
    end
    local okm, methods = pcall(td.get_methods, td)
    if okm and methods ~= nil then
        for _, m in ipairs(methods) do
            local mname = nil
            pcall(function() mname = m:get_name() end)
            if mname ~= nil and matches_keyword(mname) then
                local okp, pts = pcall(m.get_param_types, m)
                if okp and (pts == nil or #pts == 0) then
                    local v = try_call(obj, mname)
                    if type(v) == "number" then
                        out[#out + 1] = { path = label .. ":" .. mname .. "()", kind = "getter", value = v }
                    end
                end
            end
        end
    end
end

local function full_scan()
    local p, err = resolve_player()
    if p == nil then return nil, err end
    local out = {}
    scan_hp_candidates(p.chara, "Character(" .. type_name_of(p.chara) .. ")", out)
    scan_hp_candidates(p.entity, "Entity(" .. type_name_of(p.entity) .. ")", out)
    scan_hp_candidates(p.mi, "PlayerInfo(" .. type_name_of(p.mi) .. ")", out)
    return { player = p, rows = out }, nil
end

local snap_a, snap_b, diff = nil, nil, {}
local status = "idle: press Snapshot A at full HP"
local chara_type, entity_type = "?", "?"

local function snapshot(slot)
    local res, err = full_scan()
    if res == nil then
        status = "scan failed: " .. tostring(err)
        L(status)
        return
    end
    chara_type = type_name_of(res.player.chara)
    entity_type = type_name_of(res.player.entity)
    local map = {}
    for _, r in ipairs(res.rows) do map[r.path] = r.value end
    if slot == "A" then
        snap_a, snap_b, diff = map, nil, {}
        status = "Snapshot A stored (" .. tostring(#res.rows) .. " HP-like values). Now take damage, then Snapshot B."
    else
        if snap_a == nil then
            status = "take Snapshot A first"
            return
        end
        snap_b = map
        diff = {}
        for path, va in pairs(snap_a) do
            local vb = snap_b[path]
            if type(vb) == "number" and vb ~= va then
                diff[#diff + 1] = { path = path, before = va, after = vb, delta = vb - va }
            end
        end
        table.sort(diff, function(a, b) return math.abs(a.delta) > math.abs(b.delta) end)
        status = "compared: " .. tostring(#diff) .. " changed value(s). Biggest change is the HP path."
    end
    L(status)
end

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        imgui.text("Read-only finder. Takes no damage, writes nothing.")
        imgui.text("Character: " .. chara_type)
        imgui.text("Entity: " .. entity_type)
        imgui.text("Status: " .. status)
        if imgui.button("Snapshot A (full HP)") then snapshot("A") end
        imgui.same_line()
        if imgui.button("Snapshot B (after damage)") then snapshot("B") end
        if #diff > 0 then
            imgui.separator()
            imgui.text("Changed HP-like values (use Path in invincibility mod):")
            for i = 1, math.min(#diff, 20) do
                local d = diff[i]
                imgui.text(string.format("%d. %s : %s -> %s (d=%s)", i, d.path,
                    tostring(d.before), tostring(d.after), tostring(d.delta)))
            end
        elseif snap_a ~= nil then
            imgui.text("A stored. Damage the character, then press Snapshot B.")
        else
            imgui.text("1. Snapshot A at full HP / 2. take a hit / 3. Snapshot B.")
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

L("loaded v" .. VERSION .. " (read-only, sdk-based)")
