-- Faster Interactions  -- 1.1.0
-- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- Speeds up the slow interaction animations: Oni walls (demon tendons), doors,
-- treasure chests, ladders, crawl spaces, narrow gaps and elevators. One master
-- multiplier, plus an optional per-type override. Plain Lua, no C# API needed.
-- Mechanism: while one of those player actions is running, the action's
-- override motion speed and every motion layer of the player (and of the door
-- or chest being opened) are scaled by the multiplier. Ladder climbing is root
-- motion, so scaling the clips scales the climb; every climb clip except the top
-- dismount is covered. The fast slide down moves at a fixed engine rate instead,
-- so the missing distance is added each frame. Everything is put back when the
-- action exits. Elevators: the gimmick's move speed is scaled for the duration
-- of its own move update.
-- Menu: REFramework -> ScriptRunner -> "FasterInteractions". Config: reframework/data/faster_interactions.json.

local MOD, VERSION, CFG_FILE = "FasterInteractions", "1.1.0", "faster_interactions.json"

local KINDS = { "oni_wall", "door", "chest", "ladder", "crawl", "gap", "elevator" }
local LABEL = { oni_wall = "Oni walls", door = "Doors", chest = "Chests", ladder = "Ladders",
    crawl = "Crawl spaces", gap = "Narrow gaps", elevator = "Elevators" }
local ELEVATOR_MOVE = 3          -- app.GimmickElevator.MOVE_STATE.MOVE
local DOOR_OPENING = 0           -- app.GimmickDoor.GM_DOOR_STATE.OPENING
local CHEST_OPENING = 2          -- app.GimmickTreasureBox.STATE.OPENING
local MAX_LAYERS = 64

