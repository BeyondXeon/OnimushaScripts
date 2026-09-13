-- AtkSpeed v1.0 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- Standalone attack-speed scaler, split out of the DamageSpeed combo script
-- (combo line retired at v2.4). Scales the player's motion layers while an
-- attack action runs (animation carries its own travel, so no root-rate
-- touch). Anything that is not an attack restores the layers.
-- Sliders are gone: preset buttons x1 / x1.5 / x2 / x3.
-- (Distinct from the older AttackSpeed mod, which uses PlaySpeed windows.)
--
-- Menu: REFramework -> ScriptRunner -> "AtkSpeed v1.0".
-- Config: reframework/data/attack_speed.json.

local MOD, VERSION, CFG_FILE = "AtkSpeed", "1.0", "attack_speed.json"
local TAG = "[" .. MOD .. "] "
local MAX_LAYERS = 64
local PRESETS = { 1.0, 1.5, 2.0, 3.0 }

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { atk = 1.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.atk) == "number" then cfg.atk = math.max(1.0, math.min(3.0, saved.atk)) end
    else
        -- Fresh install: carry over the combo script's setting once.
        local oko, old = pcall(json.load_file, "damage_attack_speed.json")
        if oko and type(old) == "table" and type(old.atk) == "number" then
            cfg.atk = math.max(1.0, math.min(3.0, old.atk))
        end
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end

local function fmt_mult(v)
    return "x" .. (v == math.floor(v) and tostring(math.floor(v)) or tostring(v))
end

local function try_call(obj, name, ...)
    if obj == nil then return nil end
    local ok, r = pcall(obj.call, obj, name, ...)
    if ok then return r end
    return nil
end

-- Player handles.
local chara, entity, player_go = nil, nil, nil
local resolve_cooldown = 0
local layer_orig, layer_out = {}, {}
local cat_cache_addr, cat_cache_val = 0, nil
local motion, motion_go_addr = nil, 0

local function resolve_player()
    if resolve_cooldown > 0 then resolve_cooldown = resolve_cooldown - 1 return entity ~= nil end
    resolve_cooldown = 60
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = pm and try_call(pm, "getControllingPlayer") or nil
    local go = mi and try_call(mi, "get_Object") or nil
    if go == nil then return false end
    if player_go == nil or go:get_address() ~= player_go:get_address() then
        player_go, entity, chara = go, nil, nil
        layer_orig, layer_out = {}, {}
        cat_cache_addr, cat_cache_val = 0, nil
    end
    chara = try_call(mi, "get_Character")
    entity = try_call(mi, "get_CharacterEntity")
    return entity ~= nil
end

local function player_motion()
    if player_go == nil then return nil end
    if motion ~= nil then
        local ok, a = pcall(function() return motion:get_address() end)
        if not ok or a == 0 then motion = nil end
    end
    if motion == nil then
        local rt = nil
        pcall(function() rt = sdk.typeof("via.motion.Motion") end)
        if rt == nil then return nil end
        motion = try_call(player_go, "getComponent(System.Type)", rt)
        if motion ~= nil then motion_go_addr = player_go:get_address() end
    end
    return motion
end

-- Last-written mult per layer, so steady state costs zero game calls.
local function scale_layers(mult)
    local mo = player_motion()
    if mo == nil then return end
    for _, pair in ipairs({ { "getLayerCount", "getLayer" }, { "getPrivateLayerCount", "getPrivateLayer" } }) do
        local count = try_call(mo, pair[1]) or 0
        if count > MAX_LAYERS then count = MAX_LAYERS end
        for i = 0, count - 1 do
            local layer = try_call(mo, pair[2], i)
            if layer ~= nil then
                local addr = layer:get_address()
                local orig = layer_orig[addr]
                if orig == nil then
                    orig = try_call(layer, "get_Speed")
                    if orig ~= nil then layer_orig[addr] = orig end
                end
                if orig ~= nil and orig > 0 and layer_out[addr] ~= mult then
                    if pcall(function() layer:call("set_Speed", orig * mult) end) then
                        layer_out[addr] = mult
                    end
                end
            end
        end
    end
end

local function restore_layers()
    for addr, orig in pairs(layer_orig) do
        local layer = nil
        local mo = player_motion()
        if mo ~= nil then
            for _, pair in ipairs({ { "getLayerCount", "getLayer" }, { "getPrivateLayerCount", "getPrivateLayer" } }) do
                local count = try_call(mo, pair[1]) or 0
                if count > MAX_LAYERS then count = MAX_LAYERS end
                for i = 0, count - 1 do
                    local l = try_call(mo, pair[2], i)
                    if l ~= nil and l:get_address() == addr then layer = l break end
                end
                if layer ~= nil then break end
            end
        end
        if layer ~= nil then pcall(function() layer:call("set_Speed", orig) end) end
        layer_orig[addr] = nil
        layer_out[addr] = nil
    end
end

-- Attack category from the player's current base action class, cached per
-- action object (recomputed only when it changes).
local function action_category()
    if chara == nil then return nil end
    local act = try_call(chara, "get_BaseCurrentAction")
    if act == nil then return nil end
    local ok_addr, act_addr = pcall(function() return act:get_address() end)
    if ok_addr and act_addr ~= 0 and act_addr == cat_cache_addr then
        return cat_cache_val
    end
    local cat = nil
    local ok, td = pcall(act.get_type_definition, act)
    if ok and td ~= nil then
        local okf, full = pcall(td.get_full_name, td)
        if okf and type(full) == "string" then
            local n = full:match("([^.]+)$") or full
            if n:find("Attack") then cat = "attack"
            else cat = "other" end
        end
    end
    if ok_addr and act_addr ~= 0 then
        cat_cache_addr, cat_cache_val = act_addr, cat
    end
    return cat
end

re.on_pre_application_entry("UpdateMotion", function()
    local want_atk = cfg.atk ~= nil and cfg.atk > 1.0
    if not want_atk then
        if next(layer_orig) ~= nil then restore_layers() end
        return
    end
    if not resolve_player() then return end
    if player_go ~= nil and player_go:get_address() ~= motion_go_addr then
        restore_layers()
        motion = nil
    end
    if action_category() == "attack" then
        scale_layers(cfg.atk)
    elseif next(layer_orig) ~= nil then
        restore_layers()
    end
end)

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        local active = cfg.atk > 1.0 and ("ACTIVE: " .. fmt_mult(cfg.atk)) or "OFF"
        imgui.text_colored(active, cfg.atk > 1.0 and 0xFF40FF40 or 0xFF808080)
        imgui.text("Attack speed:")
        for i, v in ipairs(PRESETS) do
            if i > 1 then imgui.same_line() end
            local label = (cfg.atk == v) and ("[" .. fmt_mult(v) .. "]") or fmt_mult(v)
            if imgui.button(label) then cfg.atk = v save() end
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    restore_layers()
    chara, entity, player_go, motion = nil, nil, nil, nil
    layer_orig, layer_out = {}, {}
    cat_cache_addr, cat_cache_val = 0, nil
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
