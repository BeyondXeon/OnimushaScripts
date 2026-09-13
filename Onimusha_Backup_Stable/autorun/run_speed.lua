-- Run Speed  -- 1.4.0
-- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- Multiplies the player's locomotion animation speed while the base motion
-- layer plays a Walk, Run or Dash clip from any of the player's move-set banks
-- (sheathed plc_BaseMove, weapon-drawn plw_KatateMove / plw_RyoteMove, the
-- lock-on strafe sets), and on the loop clips also scales the entity's root
-- translation rate, because the game normalises loop root motion back to its
-- designed speed (layer speed alone only makes the animation faster).
-- Each tier (walk / run / dash) has its own multiplier; 1.0 leaves it untouched.
-- Attacks, dodges, climbing and everything else are left alone.
-- Menu: REFramework -> ScriptRunner -> "RunSpeed". Config: reframework/data/run_speed.json.

local MOD = "RunSpeed"
local VERSION = "1.4.0"
local CFG_FILE = "run_speed.json"
local DEFAULT_MULT = 1.5        -- build.ps1 stamps 2.0 / 2.5 into the other downloads
local LAYER = 0                 -- ponytail: base layer only; add sub-layers if arms desync at high multipliers
local NO_MOTION = 4294967295
-- Player move-set enums. SetID = BankID * 4096 + motion id, so the bank comes from the value.
local MOVE_ENUMS = {
    "app.plc_BaseMove_Mot.SetID",   -- 10000 sheathed (dungeons, most of the game)
    "app.plw_KatateMove_Mot.SetID", -- 20000 one-handed weapon drawn (Kyoto open world)
    "app.plw_RyoteMove_Mot.SetID",  -- 20001 two-handed weapon drawn, lock-on strafe
    "app.plw_tree_Mot.SetID",       -- 20050 strafe walk/jog/dash loops
    "app.plw_SubWeapon_Mot.SetID",  -- 20033 sub-weapon strafe
}

local cfg = { enabled = true, mult_walk = 1.0, mult_run = DEFAULT_MULT, mult_dash = DEFAULT_MULT, loops_only = true, log_nodes = false }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do cfg[k] = v end
        -- 1.3.x config: one multiplier plus per-tier on/off checkboxes.
        if saved.multiplier ~= nil and saved.mult_dash == nil then
            cfg.mult_walk = saved.scale_walk and saved.multiplier or 1.0
            cfg.mult_run = saved.scale_run ~= false and saved.multiplier or 1.0
            cfg.mult_dash = saved.scale_dash ~= false and saved.multiplier or 1.0
            cfg.multiplier, cfg.scale_walk, cfg.scale_run, cfg.scale_dash = nil, nil, nil, nil
            pcall(json.dump_file, CFG_FILE, cfg)
        end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end

local function info(msg) log.info("[" .. MOD .. "] " .. tostring(msg)) end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end

local function mult_for(t)
    if t == "dash" then return cfg.mult_dash end
    if t == "run" then return cfg.mult_run end
    if t == "walk" then return cfg.mult_walk end
    return 1.0
end

local speed_text = "-"
-- Reused per frame; rebuilt only when a multiplier changes.
local ONE_VEC = Vector3f.new(1.0, 1.0, 1.0)
local rate_vecs = {}
local function set_rate_vecs()
    for _, t in ipairs({ "walk", "run", "dash" }) do
        local m = mult_for(t)
        rate_vecs[t] = Vector3f.new(m, m, m)
    end
end
set_rate_vecs()
-- With the script disabled and the REFramework menu closed there is nothing to do per frame.
local ui_open = function() return true end
if pcall(function() return reframework:is_drawing_ui() end) then
    ui_open = function() return reframework:is_drawing_ui() end
end
local diag = 0
local function diag_log(msg)
    if diag < 1200 then diag = diag + 1; info(msg) end
end

local function try_call(obj, name, ...)
    if obj == nil or obj:get_address() == 0 then return nil end
    local ok, r = pcall(obj.call, obj, name, ...)
    if ok then return r end
    return nil
end

-- mot_names[bank][id] -> clip name, from the game's generated enums.
local mot_names = {}
local function clip_name(bank, id)
    local t = mot_names[bank]
    return t and t[id] or nil
end
do
    local n = 0
    for _, tname in ipairs(MOVE_ENUMS) do
        local td = sdk.find_type_definition(tname)
        if td ~= nil then
            for _, f in ipairs(td:get_fields()) do
                local name = f:get_name()
                if name ~= "value__" then
                    local ok, v = pcall(f.get_data, f, nil)
                    if ok and type(v) == "number" then
                        local bank = math.floor(v / 4096)
                        mot_names[bank] = mot_names[bank] or {}
                        mot_names[bank][v % 4096] = name
                        n = n + 1
                    end
                end
            end
        else
            info("enum not found: " .. tname)
        end
    end
    info("clip names loaded: " .. n)