local cfg = { enabled = true, speed = 3.0, oni_wall = true, door = true, chest = true, ladder = true,
    crawl = true, gap = true, elevator_down = true, elevator_up = false,
    speed_oni_wall = 0.0, speed_door = 0.0, speed_chest = 0.0, speed_ladder = 0.0,
    speed_crawl = 0.0, speed_gap = 0.0, speed_elevator = 0.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end end
    else
        pcall(json.dump_file, CFG_FILE, cfg)   -- first launch: write defaults so the loader stops complaining
    end
end
local function save_cfg() pcall(json.dump_file, CFG_FILE, cfg) end

local function info(m) log.info("[" .. MOD .. "] " .. tostring(m)) end
local function try(obj, name, ...)
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
local function hook(tn, mn, pre, post)
    local td = sdk.find_type_definition(tn)
    local m = td and td:get_method(mn)
    if m == nil then info("missing " .. tn .. "." .. mn .. " (game build changed?)"); return false end
    local ok, err = pcall(sdk.hook, m, pre, post)
    if not ok then info("hook failed " .. tn .. "." .. mn .. ": " .. tostring(err)); return false end
    return true
end
local function is_a(td, name)
    local ok, r = pcall(td.is_a, td, name)
    return ok and r == true
end

local function speed_for(kind)
    local s = cfg["speed_" .. kind]
    if s == nil or s < 1.0 then s = cfg.speed end
    if s < 1.0 then s = 1.0 end
    return s
end

local function name_of(action)
    local ok, td = pcall(action.get_type_definition, action)
    return (ok and td) and td:get_full_name() or ""
end

-- Which interaction an action object is, or nil. Also returns the gimmick for doors and chests.
local function classify(action)
    local ok, td = pcall(action.get_type_definition, action)
    if not ok or td == nil then return nil end
    local name = td:get_full_name()
    if name:find("DemonTendonInterruption", 1, true) then
        return cfg.oni_wall and "oni_wall" or nil
    end
    if is_a(td, "app.PlayerCommonAction.cLadderActionBase") then
        -- Every climb clip: mount, loop, fast slide, slide stop and the bottom dismount. Movement
        -- is root motion, so scaling the clip scales the climb. Idle, attacks, guard, damage and
        -- falls stay. The top dismount (UpEnd) stays too: sped up, it releases the ladder before
        -- Musashi reaches the ledge and he falls back onto it (log-verified 2026-09-09).
        if name:find("cLadderClimb", 1, true) and not name:find("UpEnd", 1, true) then
            return cfg.ladder and "ladder" or nil
        end
        return nil
    end
    if is_a(td, "app.PlayerCommonAction.cCreepBase") then
        -- Crawl under low gaps: start, move and end clips. The idle has nothing to speed up.
        if name:find("Idle", 1, true) then return nil end
        return cfg.crawl and "crawl" or nil
    end
    if is_a(td, "app.PlayerCommonAction.cGoThroughBase") then
        -- Sliding sideways through a narrow gap.
        return cfg.gap and "gap" or nil
    end
    if is_a(td, "app.PlayerCommonAction.cInteractGimmickBase") then
        local gm = field(action, "_ActionGimmick") or try(action, "get_ActionGimmick")
        local gok, gtd = pcall(function() return gm:get_type_definition() end)
        if not gok or gtd == nil then return nil end
        if is_a(gtd, "app.GimmickDoor") then return cfg.door and "door" or nil, gm end
        if is_a(gtd, "app.GimmickTreasureBox") then return cfg.chest and "chest" or nil, gm end
    end
    return nil
end

-- Motion layer scaling with remembered originals (keyed by layer address).
local function scale_layers(motion, mult, originals)
    if motion == nil then return end
    for _, pair in ipairs({ { "getLayerCount", "getLayer" }, { "getPrivateLayerCount", "getPrivateLayer" } }) do
        local count = try(motion, pair[1]) or 0
        if count > MAX_LAYERS then count = MAX_LAYERS end
        for i = 0, count - 1 do
            local layer = try(motion, pair[2], i)
            if layer ~= nil then
                local addr = layer:get_address()
                local orig = originals[addr]
                if orig == nil then
                    orig = try(layer, "get_Speed")
                    if orig ~= nil then originals[addr] = { layer = layer, speed = orig } end
                else
                    orig = orig.speed
                end
                if orig ~= nil and orig > 0 then try(layer, "set_Speed", orig * mult) end
            end
        end
    end
end
local function restore_layers(originals)
    for addr, o in pairs(originals) do
        pcall(function() o.layer:call("set_Speed", o.speed) end)
        originals[addr] = nil
    end
end

-- Player motion component, cached by GameObject address.
local player_go, player_motion, player_chara = nil, nil, nil
local function player_objects()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = try(pm, "getControllingPlayer")
    local go = try(mi, "get_Object")
    if go == nil then player_go, player_motion, player_chara = nil, nil, nil; return nil, nil end
    if player_go == nil or go:get_address() ~= player_go:get_address() then
        player_go = go
        player_motion = try(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        player_chara = try(mi, "get_Character")
    end
    return player_motion, player_chara
end

local function gimmick_motion(gm)
    return field(field(gm, "_McMotion"), "_Motion")
end

-- The one interaction currently accelerated.
local active = nil     -- { action, addr, kind, gm, orig_use, orig_speed, boost, layers = {}, gm_layers = {} }
local boost_prev = nil     -- player position after our last movement boost
local adjust = nil         -- { timer = ace.cTimer, last, kind }: crawl / gap entry-alignment timer being boosted
local tail = nil       -- door / chest still opening after the player action ended: { gm, kind, layers = {} }
local stats = { started = 0, last = "-" }

local function restore_active()
    if active == nil then return end
    local a = active
    active = nil
    restore_layers(a.layers)
    pcall(function()
        a.action:set_field("_UseOverrideMotionSpeed", a.orig_use)
        a.action:set_field("_OverrideMotionSpeed", a.orig_speed)
    end)
    boost_prev = nil
    if a.gm ~= nil then
        -- Keep the door or chest moving fast until its own opening state ends.
        tail = { gm = a.gm, kind = a.kind, layers = a.gm_layers }
    else
        restore_layers(a.gm_layers)
    end
end

local function restore_tail()
    if tail == nil then return end
    local t = tail
    tail = nil
    restore_layers(t.layers)
end

local function gimmick_opening(gm, kind)
    if kind == "door" then return try(gm, "get_CurrentState") == DOOR_OPENING end
    if kind == "chest" then return try(gm, "get_State") == CHEST_OPENING end
    return false
end

local function begin(action)
    local kind, gm = classify(action)
    if kind == nil then return end
    if active ~= nil and active.addr == action:get_address() then return end
    restore_active()
    if tail ~= nil and gm ~= nil and tail.gm:get_address() == gm:get_address() then
        -- Same gimmick again: reuse its remembered originals instead of scaling twice.
        active = { layers = {}, gm_layers = tail.layers }
        tail = nil
    else
        restore_tail()
        active = { layers = {}, gm_layers = {} }
    end
    active.action, active.addr, active.kind, active.gm = action, action:get_address(), kind, gm
    active.orig_use = field(action, "_UseOverrideMotionSpeed")
    active.orig_speed = field(action, "_OverrideMotionSpeed")
    -- The ladder fast slide and the narrow-gap pass are not root motion: the engine moves
    -- Musashi at a fixed rate whatever the clip speed, so boost_move() adds the missing
    -- distance each frame ("y" = downward only, "xz" = along the ground).
    if kind == "gap" then active.boost = "xz"
    elseif kind == "ladder" and name_of(action):find("DownFastLoop", 1, true) then active.boost = "y" end
    -- Crawl starts and gap passes align Musashi to the opening by lerping over _AdjustTimer in
    -- real time; at clip speed 3x that lerp wins and drags him back to the entrance. The timer
    -- is boosted in step with the clip (boost_adjust); it lives on the start action, so keep it
    -- through the following crawl move / end actions.
    if kind == "crawl" or kind == "gap" then
        local timer = field(action, "_AdjustTimer")
        if timer ~= nil then adjust = { timer = timer, kind = kind } end
    else
        adjust = nil
    end
    stats.started, stats.last = stats.started + 1, LABEL[kind]
end

local function apply_active()
    if active == nil then return end
    local mult = speed_for(active.kind)
    set(active.action, "_UseOverrideMotionSpeed", true)
    set(active.action, "_OverrideMotionSpeed", mult)
    local motion = player_objects()
    scale_layers(motion, mult, active.layers)
    if active.gm ~= nil then scale_layers(gimmick_motion(active.gm), mult, active.gm_layers) end
end

hook("app.PlayerActionBase.cPlayerActionBase", "doEnter", function(args)
    if not cfg.enabled then return end
    local action = sdk.to_managed_object(args[2])
    if action == nil then return end
    pcall(begin, action)
    pcall(apply_active)
end, function(retval)
    if cfg.enabled then pcall(apply_active) end
    return retval
end)

hook("app.PlayerActionBase.cPlayerActionBase", "doExit", function(args)
    if active ~= nil and args[2] ~= nil and sdk.to_int64(args[2]) == active.addr then pcall(restore_active) end
end)

-- Elevators: scale the gimmick's move speed only inside its own move update, so the
-- value stored on it is never left modified. Two gimmick classes: the vertical
-- app.GimmickElevator and the sideways lift app.Gm032_002. Direction comes from the
-- car's Y between updates; a sideways ride counts as "down" for the tick boxes.
local function enum_value(tn, name, fallback)
    local td = sdk.find_type_definition(tn)
    local ok, v = pcall(function() return td:get_field(name):get_data(nil) end)
    if ok and type(v) == "number" then return v end
    return fallback
end
local ELEVATORS = {
    { type = "app.GimmickElevator", move = enum_value("app.GimmickElevator.MOVE_STATE", "MOVE", ELEVATOR_MOVE),
      state = function(e) return try(e, "get_MoveState") end },
    { type = "app.Gm032_002", move = enum_value("app.Gm032_002.MOVE_STATE", "MOVE", nil),
      state = function(e) return field(e, "_MoveState") end },
}
local elevator_y, elevator_logged = {}, {}
for _, E in ipairs(ELEVATORS) do
    if E.move ~= nil then
        hook(E.type, "updateMoveState", function(args)
            local st = thread.get_hook_storage()
            st.elev, st.speed = nil, nil
            if not cfg.enabled or (not cfg.elevator_down and not cfg.elevator_up) then return end
            local elev = sdk.to_managed_object(args[2])
            if elev == nil or E.state(elev) ~= E.move then return end
            local addr = elev:get_address()
            local pos = try(try(try(elev, "get_GameObject"), "get_Transform"), "get_Position")
            if pos == nil then return end
            local last = elevator_y[addr]
            elevator_y[addr] = pos.y
            if last == nil then return end
            local up = pos.y > last + 0.0001
            local dir = up and "up" or (pos.y < last - 0.0001) and "down" or "sideways"
            local speed = field(elev, "_MoveSpeed")
            local go = up and cfg.elevator_up or (not up and cfg.elevator_down)
            if elevator_logged[addr] ~= dir then
                elevator_logged[addr] = dir
                info(string.format("%s %x moving %s, _MoveSpeed=%s, %s", E.type, addr, dir, tostring(speed), go and "accelerating" or "left alone"))
            end
            if not go or speed == nil then return end
            st.elev, st.speed = elev, speed
            set(elev, "_MoveSpeed", speed * speed_for("elevator"))
            if stats.last ~= LABEL.elevator then stats.started, stats.last = stats.started + 1, LABEL.elevator end
        end, function(retval)
            local st = thread.get_hook_storage()
            if st.elev ~= nil then set(st.elev, "_MoveSpeed", st.speed) end
            return retval
        end)
    else
        info("no MOVE state on " .. E.type .. " (game build changed?); that lift is left alone")
    end
end

-- Fixed-rate movers (ladder fast slide, narrow-gap pass): measure how far the game moved
-- Musashi since last frame and add (mult - 1) times it, so the move keeps pace with the
-- clip while the game's own reach / exit checks still run on the real position.
local function boost_move()
    if active == nil or active.boost == nil then boost_prev = nil; return end
    local tf = try(player_go, "get_Transform")
    local pos = try(tf, "get_Position")
    if pos == nil then return end
    if boost_prev ~= nil then
        local k = speed_for(active.kind) - 1
        local dx, dy, dz = pos.x - boost_prev.x, pos.y - boost_prev.y, pos.z - boost_prev.z
        local moved = false
        if active.boost == "y" then
            if dy < 0 and dy > -0.5 then pos.y = pos.y + dy * k; moved = true end
        else
            local d = math.sqrt(dx * dx + dz * dz)
            if d > 0.0005 and d < 0.5 then pos.x, pos.z = pos.x + dx * k, pos.z + dz * k; moved = true end
        end
        if moved then pcall(tf.call, tf, "set_Position", pos) end
    end
    boost_prev = { x = pos.x, y = pos.y, z = pos.z }
end

local function boost_adjust()
    if adjust == nil then return end
    local t = try(adjust.timer, "get_Timer")
    if t == nil or try(adjust.timer, "get_IsTimeOut") then adjust = nil; return end
    if adjust.last ~= nil and t > adjust.last then
        local nt = t + (t - adjust.last) * (speed_for(adjust.kind) - 1)
        local limit = try(adjust.timer, "get_Limit") or 0
        if limit > 0 and nt > limit then nt = limit end
        try(adjust.timer, "set_Timer", nt)
        t = nt
    end
    adjust.last = t
end

re.on_pre_application_entry("UpdateMotion", function()
    if adjust ~= nil then
        if cfg.enabled then pcall(boost_adjust) else adjust = nil end
    end
    if active == nil and tail == nil then return end
    if not cfg.enabled then restore_active(); restore_tail(); return end
    if active ~= nil then
        -- Safety net: if doExit was missed, drop the acceleration once the action is no longer current.
        local _, chara = player_objects()
        if chara ~= nil then
            local base, sub = try(chara, "get_BaseCurrentAction"), try(chara, "get_SubCurrentAction")
            local ba = base and base:get_address() or 0
            local sa = sub and sub:get_address() or 0
            if ba ~= active.addr and sa ~= active.addr then restore_active() end
        end
    end
    if active ~= nil then pcall(apply_active); pcall(boost_move) end
    if tail ~= nil then
        if gimmick_opening(tail.gm, tail.kind) then
            scale_layers(gimmick_motion(tail.gm), speed_for(tail.kind), tail.layers)
        else
            restore_tail()
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(MOD) then return end
    imgui.text(MOD .. " " .. VERSION)
    local changed, v
    changed, v = imgui.checkbox("Enabled", cfg.enabled)
    if changed then cfg.enabled = v; save_cfg() end
    changed, v = imgui.slider_float("Speed", cfg.speed, 1.0, 10.0, "%.1fx")
    if changed then cfg.speed = v; save_cfg() end
    for _, k in ipairs({ "oni_wall", "door", "chest", "ladder", "crawl", "gap" }) do
        changed, v = imgui.checkbox(LABEL[k], cfg[k])
        if changed then cfg[k] = v; save_cfg() end
    end
    changed, v = imgui.checkbox("Elevators going down or sideways", cfg.elevator_down)
    if changed then cfg.elevator_down = v; save_cfg() end
    changed, v = imgui.checkbox("Elevators going up", cfg.elevator_up)
    if changed then cfg.elevator_up = v; save_cfg() end
    if imgui.tree_node("Advanced: speed per type (0 = use Speed)") then
        for _, k in ipairs(KINDS) do
            changed, v = imgui.slider_float(LABEL[k], cfg["speed_" .. k], 0.0, 10.0, "%.1fx")
            if changed then cfg["speed_" .. k] = v; save_cfg() end
        end
        imgui.tree_pop()
    end
    imgui.text("Accelerated so far: " .. stats.started .. "   last: " .. stats.last
        .. (active and ("   active: " .. LABEL[active.kind]) or ""))
    imgui.tree_pop()
end)

re.on_script_reset(function() restore_active(); restore_tail(); elevator_y = {}; elevator_logged = {}; adjust = nil end)

info("loaded " .. VERSION)
