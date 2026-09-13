-- MoveSpeed v2.3 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- COMBINED stack (every piece earned its place):
-- layers (all loco clips) + root rate (loops only) + per-action override
-- fields (all loco actions), all re-applied per frame while latched, all
-- restored on exit. Detection: doEnter kick + clip/action/travel sources +
-- Sprint keywords + attack-recovery gate + interaction exclusions.
-- Proof is one comprehensive dump incl. PEAK speed per latch (answers
-- average-vs-peak) + override readback + ring. No more probe loops.
--
-- Menu: REFramework -> ScriptRunner -> "MoveSpeed v2.3".
-- Config: reframework/data/movement_speed.json. Proof: mov_proof.json.
--
-- Slider at 1.0 = off.
--

local MOD, VERSION, CFG_FILE = "MoveSpeed", "2.3", "movement_speed.json"
local PROOF_FILE = "mov_proof.json"
local TAG = "[" .. MOD .. "] "
local MAX_LAYERS = 64

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { mov = 1.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.mov) == "number" then cfg.mov = math.max(1.0, math.min(3.0, saved.mov)) end
    else
        -- Fresh install: carry over the combo script's setting once.
        local oko, old = pcall(json.load_file, "damage_attack_speed.json")
        if oko and type(old) == "table" and type(old.mov) == "number" then
            cfg.mov = math.max(1.0, math.min(3.0, old.mov))
        end
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
local function field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(obj.get_field, obj, name)
    if ok then return r end
    return nil
end
local function set(obj, name, value)
    if obj == nil then return false end
    return pcall(obj.set_field, obj, name, value)
end

-- Player handles.
local chara, entity, player_go = nil, nil, nil
local resolve_cooldown = 0
-- Write-skip + category caches, before resolve_player (which clears them
-- on player change) so nothing binds to globals.
local layer_orig, layer_out = {}, {}
local cat_cache_addr, cat_cache_val = 0, nil
local proof = { entity_type = "-", ring = {} }


local function resolve_player()
    if resolve_cooldown > 0 then resolve_cooldown = resolve_cooldown - 1 return entity ~= nil end
    resolve_cooldown = 60
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = pm and try_call(pm, "getControllingPlayer") or nil
    local go = mi and try_call(mi, "get_Object") or nil
    if go == nil then return false end
    if player_go == nil or go:get_address() ~= player_go:get_address() then
        player_go, entity, chara = go, nil, nil
        layer_out = {}
        cat_cache_addr, cat_cache_val = 0, nil
    end
    chara = try_call(mi, "get_Character")
    entity = try_call(mi, "get_CharacterEntity")
    if entity ~= nil then
        pcall(function()
            local td = entity:get_type_definition()
            if td ~= nil then proof.entity_type = tostring(td:get_full_name()) end
        end)
    end
    return entity ~= nil
end


