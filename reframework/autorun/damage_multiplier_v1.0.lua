-- DamageMult v1.0 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- Standalone damage multiplier, split out of the DamageSpeed combo script
-- (combo line retired at v2.4). Scales OUTGOING player damage only: the
-- player's own damage module passes through, everything else gets xN via
-- calcDamage output scaling (+ enemy-subclass hook). Rates are counted,
-- never multiplied (multiplying them did nothing - proven v1.2).
-- Sliders are gone: preset buttons x1 / x1.5 / x2 / x3 / x5 / x10.
--
-- Menu: REFramework -> ScriptRunner -> "DamageMult v1.0".
-- Config: reframework/data/damage_multiplier.json. Proof: damage_proof.json.

local MOD, VERSION, CFG_FILE = "DamageMult", "1.0", "damage_multiplier.json"
local PROOF_FILE = "damage_proof.json"
local TAG = "[" .. MOD .. "] "
local PRESETS = { 1.0, 1.5, 2.0, 3.0, 5.0, 10.0 }

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { dmg = 1.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.dmg) == "number" then cfg.dmg = math.max(1.0, math.min(10.0, saved.dmg)) end
    else
        -- Fresh install: carry over the combo script's setting once.
        local oko, old = pcall(json.load_file, "damage_attack_speed.json")
        if oko and type(old) == "table" and type(old.dmg) == "number" then
            cfg.dmg = math.max(1.0, math.min(10.0, old.dmg))
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

local function try_field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(obj.get_field, obj, name)
    if ok then return r end
    return nil
end

local function is_managed_object(v)
    if v == nil then return false end
    local ok, td = pcall(function() return v:get_type_definition() end)
    if not ok or td == nil then return false end
    return pcall(function() return v:get_address() end)
end

-- Player handles + own damage-module address (excluded from the multiplier).
local chara, entity, player_go, player_mod_addr = nil, nil, nil, 0
local resolve_cooldown = 0
local proof = { mod_addr = 0, attached = {}, addrs = {}, mult_hits = 0, player_fires = 0,
    calc_fires = 0, calc_scaled = 0, entity_type = "-", mod_step = "-",
    enemy_hook = "-", player_calc_fires = 0 }

local function type_name_of(obj)
    if obj == nil then return "nil" end
    local ok, td = pcall(obj.get_type_definition, obj)
    if ok and td ~= nil then
        local okn, n = pcall(td.get_full_name, td)
        if okn and n then return tostring(n) end
    end
    return "?"
end

-- Module resolution: direct field first, then scan every field for the
-- module type. Records which step worked (or that all failed).
local function resolve_module()
    player_mod_addr = 0
    proof.mod_step = "no entity"
    if entity == nil then return end
    proof.entity_type = type_name_of(entity)
    local mod = try_field(entity, "_DamageInterface")
    if is_managed_object(mod) then
        pcall(function() player_mod_addr = mod:get_address() end)
        if player_mod_addr ~= 0 then proof.mod_step = "field" end
    end
    if player_mod_addr == 0 then
        local ok_td, td = pcall(entity.get_type_definition, entity)
        if ok_td and td ~= nil then
            local okf, fields = pcall(td.get_fields, td)
            if okf and fields ~= nil then
                for _, f in pairs(fields) do
                    local ftname = "?"
                    pcall(function()
                        local ft = f:get_type()
                        if ft ~= nil then ftname = ft:get_full_name() end
                    end)
                    if ftname == "app.cPlayerApplyDamage" then
                        local fname = nil
                        pcall(function() fname = f:get_name() end)
                        if type(fname) == "string" then
                            local m2 = try_field(entity, fname)
                            if is_managed_object(m2) then
                                pcall(function() player_mod_addr = m2:get_address() end)
                                if player_mod_addr ~= 0 then
                                    proof.mod_step = "scan:" .. fname
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if player_mod_addr == 0 then proof.mod_step = "FAILED" end
    proof.mod_addr = player_mod_addr
end

