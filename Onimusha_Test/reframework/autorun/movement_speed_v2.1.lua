-- MoveSpeed v2.1 -- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- v2.1: override alone proved too weak (x3 showed 2.79 m/s travel), so this
-- is the FULL shipped combo from FasterInteractions: per-action override
-- fields PLUS player layer scaling, re-applied every frame while active.
-- Plus readback: the menu/proof now show the ACTUAL field values on the
-- active action, so silent write failures can't hide anymore.
--
-- Menu: REFramework -> ScriptRunner -> "MoveSpeed v2.0".
-- Config: reframework/data/movement_speed.json (same {mov} as v1.x).

local MOD, VERSION, CFG_FILE = "MoveSpeed", "2.1", "movement_speed.json"
local PROOF_FILE = "mov_proof.json"
local TAG = "[" .. MOD .. "] "

local cfg = { mov = 1.0 }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.mov) == "number" then cfg.mov = math.max(1.0, math.min(3.0, saved.mov)) end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end
local function L(msg) log.info(TAG .. tostring(msg)) end

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
local function is_a(td, name)
    local ok, r = pcall(td.is_a, td, name)
    return ok and r == true
end

local LOCO_KEYS = { "Run", "Walk", "Dash", "Sprint", "Move", "Turn", "Strafe", "Jog" }

local function short_name(full)
    if type(full) ~= "string" then return "?" end
    return full:match("([^.]+)$") or full
end

-- Locomotion only. Attacks (AtkSpeed), interactions (FasterInteractions),
-- climbs/crawls/gaps (FasterInteractions) and everything else: hands off.
local function classify(action)
    local ok, td = pcall(action.get_type_definition, action)
    if not ok or td == nil then return nil end
    local full = nil
    pcall(function() full = td:get_full_name() end)
    if type(full) ~= "string" then return nil end
    local n = short_name(full)
    if n:find("Attack", 1, true) then return nil end
    if full:find("DemonTendon", 1, true) then return nil end
    if is_a(td, "app.PlayerCommonAction.cLadderActionBase") then return nil end
    if is_a(td, "app.PlayerCommonAction.cCreepBase") then return nil end
    if is_a(td, "app.PlayerCommonAction.cGoThroughBase") then return nil end
    if is_a(td, "app.PlayerCommonAction.cInteractGimmickBase") then return nil end
    for _, k in ipairs(LOCO_KEYS) do
        if n:find(k, 1, true) then return "move", n end
    end
    return nil
end

-- The one locomotion action currently overridden.
local active = nil -- { action, addr, name, orig_use, orig_speed }
local stats = { started = 0, last = "-" }
local rb_use, rb_speed, layers_n = nil, nil, 0 -- v2.1 readback + layer count
local MAX_LAYERS = 64