-- Motion layers: scale them, remember originals.
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
    pcall(json.dump_file, PROOF_FILE, {
        version = VERSION, tick = tick, cfg = { mov = cfg.mov },
        entity_type = proof.entity_type,
        mov_hold = proof.mov_hold_state or 0, mov_latched = proof.mov_latched_state or false,
        mov_blocked = proof.mov_blocked or "-",
        mov_speed = proof.mov_speed or 0,
        last_source = proof.last_source or "-", last_clip = proof.last_clip or "?",
        last_act = proof.last_act or "?", ring = proof.ring,
        layer_speed = proof.layer_speed or 0,
        -- v2.3 combined dump: override leg + peak per latch
        ov_action = ov_name, ov_use = ov_use, ov_speed = ov_speed,
        peak = peak,
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

-- v2.3 combined: per-action override fields (proven-landing float writes).
-- Remembered per action object at kick; re-applied per frame while latched;
-- originals restored on exit. Third leg next to layers + rate.
local ov_action, ov_addr, ov_name, ov_use, ov_speed = nil, nil, "-", nil, nil
local function ov_remember(act, name)
    local ok_a, addr = pcall(function() return act:get_address() end)
    if not ok_a or addr == nil then return end
    ov_action, ov_addr, ov_name = act, addr, name or "?"
    ov_use = field(act, "_UseOverrideMotionSpeed")
    ov_speed = field(act, "_OverrideMotionSpeed")
end
local function ov_apply()
    if ov_action == nil then return end
    if cfg.mov == nil or cfg.mov <= 1.0 then return end
    set(ov_action, "_UseOverrideMotionSpeed", true)
    set(ov_action, "_OverrideMotionSpeed", cfg.mov)
    ov_use = field(ov_action, "_UseOverrideMotionSpeed")
    ov_speed = field(ov_action, "_OverrideMotionSpeed")
end
local function ov_restore()
    if ov_action == nil then return end
    local a, u, s = ov_action, ov_use, ov_speed
    ov_action, ov_addr, ov_name = nil, nil, "-"
    pcall(function()
        a:set_field("_UseOverrideMotionSpeed", u)
        a:set_field("_OverrideMotionSpeed", s)
    end)
end
-- PEAK speed per latch (answers average-vs-peak in one dump).
local peak = 0

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
    local want_mov = cfg.mov ~= nil and cfg.mov > 1.0
    if not want_mov then
        if next(layer_orig) ~= nil then restore_layers() end
        sync_root_rate(1.0, false)
        ov_restore() -- v2.3: override leg down too
        travel_last, mov_hold = nil, 0
        return
    end
    if not resolve_player() then travel_last = nil return end
    if player_go ~= nil and player_go:get_address() ~= motion_go_addr then
        restore_layers()
        motion = nil
        ov_restore() -- owner changed; drop the stored action
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
            if next(layer_orig) ~= nil then restore_layers() end
            sync_root_rate(1.0, false)
            ov_restore() -- v2.3
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
        ov_restore() -- v2.3
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
                    peak = 0 -- v2.3: fresh latch, fresh peak
                end
                mov_hold = MOV_HOLD_FRAMES
            elseif mov_hold > 0 then
                mov_hold = mov_hold - 1
                if mov_hold == 0 then ring_push("release") end
            end
            if mov_hold > 0 then
                -- v2.3 COMBINED: layers + loops-only rate + per-action override.
                -- Keep the stored override action honest: re-home when the
                -- current action changed, adopt poll-side on clip/action
                -- evidence only (never on bare travel drift).
                if ov_action ~= nil and act ~= nil then
                    local ok_c, ca = pcall(function() return act:get_address() end)
                    if ok_c and ca ~= nil and ca ~= ov_addr then
                        ov_restore()
                        ov_remember(act, aname)
                    end
                elseif ov_action == nil and act ~= nil and (loco_clip or move_act) then
                    ov_remember(act, aname)
                end
                local want_rate = loop_clip or (not loco_clip and (move_act or moving))
                scale_layers(cfg.mov)
                sync_root_rate(cfg.mov, want_rate)
                ov_apply() -- third leg; no-ops without a stored action
                if type(proof.mov_speed) == "number" and proof.mov_speed > peak then
                    peak = proof.mov_speed
                end
                proof.mov_hold_state, proof.mov_latched_state = mov_hold, true
                proof.mov_rate_state = want_rate
                proof.peak = peak
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
    ov_restore() -- v2.3: hold fully expired
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
                ov_restore() -- v2.3: strikes never carry override
                ring_push("act-enter:attack " .. short)
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            if is_interaction_action(act) then
                travel_last, mov_hold = nil, 0
                ov_restore() -- v2.3
                ring_push("act-enter:interact " .. short)
                return sdk.PreHookResult.CALL_ORIGINAL
            end
            if is_loco_action_name(short) then
                mov_hold = MOV_HOLD_FRAMES
                travel_last = nil
                layer_out = {} -- v2.3: force the write; game may have reset speeds
                scale_layers(cfg.mov)
                ov_restore() -- new action, fresh override state
                ov_remember(act, short)
                ov_apply()
                peak = 0 -- v2.3: fresh latch, fresh peak
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
        local active = cfg.mov > 1.0 and ("ACTIVE: MOV x%.1f"):format(cfg.mov) or "OFF"
        imgui.text_colored(active, cfg.mov > 1.0 and 0xFF40FF40 or 0xFF808080)
        local chc, vc = imgui.slider_float("Movement Speed", cfg.mov, 1.0, 3.0, "x%.1f")
        if chc then cfg.mov = vc save() end
        imgui.text(string.format("Travel: %.2f m/s   PEAK: %.2f m/s", proof.mov_speed or 0, peak))
        imgui.text("Override: " .. tostring(ov_name) .. " use=" .. tostring(ov_use)
            .. " speed=" .. tostring(ov_speed))
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    write_proof()
    restore_layers()
    sync_root_rate(1.0, false)
    ov_restore() -- v2.3
    chara, entity, player_go, motion = nil, nil, nil, nil
    layer_orig, layer_out = {}, {}
    cat_cache_addr, cat_cache_val = 0, nil
    travel_last, travel_t, mov_hold = nil, 0, 0
    mov_latched, mov_latched_mult, mov_rate_on = false, 1.0, false
    last_bank, last_motid = nil, nil
    proof.layer_speed = 0
    proof.ring, proof.last_source = {}, nil
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