local function resolve_player()
    if resolve_cooldown > 0 then resolve_cooldown = resolve_cooldown - 1 return entity ~= nil end
    resolve_cooldown = 60
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = pm and try_call(pm, "getControllingPlayer") or nil
    local go = mi and try_call(mi, "get_Object") or nil
    if go == nil then return false end
    if player_go == nil or go:get_address() ~= player_go:get_address() then
        player_go, entity, chara, player_mod_addr = go, nil, nil, 0
    end
    chara = try_call(mi, "get_Character")
    entity = try_call(mi, "get_CharacterEntity")
    resolve_module()
    return entity ~= nil
end

-- Damage multiplier: base getDamageRate + getAttackRate post-hooks count
-- rates only. The scaling lives on calcDamage outputs below.
local dmg_armed = false
local function install_rate_hook(td, mname)
    local ok_m, m = pcall(td.get_method, td, mname)
    if not ok_m or m == nil then
        proof.attached[mname] = false
        L(mname .. ": METHOD NOT FOUND")
        return false
    end
    local attached = pcall(sdk.hook, m, function(args)
        -- Post-hooks receive only retval: capture the module address here.
        local st = thread.get_hook_storage()
        st.dmg_this = 0
        pcall(function() st.dmg_this = sdk.to_int64(args[2]) end)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local st = thread.get_hook_storage()
        local this_addr = st.dmg_this or 0
        if this_addr ~= 0 and this_addr == player_mod_addr and player_mod_addr ~= 0 then
            proof.player_fires = proof.player_fires + 1
        elseif this_addr ~= 0 then
            local nkeys = 0
            for _ in pairs(proof.addrs) do nkeys = nkeys + 1 end
            if proof.addrs[this_addr] ~= nil or nkeys < 50 then
                proof.addrs[this_addr] = (proof.addrs[this_addr] or 0) + 1
            end
        end
        return retval
    end)
    proof.attached[mname] = attached
    L(mname .. " hook " .. (attached and "ATTACHED" or "FAILED"))
    return attached
end

-- Scale calcDamage's computed outputs on the cApplyParam. Whatever rates
-- fed the calc, the final numbers get xN. Player's own module excluded.
local function scale_param_number(param, fname, mult, is_int)
    local okv, v = pcall(param.get_field, param, fname)
    if not okv or type(v) ~= "number" then return end
    local nv = v * mult
    if is_int then nv = math.floor(nv + 0.5) end
    pcall(param.set_field, param, fname, nv)
end

local function install_calc_hook(td)
    local ok_m, m = pcall(td.get_method, td, "calcDamage")
    if not ok_m or m == nil then
        proof.attached["calcDamage"] = false
        L("calcDamage: METHOD NOT FOUND")
        return false
    end
    local attached = pcall(sdk.hook, m, function(args)
        -- Post-hooks receive only retval: capture module + param here.
        local st = thread.get_hook_storage()
        st.calc_this, st.calc_param = 0, nil
        pcall(function()
            st.calc_this = sdk.to_int64(args[2])
            st.calc_param = sdk.to_managed_object(args[3])
        end)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local mult = cfg.dmg
        local st = thread.get_hook_storage()
        local this_addr = st.calc_this or 0
        local param = st.calc_param
        st.calc_this, st.calc_param = 0, nil
        if this_addr ~= 0 then proof.calc_fires = proof.calc_fires + 1 end
        if mult == nil or mult <= 1.0 then return retval end
        if this_addr == 0 or this_addr == player_mod_addr or player_mod_addr == 0 then
            return retval
        end
        if param == nil then return retval end
        scale_param_number(param, "Damage", mult, false)
        scale_param_number(param, "HealthDecrease", mult, true)
        scale_param_number(param, "RikidoDamage", mult, false)
        scale_param_number(param, "RikidoDecrease", mult, true)
        proof.calc_scaled = proof.calc_scaled + 1
        return retval
    end)
    proof.attached["calcDamage"] = attached
    L("calcDamage hook " .. (attached and "ATTACHED" or "FAILED"))
    return attached
end

-- Attribution: count calcDamage on the PLAYER's subclass (tells whether
-- the player's module computes outgoing hits).
local function install_player_calc_counter()
    local ok_td, td = pcall(sdk.find_type_definition, "app.cPlayerApplyDamage")
    if not ok_td or td == nil then return end
    local ok_m, m = pcall(td.get_method, td, "calcDamage")
    if not ok_m or m == nil then return end
    pcall(sdk.hook, m, function(args)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        proof.player_calc_fires = (proof.player_calc_fires or 0) + 1
        return retval
    end)
