-- Damage & Attack Speed v2.3 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- v2.3: ring data proved kicks land on time, so the delay is AFTER our
-- writes. Two hardening fixes: (1) force-rewrite - the layer_out cache
-- assumed our speeds persist, but if the game resets layer speed on an
-- action enter the cache would skip rewrites forever; now doEnter kicks
-- and clip changes force a full rewrite. (2) attack-recovery gate - past
-- ~60% of an attack clip, MOV may engage (strike itself never gets it),
-- so sprint chained out of a swing doesn't wait out the full recovery.
-- Plus layer-0 speed sampled into the proof, showing whether our speed
-- actually sticks on the layer.
--
-- v1.3: proof showed mod_addr:0, so the player-module gate blocked ALL
-- scaling at any setting. Module resolution is now multi-step with a trail
-- (direct field, then full field-type scan), the entity type name is
-- recorded, the player-subclass calc is counted, and an enemy-subclass calc
-- hook is attempted at runtime (registry absence may just be dump reach).
-- No behavior change except the resolution fix; attribution data decides v1.4.
--
-- Sliders at 1.0 = off. Fire counters go to damage_proof.json.
--
-- Menu: REFramework -> ScriptRunner -> "Damage & Attack Speed v1.6".
-- Config: reframework/data/damage_attack_speed.json (stable across versions).

local MOD, VERSION, CFG_FILE = "DamageSpeed", "2.3", "damage_attack_speed.json"
local PROOF_FILE = "damage_proof.json"
local TAG = "[" .. MOD .. "] "
local MAX_LAYERS = 64

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { dmg = 1.0, atk = 1.0, mov = 1.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.dmg) == "number" then cfg.dmg = math.max(1.0, math.min(10.0, saved.dmg)) end
        if type(saved.atk) == "number" then cfg.atk = math.max(1.0, math.min(3.0, saved.atk)) end
        if type(saved.mov) == "number" then
            cfg.mov = math.max(1.0, math.min(3.0, saved.mov))
        elseif type(saved.act) == "number" then
            cfg.mov = math.max(1.0, math.min(3.0, saved.act)) -- v1.1-v1.4 -> v1.5
        elseif type(saved.spd) == "number" then
            cfg.mov = math.max(1.0, math.min(3.0, saved.spd)) -- v1.0 -> v1.5
        end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end

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
-- Declared BEFORE the proof block: resolve_module (below) reads/writes them.
local chara, entity, player_go, player_mod_addr = nil, nil, nil, 0
local resolve_cooldown = 0
-- v1.4 write-skip + category caches, also before resolve_player (which
-- clears them on player change) so nothing binds to globals.
local layer_orig, layer_out = {}, {}
local cat_cache_addr, cat_cache_val = 0, nil
local proof = { mod_addr = 0, attached = {}, addrs = {}, mult_hits = 0, player_fires = 0,
    calc_fires = 0, calc_scaled = 0, entity_type = "-", mod_step = "-",
    enemy_hook = "-", player_calc_fires = 0, ring = {} }

local function type_name_of(obj)
    if obj == nil then return "nil" end
    local ok, td = pcall(obj.get_type_definition, obj)
    if ok and td ~= nil then
        local okn, n = pcall(td.get_full_name, td)
        if okn and n then return tostring(n) end
    end
    return "?"
end

-- v1.3 module resolution: direct field first, then scan every field for the
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
        layer_out = {}
        cat_cache_addr, cat_cache_val = 0, nil
    end
    chara = try_call(mi, "get_Character")
    entity = try_call(mi, "get_CharacterEntity")
    resolve_module()
    return entity ~= nil
end

-- Damage multiplier: base getDamageRate + getAttackRate post-hooks (v1.0
-- proved rate alone is not the choke). Player's own module passes through;
-- everything else gets xN. Player-module fires are counted (not multiplied)
-- to settle attacker vs victim attribution from normal play.
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
        -- v1.2: rates count only (multiplying them did nothing). The scaling
        -- moved to calcDamage outputs below.
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

-- v1.2 primary: scale calcDamage's computed outputs on the cApplyParam.
-- Whatever rates fed the calc, the final numbers get xN. Player's own
-- module excluded, same as the rates.
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