end

-- Clips that contain Run/Dash/Walk but are not ground locomotion.
local EXCLUDE = { "StepJump", "GenericFalling", "Falling", "NPC_", "Over_The_Fence", "Ladder", "Ledge", "Jump",
    "WallRun", "Guard", "Issen", "Bow", "QuickShot", "Tired" }

local function tier_of(name)
    if name == nil then return nil end
    for _, s in ipairs(EXCLUDE) do
        if string.find(name, s, 1, true) then return nil end
    end
    -- Start, Stop, Turn and X_to_Y transitions get twitchy at high multipliers; loops carry the travel speed.
    -- "Loop" without the underscore so the strafe sets (JogLoop_FR, DashLoop_BL) count too.
    if cfg.loops_only and not string.find(name, "Loop", 1, true) then return nil end
    if string.find(name, "Dash", 1, true) then return "dash" end
    if string.find(name, "Run", 1, true) then return "run" end
    if string.find(name, "Walk", 1, true) or string.find(name, "Jog", 1, true) then return "walk" end
    return nil
end

-- Player lookup: cached, re-resolved when it goes stale.
local motion = nil
local transform = nil
local entity = nil
local player_go = nil
local recheck = 0
local resolve_cooldown = 0

local function resolve_player()
    if resolve_cooldown > 0 then resolve_cooldown = resolve_cooldown - 1; return false end
    resolve_cooldown = 60
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = pm and try_call(pm, "getControllingPlayer") or nil
    local go = mi and try_call(mi, "get_Object") or nil
    if go == nil then return false end
    local m = try_call(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if m == nil then return false end
    motion = m
    transform = try_call(go, "get_Transform")
    entity = try_call(mi, "get_CharacterEntity")
    player_go = go
    info("player=" .. tostring(try_call(go, "get_Name")) .. " layers=" .. tostring(try_call(m, "getLayerCount")))
    return true
end

local last_bank, last_motid = nil, nil
local tier = nil          -- classification of the current clip, recomputed only when the clip changes
local is_loop = false
local status_tick = 0
local applied = false
local applied_mult = 1.0  -- the value we last wrote, so undo only removes our own
local rate_applied = false
local rate_mult = 1.0
local current_name = "?"

re.on_pre_application_entry("UpdateMotion", function()
    if not cfg.enabled and not applied and not rate_applied and not cfg.log_nodes and not ui_open() then return end
    -- Area transitions can recreate the player; drop the cache if the controlling object changed.
    recheck = recheck + 1
    if motion ~= nil and recheck >= 15 then
        recheck = 0
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        local mi = pm and try_call(pm, "getControllingPlayer") or nil
        local go = mi and try_call(mi, "get_Object") or nil
        if go ~= nil and (player_go == nil or go:get_address() ~= player_go:get_address()) then
            info("controlling player changed, re-resolving")
            motion, entity, transform = nil, nil, nil
        elseif mi ~= nil then
            -- The entity can be swapped or nulled without the GameObject changing; refresh it.
            entity = try_call(mi, "get_CharacterEntity")
        end
    end
    if motion == nil and not resolve_player() then return end
    local layer = try_call(motion, "getLayer", LAYER)
    if layer == nil then motion, entity, transform = nil, nil, nil; return end

    local motid = try_call(layer, "get_MotionID")
    local bank = try_call(layer, "get_MotionBankID")
    local clip_changed = motid ~= last_motid or bank ~= last_bank
    if clip_changed then
        last_motid, last_bank = motid, bank
        local name = nil
        if motid ~= NO_MOTION then name = clip_name(bank, motid) end
        tier = tier_of(name)
        -- Loop clips: the game divides their root motion by the layer speed, so travel speed
        -- only follows through the root translation rate. Transitions are not normalised and
        -- already move faster with the layer speed, so they must not get the rate as well.
        is_loop = name ~= nil and string.find(name, "Loop", 1, true) ~= nil
        current_name = name or (tostring(bank) .. ":" .. tostring(motid))
    end

    local m = cfg.enabled and mult_for(tier) or 1.0
    if math.abs(m - 1.0) > 0.001 then
        layer:call("set_Speed", m)
        applied, applied_mult = true, m
    elseif applied then
        -- Only undo our own value; leave any game-set speed alone.
        local s = try_call(layer, "get_Speed")
        if s ~= nil and math.abs(s - applied_mult) < 0.001 then layer:call("set_Speed", 1.0) end
        applied = false
    end

    if entity ~= nil then
        if applied and is_loop then
            try_call(entity, "set_ActionRootTransRate", rate_vecs[tier])
            rate_applied, rate_mult = true, m
        elseif rate_applied then
            local r = try_call(entity, "get_ActionRootTransRate")
            if r ~= nil and math.abs(r.x - rate_mult) < 0.001 then
                try_call(entity, "set_ActionRootTransRate", ONE_VEC)
            end
            rate_applied = false
        end
    end

    -- Logged after apply/undo so the values are this frame's, not the previous clip's.
    if cfg.log_nodes then
        if clip_changed then
            diag_log(string.format("motion %s tier=%s applied=%s speed=%s", current_name, tostring(tier), tostring(applied), tostring(try_call(layer, "get_Speed"))))
        end
        status_tick = status_tick + 1
        if status_tick >= 60 then
            status_tick = 0
            local r = entity and try_call(entity, "get_ActionRootTransRate") or nil
            diag_log(string.format("status motion=%s bank=%s id=%s tier=%s applied=%s layer=%s rate=%s entity=%s ground=%s",
                current_name, tostring(bank), tostring(motid), tostring(tier), tostring(applied),
                tostring(try_call(layer, "get_Speed")), r and string.format("%.2f", r.x) or "nil",
                tostring(entity ~= nil), speed_text))
        end
    end
end)

-- Ground speed meter: horizontal m/s over 60-frame windows while a run/dash clip plays.
local meter = { frames = 0, dist = 0, secs = 0, clock = nil, last = nil, tier = nil }
re.on_application_entry("UpdateMotion", function()
    if transform == nil or not (cfg.log_nodes or ui_open()) then return end
    local pos = try_call(transform, "get_Position")
    if pos == nil then return end
    local now = os.clock()
    if meter.last ~= nil and tier ~= nil and tier == meter.tier then
        local dx, dz = pos.x - meter.last.x, pos.z - meter.last.z
        meter.dist = meter.dist + math.sqrt(dx * dx + dz * dz)
        meter.secs = meter.secs + (now - meter.clock)
        meter.frames = meter.frames + 1
        if meter.frames >= 60 and meter.secs > 0 then
            local mps = meter.dist / meter.secs
            speed_text = string.format("%.2f m/s (%s, x%.2f%s)", mps, tier, mult_for(tier), cfg.enabled and "" or " OFF")
            if cfg.log_nodes then diag_log("ground " .. speed_text) end
            meter.frames, meter.dist, meter.secs = 0, 0, 0
        end
    else
        meter.frames, meter.dist, meter.secs = 0, 0, 0
    end
    meter.last, meter.tier, meter.clock = pos, tier, now
end)

re.on_draw_ui(function()
    if imgui.tree_node(MOD) then
        imgui.text("version " .. VERSION)
        local changed
        changed, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
        if changed then save() end
        -- The plain slider drives run and dash together; walk stays as set in Advanced.
        changed, cfg.mult_dash = imgui.slider_float("Multiplier (run + dash)", cfg.mult_dash, 0.5, 3.0, "%.2f")
        if changed then cfg.mult_run = cfg.mult_dash; save(); set_rate_vecs() end
        if imgui.tree_node("Advanced: speed per movement type") then
            imgui.text("Boost over normal speed. 0% leaves that movement untouched.")
            local function pct_slider(label, key)
                local c, p = imgui.slider_float(label, (cfg[key] - 1.0) * 100, -50, 200, "%+.0f%%")
                if c then cfg[key] = 1.0 + p / 100; save(); set_rate_vecs() end
            end
            pct_slider("Walk (partial stick)", "mult_walk")
            pct_slider("Run (first moment at full stick)", "mult_run")
            pct_slider("Dash (sustained running; the game calls it dash)", "mult_dash")
            imgui.tree_pop()
        end
        changed, cfg.loops_only = imgui.checkbox("Loop clips only (normal-speed starts, stops, turns)", cfg.loops_only)
        if changed then save(); last_motid = nil end
        changed, cfg.log_nodes = imgui.checkbox("Log motion changes", cfg.log_nodes)
        if changed then save() end
        imgui.text("motion: " .. tostring(current_name) .. (applied and "  [scaled]" or ""))
        imgui.text("ground: " .. speed_text)
        imgui.tree_pop()
    end
end)

info(string.format("loaded %s walk=%.2f run=%.2f dash=%.2f loops_only=%s", VERSION, cfg.mult_walk, cfg.mult_run, cfg.mult_dash, tostring(cfg.loops_only)))