-- Player motion component, cached by GameObject address.
local player_go, player_motion = nil, nil
local function get_motion()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = try(pm, "getControllingPlayer")
    local go = try(mi, "get_Object")
    if go == nil then player_go, player_motion = nil, nil return nil end
    if player_go == nil or go:get_address() ~= player_go:get_address() then
        player_go = go
        player_motion = try(go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    end
    return player_motion
end

-- v2.1: layer scaling WITH remembered originals (same pattern as the
-- shipped interaction mod). Re-applied every frame while active.
local layer_orig = {}
local function scale_layers(mult)
    local motion = get_motion()
    if motion == nil then layers_n = 0 return end
    local n = 0
    for _, pair in ipairs({ { "getLayerCount", "getLayer" }, { "getPrivateLayerCount", "getPrivateLayer" } }) do
        local count = try(motion, pair[1]) or 0
        if count > MAX_LAYERS then count = MAX_LAYERS end
        for i = 0, count - 1 do
            local layer = try(motion, pair[2], i)
            if layer ~= nil then
                n = n + 1
                local addr = layer:get_address()
                local orig = layer_orig[addr]
                if orig == nil then
                    orig = try(layer, "get_Speed")
                    if orig ~= nil then layer_orig[addr] = orig end
                end
                if orig ~= nil and orig > 0 then try(layer, "set_Speed", orig * mult) end
            end
        end
    end
    layers_n = n
end
local function restore_layers()
    for addr, orig in pairs(layer_orig) do
        local motion = get_motion()
        if motion ~= nil then
            for _, pair in ipairs({ { "getLayerCount", "getLayer" }, { "getPrivateLayerCount", "getPrivateLayer" } }) do
                local count = try(motion, pair[1]) or 0
                if count > MAX_LAYERS then count = MAX_LAYERS end
                for i = 0, count - 1 do
                    local layer = try(motion, pair[2], i)
                    if layer ~= nil and layer:get_address() == addr then
                        pcall(function() layer:call("set_Speed", orig) end)
                    end
                end
            end
        end
        layer_orig[addr] = nil
    end
    layers_n = 0
end

local function restore_active()
    if active == nil then return end
    local a = active
    active = nil
    restore_layers()
    pcall(function()
        a.action:set_field("_UseOverrideMotionSpeed", a.orig_use)
        a.action:set_field("_OverrideMotionSpeed", a.orig_speed)
    end)
end

local function begin(action)
    local kind, name = classify(action)
    if kind == nil then return end
    local ok_addr, addr = pcall(function() return action:get_address() end)
    if not ok_addr or addr == nil then return end
    if active ~= nil and active.addr == addr then return end
    restore_active()
    active = { action = action, addr = addr, name = name }
    active.orig_use = field(action, "_UseOverrideMotionSpeed")
    active.orig_speed = field(action, "_OverrideMotionSpeed")
    stats.started, stats.last = stats.started + 1, name
end

local function apply_active()
    if active == nil then return end
    if cfg.mov == nil or cfg.mov <= 1.0 then return end
    set(active.action, "_UseOverrideMotionSpeed", true)
    set(active.action, "_OverrideMotionSpeed", cfg.mov)
    -- v2.1 readback: prove the fields actually hold what we wrote.
    rb_use = field(active.action, "_UseOverrideMotionSpeed")
    rb_speed = field(active.action, "_OverrideMotionSpeed")
    scale_layers(cfg.mov)
end

do
    local td = sdk.find_type_definition("app.PlayerActionBase.cPlayerActionBase")
    local m_enter = td and td:get_method("doEnter") or nil
    local m_exit = td and td:get_method("doExit") or nil
    if m_enter ~= nil then
        pcall(sdk.hook, m_enter, function(args)
            if cfg.mov == nil or cfg.mov <= 1.0 then return end
            local action = sdk.to_managed_object(args[2])
            if action == nil then return end
            -- own player only: match the controlling player's character entity
            local pm = sdk.get_managed_singleton("app.PlayerManager")
            local mi = try(pm, "getControllingPlayer")
            local ent = try(mi, "get_CharacterEntity")
            local aent = try(action, "get_CharacterEntity")
            if ent == nil or aent == nil then return end
            local ok1, e1 = pcall(function() return ent:get_address() end)
            local ok2, e2 = pcall(function() return aent:get_address() end)
            if not ok1 or not ok2 or e1 ~= e2 then return end
            pcall(begin, action)
            pcall(apply_active)
        end, function(retval)
            if cfg.mov ~= nil and cfg.mov > 1.0 then pcall(apply_active) end
            return retval
        end)
        L("doEnter hooked")
    else
        L("doEnter NOT FOUND")
    end
    if m_exit ~= nil then
        pcall(sdk.hook, m_exit, function(args)
            if active ~= nil and args[2] ~= nil and sdk.to_int64(args[2]) == active.addr then
                pcall(restore_active)
            end
        end)
    end
end

-- Travel meter + safety net + proof (no speed logic here anymore).
local tick = 0
local meter_last, meter_t, mov_speed = nil, 0, 0
local function player_go()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local mi = try(pm, "getControllingPlayer")
    return try(mi, "get_Object"), try(mi, "get_Character")
end
local function write_proof()
    pcall(json.dump_file, PROOF_FILE, {
        version = VERSION, tick = tick, cfg = { mov = cfg.mov },
        active = active ~= nil and active.name or "-",
        started = stats.started, last = stats.last,
        mov_speed = mov_speed,
        rb_use = rb_use, rb_speed = rb_speed, layers_n = layers_n,
    })
end

re.on_pre_application_entry("UpdateMotion", function()
    tick = tick + 1
    if tick % 600 == 0 then write_proof() end
    local go, chara = player_go()
    if active ~= nil then
        -- Safety net: action changed without doExit -> restore.
        if chara ~= nil then
            local base = try(chara, "get_BaseCurrentAction")
            local sub = try(chara, "get_SubCurrentAction")
            local ba = base and base:get_address() or 0
            local sa = sub and sub:get_address() or 0
            if ba ~= active.addr and sa ~= active.addr then restore_active() end
        end
    end
    if active ~= nil then
        if cfg.mov == nil or cfg.mov <= 1.0 then
            restore_active() -- slider off mid-action: give everything back
        else
            pcall(apply_active)
        end
        -- measure travel while overridden
        local tf = try(go, "get_Transform")
        local pos = tf and try(tf, "get_Position") or nil
        local now = os.clock()
        if pos ~= nil and meter_last ~= nil then
            local dx, dz = pos.x - meter_last.x, pos.z - meter_last.z
            local dist = math.sqrt(dx * dx + dz * dz)
            local dt = now - meter_t
            if dt > 0 and dt < 1.0 and dist < 5.0 then
                mov_speed = math.floor(dist / dt * 100) / 100
            end
        end
        if pos ~= nil then meter_last, meter_t = { x = pos.x, z = pos.z }, now
        else meter_last = nil end
    else
        meter_last = nil
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
    local on = cfg.mov ~= nil and cfg.mov > 1.0
    imgui.text_colored(on and string.format("ACTIVE: MOV x%.1f", cfg.mov) or "OFF",
        on and 0xFF40FF40 or 0xFF808080)
    local changed, v = imgui.slider_float("Movement Speed", cfg.mov, 1.0, 3.0, "x%.1f")
    if changed then cfg.mov = v save() end
    imgui.text("Overridden so far: " .. stats.started .. "   last: " .. stats.last
        .. (active and ("   active: " .. active.name) or ""))
    imgui.text(string.format("Travel: %.2f m/s", mov_speed))
    imgui.text("Field readback: use=" .. tostring(rb_use) .. " speed=" .. tostring(rb_speed)
        .. " layers=" .. tostring(layers_n))
    imgui.tree_pop()
end)

re.on_script_reset(function()
    write_proof()
    restore_active()
    meter_last = nil
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