-- v1.3 attribution: count calcDamage on the PLAYER's subclass (tells whether
-- the player's module computes outgoing hits), and try an enemy-subclass
-- calc hook at runtime (enemies-only by construction if it resolves).
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

-- Attack speed: scale the player's motion layers, remember originals.
-- (layer_orig/layer_out declared with the other state near the top.)
local motion, motion_go_addr = nil, 0
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

-- v1.4: last-written mult per layer, so steady state costs zero game calls.
-- (table itself declared near the top.)
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

local tick = 0
local function write_proof()
    local addrs, n = {}, 0
    for addr, fires in pairs(proof.addrs) do
        if n < 10 then addrs[tostring(addr)] = fires n = n + 1 end
    end
    pcall(json.dump_file, PROOF_FILE, {
        version = VERSION, tick = tick, cfg = { dmg = cfg.dmg, atk = cfg.atk, mov = cfg.mov },
        mod_addr = proof.mod_addr, attached = proof.attached,
        addrs = addrs, mult_hits = proof.mult_hits, player_fires = proof.player_fires,
        calc_fires = proof.calc_fires, calc_scaled = proof.calc_scaled,
        entity_type = proof.entity_type, mod_step = proof.mod_step,
        enemy_hook = proof.enemy_hook, enemy_fires = proof.enemy_fires or 0,
        enemy_scaled = proof.enemy_scaled or 0,
        player_calc_fires = proof.player_calc_fires or 0,
        mov_hold = proof.mov_hold_state or 0, mov_latched = proof.mov_latched_state or false,
        mov_blocked = proof.mov_blocked or "-",
        mov_speed = proof.mov_speed or 0,
        last_source = proof.last_source or "-", last_clip = proof.last_clip or "?",
        last_act = proof.last_act or "?", ring = proof.ring,
        layer_speed = proof.layer_speed or 0,
    })
end

-- Action category from the player's current base action class. Attack and
-- move classes follow the installed AnimationCancel mod's naming precedent.
-- v1.4: cached per action object (recomputed only when it changes).
-- (cache vars declared near the top.)
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
            elseif n:find("Run") or n:find("Walk") or n:find("Dash") or n:find("Sprint")
                or n:find("Move") or n:find("Turn") or n:find("Strafe") or n:find("Jog") then
                cat = "move"
            else
                cat = "other"
            end
        end
    end
    if ok_addr and act_addr ~= 0 then
        cat_cache_addr, cat_cache_val = act_addr, cat
    end
    return cat
end