end

local function install_enemy_calc_hook()
    local ok_td, td = pcall(sdk.find_type_definition, "app.cEnemyApplyDamage")
    if not ok_td or td == nil then
        proof.enemy_hook = "type missing"
        return
    end
    local ok_m, m = pcall(td.get_method, td, "calcDamage")
    if not ok_m or m == nil then
        proof.enemy_hook = "method missing"
        return
    end
    local attached = pcall(sdk.hook, m, function(args)
        local st = thread.get_hook_storage()
        st.ecalc_param = nil
        pcall(function() st.ecalc_param = sdk.to_managed_object(args[3]) end)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local mult = cfg.dmg
        local st = thread.get_hook_storage()
        local param = st.ecalc_param
        st.ecalc_param = nil
        proof.enemy_fires = (proof.enemy_fires or 0) + 1
        if mult == nil or mult <= 1.0 or param == nil then return retval end
        scale_param_number(param, "Damage", mult, false)
        scale_param_number(param, "HealthDecrease", mult, true)
        scale_param_number(param, "RikidoDamage", mult, false)
        scale_param_number(param, "RikidoDecrease", mult, true)
        proof.enemy_scaled = (proof.enemy_scaled or 0) + 1
        return retval
    end)
    proof.enemy_hook = attached and "ATTACHED" or "FAILED"
    L("enemy calc hook: " .. proof.enemy_hook)
end

local function install_dmg_hook()
    if dmg_armed then return end
    local ok_td, td = pcall(sdk.find_type_definition, "app.cCharacterApplyDamage")
    if not ok_td or td == nil then
        L("cCharacterApplyDamage: TYPE NOT FOUND")
        return
    end
    local a = install_rate_hook(td, "getDamageRate")
    local b = install_rate_hook(td, "getAttackRate")
    local c = install_calc_hook(td)
    if a or b or c then dmg_armed = true end
end

install_dmg_hook()
install_player_calc_counter()
install_enemy_calc_hook()

local tick = 0
local function write_proof()
    local addrs, n = {}, 0
    for addr, fires in pairs(proof.addrs) do
        if n < 10 then addrs[tostring(addr)] = fires n = n + 1 end
    end
    pcall(json.dump_file, PROOF_FILE, {
        version = VERSION, tick = tick, cfg = { dmg = cfg.dmg },
        mod_addr = proof.mod_addr, attached = proof.attached,
        addrs = addrs, mult_hits = proof.mult_hits, player_fires = proof.player_fires,
        calc_fires = proof.calc_fires, calc_scaled = proof.calc_scaled,
        entity_type = proof.entity_type, mod_step = proof.mod_step,
        enemy_hook = proof.enemy_hook, enemy_fires = proof.enemy_fires or 0,
        enemy_scaled = proof.enemy_scaled or 0,
        player_calc_fires = proof.player_calc_fires or 0,
    })
end

-- Keep the player/module resolution warm (cheap, 1x/60 frames).
re.on_pre_application_entry("UpdateMotion", function()
    tick = tick + 1
    if tick % 60 == 0 then resolve_player() end
    if tick % 600 == 0 then write_proof() end
end)

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        local active = cfg.dmg > 1.0 and ("ACTIVE: " .. fmt_mult(cfg.dmg)) or "OFF"
        imgui.text_colored(active, cfg.dmg > 1.0 and 0xFF40FF40 or 0xFF808080)
        imgui.text("Damage multiplier:")
        for i, v in ipairs(PRESETS) do
            if i > 1 then imgui.same_line() end
            local label = (cfg.dmg == v) and ("[" .. fmt_mult(v) .. "]") or fmt_mult(v)
            if imgui.button(label) then cfg.dmg = v save() end
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    write_proof()
    chara, entity, player_go, player_mod_addr = nil, nil, nil, 0
    proof.addrs, proof.mult_hits, proof.player_fires = {}, 0, 0
    proof.calc_fires, proof.calc_scaled = 0, 0
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
