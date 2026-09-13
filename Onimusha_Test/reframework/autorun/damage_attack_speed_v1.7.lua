-- Damage & Attack Speed v1.7 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- v1.7: movement latched ON while MOV is on. v1.6 keyed scaling off measured
-- travel each frame, so the first step (no travel yet) and every
-- sprint->walk/run transition (one slow frame) dropped back to x1.0 and had
-- to re-engage: visible delay. Now any locomotion sign (locomotion-bank
-- clip incl. Start/Stop/Turn transitions, move action class, or measured
-- motion) engages scaling and a 45-frame hold keeps it engaged through
-- transitions and stick flicker. Single owner rule: disable/remove the
-- standalone run_speed.lua while MOV is in use, both write layer speed +
-- root rate and will fight each other.
-- Climb/crawl/gap actions are excluded (the FasterInteractions mod owns
-- those and its timing is exact).
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

local MOD, VERSION, CFG_FILE = "DamageSpeed", "1.7", "damage_attack_speed.json"
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
            elseif n:find("Run") or n:find("Walk") or n:find("Dash") or n:find("Move")
                or n:find("Turn") or n:find("Strafe") or n:find("Jog") then
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
local function sync_root_rate(mult, want)
    if entity == nil then return end
    if want and mult > 1.0 then
        if rate_applied and rate_mult == mult then return end -- already set
        local ok = pcall(entity.call, entity, "set_ActionRootTransRate", rate_vec(mult))
        if ok then rate_applied, rate_mult = true, mult end
    elseif rate_applied then
        local ok, r = pcall(entity.call, entity, "get_ActionRootTransRate")
        if ok and r ~= nil and math.abs(r.x - rate_mult) < 0.001 then
            pcall(entity.call, entity, "set_ActionRootTransRate", ONE_VEC)
        end
        rate_applied = false
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
local LOCO_KEYS = { "Walk", "Run", "Dash", "Jog", "Strafe", "Turn", "Step", "Move" }
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
local function is_loco_clip(bank, motid)
    local t = mot_names[bank]
    local name = t and t[motid] or nil
    if name == nil then return false end
    for _, s in ipairs(MOT_EXCLUDE) do
        if string.find(name, s, 1, true) then return false end
    end
    for _, k in ipairs(LOCO_KEYS) do
        if string.find(name, k, 1, true) then return true end
    end
    return false
end
local travel_last, travel_t = nil, 0
local MOV_MIN_SPEED, MOV_MAX_STEP = 0.3, 5.0
local MOV_HOLD_FRAMES = 45 -- ~0.75s at 60fps: bridges transitions + stick flicker
local mov_hold = 0
local function action_name()
    if chara == nil then return nil end
    local act = try_call(chara, "get_BaseCurrentAction")
    if act == nil then return nil end
    local ok, td = pcall(act.get_type_definition, act)
    if not ok or td == nil then return nil end
    local okf, full = pcall(td.get_full_name, td)
    if not okf or type(full) ~= "string" then return nil end
    return full:match("([^.]+)$") or full
end

re.on_pre_application_entry("UpdateMotion", function()
    tick = tick + 1
    if tick % 600 == 0 then write_proof() end
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
    if cat == "attack" and want_atk then
        -- Attacks: animation speed carries travel; no root-rate scaling.
        -- An attack also ends any movement latch (dodge/attack cancels runs).
        travel_last, mov_hold = nil, 0
        scale_layers(cfg.atk)
        sync_root_rate(1.0, false)
        return
    end
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
            local loco_clip = false
            local mo = player_motion()
            local layer = mo and try_call(mo, "getLayer", 0) or nil
            local bank = layer and try_call(layer, "get_MotionBankID") or nil
            local motid = layer and try_call(layer, "get_MotionID") or nil
            if type(bank) == "number" and type(motid) == "number" then
                loco_clip = is_loco_clip(bank, motid)
            end
            -- Source 2: move action class (first step, before travel exists).
            local move_act = aname ~= nil and (aname:find("Run") or aname:find("Walk")
                or aname:find("Dash") or aname:find("Move") or aname:find("Turn")
                or aname:find("Strafe") or aname:find("Jog")) or false
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
                mov_hold = MOV_HOLD_FRAMES
            elseif mov_hold > 0 then
                mov_hold = mov_hold - 1
            end
            if mov_hold > 0 then
                scale_layers(cfg.mov)
                sync_root_rate(cfg.mov, true)
                return
            end
        end
    else
        travel_last = nil
    end
    if next(layer_orig) ~= nil then restore_layers() end
    sync_root_rate(1.0, false)
end)

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
    cat_cache_addr, cat_cache_val = 0, nil
    proof.addrs, proof.mult_hits, proof.player_fires = {}, 0, 0
    proof.calc_fires, proof.calc_scaled = 0, 0
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