-- Root translation rate: the game normalises loop root motion back to its
-- designed speed, so locomotion needs the entity rate scaled too (installed
-- RunSpeed mod's finding). Attacks carry their travel in the clip itself.
-- v1.4: vectors reused per mult value instead of allocated per frame.
local ONE_VEC = Vector3f.new(1.0, 1.0, 1.0)
local rate_vecs = {}
local rate_applied, rate_mult = false, 1.0
local function rate_vec(mult)
    local v = rate_vecs[mult]
    if v == nil then
        v = Vector3f.new(mult, mult, mult)
        rate_vecs[mult] = v
    end
    return v
end
-- v1.8: write-through every frame while wanted. The game re-asserts
-- ActionRootTransRate on its own state changes, so a write-once cache
-- silently stops working (fast animation, vanilla travel). One set_ call
-- per frame is negligible.
local mov_latched, mov_latched_mult = false, 1.0 -- re-asserted post-update too
local mov_rate_on = false -- v1.9: rate applies on loops only, not transitions
local function sync_root_rate(mult, want)
    if entity == nil then return end
    if want and mult > 1.0 then
        pcall(entity.call, entity, "set_ActionRootTransRate", rate_vec(mult))
        rate_applied, rate_mult = true, mult
        mov_latched, mov_latched_mult, mov_rate_on = true, mult, true
    elseif rate_applied then
        local ok, r = pcall(entity.call, entity, "get_ActionRootTransRate")
        if ok and r ~= nil and math.abs(r.x - rate_mult) < 0.001 then
            pcall(entity.call, entity, "set_ActionRootTransRate", ONE_VEC)
        end
        rate_applied = false
        mov_latched, mov_rate_on = false, false
    else
        mov_latched, mov_rate_on = false, false
    end
end

-- v1.7 movement: latched, not per-frame gated. Any locomotion sign engages
-- scaling and a hold timer keeps it through transitions and stick flicker.
-- Engage sources (any one is enough):
--   1. locomotion-bank clip ( Walk/Run/Dash/Jog/Strafe/Turn/Step, INCLUDING
--      Start/Stop/Turn transitions - v1.5/v1.6 only covered Loop clips, so
--      every sprint->walk change dropped to x1.0 for a beat);
--   2. move action class (catches the first step before travel exists);
--   3. measured travel (covers tap-dash and anything the lists miss).
-- Climb/crawl/gap actions are excluded by class name (FasterInteractions
-- owns those with exact timing). While latched, layers + root rate are
-- re-applied every frame; restore happens only after the hold expires.
local CLIMB_KEYS = { "Ladder", "Crawl", "GoThrough", "Climb", "Creep" }
local MOVE_ENUMS = {
    "app.plc_BaseMove_Mot.SetID",
    "app.plw_KatateMove_Mot.SetID",
    "app.plw_RyoteMove_Mot.SetID",
    "app.plw_tree_Mot.SetID",
    "app.plw_SubWeapon_Mot.SetID",
}
local LOCO_KEYS = { "Walk", "Run", "Dash", "Sprint", "Jog", "Strafe", "Turn", "Step", "Move" }
local MOT_EXCLUDE = { "StepJump", "GenericFalling", "Falling", "NPC_", "Over_The_Fence",
    "Ladder", "Ledge", "Jump", "WallRun", "Guard", "Issen", "Bow", "QuickShot", "Tired" }
local mot_names = {}
do
    local n = 0
    for _, tname in ipairs(MOVE_ENUMS) do
        local ok_td, td = pcall(sdk.find_type_definition, tname)
        if ok_td and td ~= nil then
            local okf, fields = pcall(td.get_fields, td)
            if okf and fields ~= nil then
                for _, f in pairs(fields) do
                    local fname = nil
                    pcall(function() fname = f:get_name() end)
                    if fname ~= nil and fname ~= "value__" then
                        local okv, v = pcall(f.get_data, f, nil)
                        if okv and type(v) == "number" then
                            local bank = math.floor(v / 4096)
                            mot_names[bank] = mot_names[bank] or {}
                            mot_names[bank][v % 4096] = fname
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    L("locomotion clip names loaded: " .. n)
end
local function clip_name_of(bank, motid)
    local t = mot_names[bank]
    return t and t[motid] or nil
end
local function is_loco_clip(bank, motid)
    local name = clip_name_of(bank, motid)
    if name == nil then return false end
    for _, s in ipairs(MOT_EXCLUDE) do
        if string.find(name, s, 1, true) then return false end
    end
    for _, k in ipairs(LOCO_KEYS) do
        if string.find(name, k, 1, true) then return true end
    end
    return false
end
-- v1.9: Loop clips normalise root motion (rate REQUIRED); transitions do
-- not (layer speed alone carries them, rate would double-multiply).
local function is_loop_clip(bank, motid)
    local name = clip_name_of(bank, motid)
    if name == nil then return false end
    return string.find(name, "Loop", 1, true) ~= nil
end
local travel_last, travel_t = nil, 0
local MOV_MIN_SPEED, MOV_MAX_STEP = 0.3, 5.0
local MOV_HOLD_FRAMES = 45 -- ~0.75s at 60fps: bridges transitions + stick flicker
local mov_hold = 0
-- v2.3: past this much of an attack clip the swing is recovery, not strike.
local REC_AT = 0.6
local last_bank, last_motid = nil, nil -- v2.3: clip changes force a rewrite
-- v2.1 engage/release event ring (last 12) for diagnosing delays from data.
local function ring_push(ev)
    proof.ring[#proof.ring + 1] = { t = tick, e = ev }
    while #proof.ring > 20 do table.remove(proof.ring, 1) end
end
local function current_action()
    if chara == nil then return nil end
    return try_call(chara, "get_BaseCurrentAction")
end
local function action_name()
    local act = current_action()
    if act == nil then return nil end
    local ok, td = pcall(act.get_type_definition, act)
    if not ok or td == nil then return nil end
    local okf, full = pcall(td.get_full_name, td)
    if not okf or type(full) ~= "string" then return nil end
    return full:match("([^.]+)$") or full
end
-- v2.0: FasterInteractions' action classes (same classification it uses).
-- While one of these runs, DamageSpeed stays out entirely: no MOV latch,
-- no hold bleed, no competing orig cache on the same layers.
local function is_interaction_action(act)
    if act == nil then return false end
    local ok, td = pcall(act.get_type_definition, act)
    if not ok or td == nil then return false end
    local function isa(name)
        local okr, r = pcall(td.is_a, td, name)
        return okr and r == true
    end
    if isa("app.PlayerCommonAction.cLadderActionBase") then return true end
    if isa("app.PlayerCommonAction.cCreepBase") then return true end
    if isa("app.PlayerCommonAction.cGoThroughBase") then return true end
    if isa("app.PlayerCommonAction.cInteractGimmickBase") then return true end
    local okf, full = pcall(td.get_full_name, td)
    if okf and type(full) == "string" and full:find("DemonTendon", 1, true) then
        return true
    end
    return false
end

re.on_pre_application_entry("UpdateMotion", function()
    tick = tick + 1
    if tick % 600 == 0 then write_proof() end
    -- v2.3: sample the actual layer-0 speed 1x/sec while latched. If the
    -- game resets speeds behind our back, this shows it in the proof.
    if tick % 60 == 0 and mov_hold > 0 then
        local mo_s = player_motion()
        local ly_s = mo_s and try_call(mo_s, "getLayer", 0) or nil
        local sp = ly_s and try_call(ly_s, "get_Speed") or nil
        if type(sp) == "number" then
            proof.layer_speed = math.floor(sp * 100) / 100
        end
    end
    local want_atk = cfg.atk ~= nil and cfg.atk > 1.0
    local want_mov = cfg.mov ~= nil and cfg.mov > 1.0
    if not want_atk and not want_mov then
        if next(layer_orig) ~= nil then restore_layers() end
        sync_root_rate(1.0, false)
        travel_last, mov_hold = nil, 0
        return
    end
    if not resolve_player() then travel_last = nil return end
    if player_go ~= nil and player_go:get_address() ~= motion_go_addr then
        restore_layers()
        motion = nil
        travel_last, mov_hold = nil, 0
    end
    local cat = action_category()
    local act = current_action()
    if cat == "attack" then
        -- v2.3: the strike never gets MOV, but past REC_AT of the clip it
        -- is recovery - fall through to the movement block so a chained
        -- sprint doesn't wait out the tail of the swing.
        local rec = nil
        if want_mov then
            local mo_r = player_motion()
            local ly_r = mo_r and try_call(mo_r, "getLayer", 0) or nil
            rec = ly_r and try_call(ly_r, "get_NormalizeTime") or nil
        end
        if type(rec) ~= "number" or rec < REC_AT then
            travel_last, mov_hold = nil, 0
            proof.mov_blocked = "attack"
            if want_atk then
                scale_layers(cfg.atk)
            elseif next(layer_orig) ~= nil then
                restore_layers()
            end
            sync_root_rate(1.0, false)
            return
        end
        proof.mov_blocked = "attack-rec"
    end
    if act ~= nil and is_interaction_action(act) then
        -- v2.0: FasterInteractions owns these actions (its own layer
        -- scaling runs after ours each frame). Stay out: clear the latch
        -- so no hold bleeds from the run into the interaction.
        travel_last, mov_hold = nil, 0
        proof.mov_blocked = "interact"
        if next(layer_orig) ~= nil then restore_layers() end
        sync_root_rate(1.0, false)
        return
    end
    if proof.mov_blocked ~= "attack-rec" then proof.mov_blocked = nil end
    if want_mov and player_go ~= nil then
        local aname = action_name()
        local climbing = false
        if aname ~= nil then
            for _, k in ipairs(CLIMB_KEYS) do
                if aname:find(k, 1, true) then climbing = true break end
            end
        end
        if climbing then
            travel_last, mov_hold = nil, 0
        else
            -- Source 1: locomotion-bank clip (loops AND transitions).
            -- v1.9: remember whether it is a Loop: only loops get the root
            -- rate (they normalise root motion); transitions get layer
            -- speed only (their travel already follows it - rate would
            -- double-multiply and cause the start-up zoom).
            local loco_clip, loop_clip = false, false
            local mo = player_motion()
            local layer = mo and try_call(mo, "getLayer", 0) or nil
            local bank = layer and try_call(layer, "get_MotionBankID") or nil
            local motid = layer and try_call(layer, "get_MotionID") or nil
            if type(bank) == "number" and type(motid) == "number" then
                if bank ~= last_bank or motid ~= last_motid then
                    -- v2.3: the game may reset layer speeds on clip changes;
                    -- drop the write cache so this frame rewrites for sure.
                    last_bank, last_motid = bank, motid
                    layer_out = {}
                end
                loco_clip = is_loco_clip(bank, motid)
                loop_clip = is_loop_clip(bank, motid)
            end
            -- Source 2: move action class (first step, before travel exists).
            local move_act = aname ~= nil and (aname:find("Run") or aname:find("Walk")
                or aname:find("Dash") or aname:find("Sprint") or aname:find("Move")
                or aname:find("Turn") or aname:find("Strafe") or aname:find("Jog")) or false
            -- Source 3: measured travel (tap-dash, anything the lists miss).
            local moving = false
            local tf = try_call(player_go, "get_Transform")
            local pos = tf and try_call(tf, "get_Position") or nil
            local now = os.clock()
            if pos ~= nil and travel_last ~= nil then
                local dx, dz = pos.x - travel_last.x, pos.z - travel_last.z
                local dist = math.sqrt(dx * dx + dz * dz)
                local dt = now - travel_t
                if dt > 0 and dt < 1.0 and dist < MOV_MAX_STEP then
                    moving = (dist / dt) > MOV_MIN_SPEED
                    proof.mov_speed = math.floor(dist / dt * 100) / 100
                end
            end
            if pos ~= nil then
                travel_last = { x = pos.x, z = pos.z }
                travel_t = now
            else
                travel_last = nil
            end
            if loco_clip or move_act or moving then
                local src = loco_clip and "clip" or (move_act and "action" or "travel")
                if mov_hold <= 0 then
                    ring_push("engage:" .. src)
                    proof.last_source = src
                    proof.last_clip = clip_name_of(bank, motid) or "?"
                    proof.last_act = aname or "?"
                end
                mov_hold = MOV_HOLD_FRAMES
            elseif mov_hold > 0 then
                mov_hold = mov_hold - 1
                if mov_hold == 0 then ring_push("release") end
            end
            if mov_hold > 0 then
                -- Latch drives layer speed everywhere; root rate on loops
                -- only, actively reset on transitions (kills the zoom).
                -- move_act/moving engages without clip info: assume a loop
                -- is coming and allow the rate (it self-corrects next
                -- frame once the clip is known).
                local want_rate = loop_clip or (not loco_clip and (move_act or moving))
                scale_layers(cfg.mov)
                sync_root_rate(cfg.mov, want_rate)
                proof.mov_hold_state, proof.mov_latched_state = mov_hold, true
                proof.mov_rate_state = want_rate
                return
            else
                proof.mov_hold_state, proof.mov_latched_state = mov_hold, mov_latched
                proof.mov_rate_state = false
            end
        end
    else
        travel_last = nil
    end
    if next(layer_orig) ~= nil then restore_layers() end
    sync_root_rate(1.0, false)
end)

-- v1.8: re-assert AFTER the game's own motion update. Whatever the game
-- recomputes during UpdateMotion gets overridden right after, so the rate
-- holds until next frame no matter where root motion is consumed.
re.on_application_entry("UpdateMotion", function()
    if not mov_latched or not mov_rate_on or entity == nil then return end
    local m = mov_latched_mult
    if m == nil or m <= 1.0 then return end
    pcall(entity.call, entity, "set_ActionRootTransRate", rate_vec(m))
end)

-- v2.2 event-driven kick-start: apply MOV the exact frame a locomotion
-- action enters instead of waiting for the poll to observe a clip, an
-- action class, or measured travel. Layers + full hold only (the poll
-- decides the root rate next frame, so transitions can't zoom).
-- Attack/interaction enters just clear the latch and trace.
local LOCO_ACT_KEYS = { "Run", "Walk", "Dash", "Sprint", "Move", "Turn", "Strafe", "Jog" }
local function is_loco_action_name(n)
    if n == nil then return false end
    for _, k in ipairs(LOCO_ACT_KEYS) do
        if n:find(k, 1, true) then return true end
    end
    return false
end
do
    local doenter_m = nil
    local ok_td, base_td = pcall(sdk.find_type_definition, "app.PlayerActionBase.cPlayerActionBase")
    if ok_td and base_td ~= nil then
        local okm, m = pcall(base_td.get_method, base_td, "doEnter")
        if okm and m ~= nil then doenter_m = m end
    end
    if doenter_m ~= nil then
        pcall(sdk.hook, doenter_m, function(args)
            if cfg.mov == nil or cfg.mov <= 1.0 then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            local ok_act, act = pcall(sdk.to_managed_object, args[2])
            if not ok_act or act == nil then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            if not resolve_player() or entity == nil then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            -- Only our own player's actions.
            local ok_e, aenty = pcall(act.call, act, "get_CharacterEntity")
            if not ok_e or aenty == nil then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            local ok_a1, a1 = pcall(aenty.get_address, aenty)
            local ok_a2, a2 = pcall(entity.get_address, entity)
            if not ok_a1 or not ok_a2 or a1 ~= a2 then
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            local ok_td2, td = pcall(act.get_type_definition, act)
            local short = "?"
            if ok_td2 and td ~= nil then
                local okf, full = pcall(td.get_full_name, td)
                if okf and type(full) == "string" then
                    short = full:match("([^.]+)$") or full
                end
            end
            if short:find("Attack", 1, true) then
                travel_last, mov_hold = nil, 0
                ring_push("act-enter:attack " .. short)
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            if is_interaction_action(act) then
                travel_last, mov_hold = nil, 0
                ring_push("act-enter:interact " .. short)
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            if is_loco_action_name(short) then
                mov_hold = MOV_HOLD_FRAMES
                travel_last = nil
                layer_out = {} -- v2.3: force the write; game may have reset speeds
                scale_layers(cfg.mov)
                proof.last_source, proof.last_act = "doenter", short
                local mo_k = player_motion()
                local ly_k = mo_k and try_call(mo_k, "getLayer", 0) or nil
                local bk = ly_k and try_call(ly_k, "get_MotionBankID") or nil
                local mi = ly_k and try_call(ly_k, "get_MotionID") or nil
                if type(bk) == "number" and type(mi) == "number" then
                    proof.last_clip = clip_name_of(bk, mi) or "?"
                else
                    proof.last_clip = "?"
                end
                ring_push("kick:" .. short)
            end
            return sdk.PreHookResult.CALL_ORIGINAL
        end)
        L("doEnter kick-start hooked")
    else
        L("doEnter NOT FOUND - kick-start disabled, poll only")
    end
end

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        local parts = {}
        if cfg.dmg > 1.0 then parts[#parts + 1] = string.format("DMG x%.1f", cfg.dmg) end
        if cfg.atk > 1.0 then parts[#parts + 1] = string.format("ATK x%.1f", cfg.atk) end
        if cfg.mov > 1.0 then parts[#parts + 1] = string.format("MOV x%.1f", cfg.mov) end
        local active = #parts > 0 and table.concat(parts, " + ") or "OFF"
        imgui.text_colored("ACTIVE: " .. active, #parts > 0 and 0xFF40FF40 or 0xFF808080)
        local chd, vd = imgui.slider_float("Damage", cfg.dmg, 1.0, 10.0, "x%.1f")
        if chd then cfg.dmg = vd save() end
        local cha, va = imgui.slider_float("Attack Speed", cfg.atk, 1.0, 3.0, "x%.1f")
        if cha then cfg.atk = va save() end
        local chc, vc = imgui.slider_float("Movement Speed", cfg.mov, 1.0, 3.0, "x%.1f")
        if chc then cfg.mov = vc save() end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    write_proof()
    restore_layers()
    sync_root_rate(1.0, false)
    chara, entity, player_go, player_mod_addr, motion = nil, nil, nil, 0, nil
    layer_out = {}
    cat_cache_addr, cat_cache_val = 0, nil
    travel_last, travel_t, mov_hold = nil, 0, 0
    mov_latched, mov_latched_mult, mov_rate_on = false, 1.0, false
    last_bank, last_motid = nil, nil
    proof.layer_speed = 0
    cat_cache_addr, cat_cache_val = 0, nil
    proof.addrs, proof.mult_hits, proof.player_fires = {}, 0, 0
    proof.calc_fires, proof.calc_scaled = 0, 0
    proof.ring, proof.last_source = {}, nil
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
