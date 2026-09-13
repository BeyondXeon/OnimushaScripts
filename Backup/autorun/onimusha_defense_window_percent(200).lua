-- Onimusha: Way of the Sword Demo - Timing Window Percent
-- Exact 1-200% controls. 100% is the original game timing window.
-- Above 100% loosens (extends) the timing window; below 100% tightens it.

local MOD_NAME = "OnimushaTimingWindowPercent"
local VERSION = "1.2.0-test"
local CONFIG_PATH = "reframework/data/onimusha_issen_window_percent.json"
local MIN_PERCENT = 1
local MAX_PERCENT = 200

local TARGETS = {
    {
        id = "issen",
        label = "Issen",
        description = "Counter Issen judgment window",
    },
    {
        id = "parry_deflect",
        label = "Parry / Deflect",
        description = "Shared Just Guard judgment window",
    },
    {
        id = "reflex_dodge",
        label = "Reflex Dodge",
        description = "Just Dodge judgment window",
    },
    {
        id = "counter_grab",
        label = "Counter Grab",
        description = "Counter Grab judgment window",
    },
    {
        id = "chain_issen",
        label = "Chain Issen",
        description = "Early and late follow-up input windows",
    },
}

local HOOKS = {
    {
        id = "issen",
        target = "issen",
        type_name = "app.cPlayerJustFrameUpdater",
        method_name = "getCounterIssenFrame",
        label = "Issen",
    },
    {
        id = "parry_deflect",
        target = "parry_deflect",
        type_name = "app.cPlayerJustFrameUpdater",
        method_name = "getJustGuardFrame",
        label = "Parry / Deflect",
    },
    {
        id = "reflex_dodge",
        target = "reflex_dodge",
        type_name = "app.cPlayerJustFrameUpdater",
        method_name = "getJustDodgeFrame",
        label = "Reflex Dodge",
    },
    {
        id = "counter_grab",
        target = "counter_grab",
        type_name = "app.cPlayerJustFrameUpdater",
        method_name = "getCounterGrabFrame",
        label = "Counter Grab",
    },
    {
        id = "chain_issen_before",
        target = "chain_issen",
        type_name = "app.user_data.ChainIssenParam.HitFrameSetting",
        method_name = "getInputBeforeHitFrame",
        label = "Chain Issen - Before",
    },
    {
        id = "chain_issen_after",
        target = "chain_issen",
        type_name = "app.user_data.ChainIssenParam.HitFrameSetting",
        method_name = "getInputAfterHitFrame",
        label = "Chain Issen - After",
    },
}

local DEFAULT_PERCENTAGES = {
    issen = 100,
    parry_deflect = 100,
    reflex_dodge = 100,
    counter_grab = 100,
    chain_issen = 100,
}

local state = {
    enabled = true,
    percentages = {},
    pending = {},
    pending_changed = false,
    hook_flags = {},
    hook_status = {},
    installed_hooks = 0,
    observed_frames = {},
    capture_requested = false,
    capture_deadline_time = 0,
    frame = 0,
    status = "Waiting for hooks",
    last_error = "",
}

local function info(message)
    log.info("[" .. MOD_NAME .. "] " .. tostring(message))
end

local function warn(message)
    state.last_error = tostring(message)
    log.warn("[" .. MOD_NAME .. "] " .. tostring(message))
end

local function clamp_percent(value)
    if type(value) ~= "number" or value ~= value then
        return 100
    end
    return math.max(MIN_PERCENT, math.min(MAX_PERCENT, math.floor(value + 0.5)))
end

local function copy_percentages(source)
    local result = {}
    for key, default in pairs(DEFAULT_PERCENTAGES) do
        result[key] = clamp_percent(type(source) == "table" and source[key] or default)
    end
    return result
end

local function save_config()
    if json == nil or json.dump_file == nil then
        return
    end
    local ok, err = pcall(function()
        json.dump_file(CONFIG_PATH, {
            version = 1,
            enabled = state.enabled,
            percentages = state.percentages,
        })
    end)
    if not ok then
        warn("Could not save config: " .. tostring(err))
    end
end

local function load_config()
    local loaded = nil
    if json ~= nil and json.load_file ~= nil then
        pcall(function()
            loaded = json.load_file(CONFIG_PATH)
        end)
    end

    if type(loaded) == "table" and type(loaded.enabled) == "boolean" then
        state.enabled = loaded.enabled
    end
    state.percentages = copy_percentages(type(loaded) == "table" and loaded.percentages or nil)
    state.pending = copy_percentages(state.percentages)
    save_config()
end

local function find_method(type_name, method_name)
    local type_def = sdk.find_type_definition(type_name)
    if type_def == nil then
        return nil
    end

    local ok, method = pcall(function()
        return type_def:get_method(method_name)
    end)
    if ok and method ~= nil then
        return method
    end

    local methods_ok, methods = pcall(function()
        return type_def:get_methods()
    end)
    if not methods_ok or methods == nil then
        return nil
    end
    for _, candidate in ipairs(methods) do
        if tostring(candidate:get_name()) == method_name then
            return candidate
        end
    end
    return nil
end

local function install_hook(hook)
    if state.hook_flags[hook.id] then
        return true
    end

    local method = find_method(hook.type_name, hook.method_name)
    if method == nil then
        state.hook_status[hook.id] = "Waiting"
        return false
    end

    local ok, err = pcall(function()
        sdk.hook(method, function()
        end, function(retval)
            local percent = state.percentages[hook.target] or 100
            local should_scale = state.enabled and percent ~= 100
            local should_capture = state.capture_requested
                and state.observed_frames[hook.id] == nil

            -- True fast path: do no float conversion when neither scaling nor
            -- a user-requested one-shot observation is needed.
            if not should_scale and not should_capture then
                return retval
            end

            local original = sdk.to_float(retval)
            if type(original) ~= "number" or original ~= original or original < 0.0 then
                return retval
            end

            if should_capture then
                state.observed_frames[hook.id] = original
            end

            if should_scale then
                return sdk.float_to_ptr(original * percent / 100.0)
            end
            return retval
        end)
    end)

    if not ok then
        state.hook_status[hook.id] = "Failed"
        warn(hook.label .. " hook failed: " .. tostring(err))
        return false
    end

    state.hook_flags[hook.id] = true
    state.hook_status[hook.id] = "Installed"
    state.installed_hooks = state.installed_hooks + 1
    return true
end

local function start_frame_capture()
    state.observed_frames = {}
    state.capture_requested = true
    state.capture_deadline_time = os.time() + 30
    state.status = "Capturing vanilla frame values - perform each action once"
end

local function update_capture_status()
    if not state.capture_requested then
        return
    end

    if os.time() >= state.capture_deadline_time then
        state.capture_requested = false
        state.status = "Frame capture stopped after 30 seconds (partial results kept)"
        return
    end

    for _, hook in ipairs(HOOKS) do
        if state.observed_frames[hook.id] == nil then
            return
        end
    end

    state.capture_requested = false
    state.status = "Captured all vanilla frame values"
    info(state.status)
end

local function frame_text(value)
    if type(value) ~= "number" then
        return "waiting"
    end
    return string.format("%.2f F / %.1f ms at 60 FPS", value, value * 1000.0 / 60.0)
end

local function install_pending_hooks()
    if sdk.to_float == nil or sdk.float_to_ptr == nil then
        state.status = "Float conversion API unavailable"
        return
    end
    for _, hook in ipairs(HOOKS) do
        install_hook(hook)
    end
    state.status = "Installed " .. tostring(state.installed_hooks) .. "/" .. tostring(#HOOKS) .. " hooks"
    if state.installed_hooks == #HOOKS then
        info(state.status)
    end
end

local function stage_all(percent)
    percent = clamp_percent(percent)
    for key in pairs(DEFAULT_PERCENTAGES) do
        state.pending[key] = percent
    end
    state.pending_changed = true
end

local function apply_pending()
    state.percentages = copy_percentages(state.pending)
    state.pending = copy_percentages(state.percentages)
    state.pending_changed = false
    state.status = "Timing percentages applied"
    save_config()
end

local function draw_percent_control(target)
    local current = state.pending[target.id] or 100
    local changed, value

    if imgui.slider_int ~= nil then
        changed, value = imgui.slider_int(target.label, current, MIN_PERCENT, MAX_PERCENT, "%d%%")
    else
        changed, value = imgui.slider_float(target.label, current + 0.0, MIN_PERCENT + 0.0, MAX_PERCENT + 0.0, "%.0f%%")
    end

    if changed then
        state.pending[target.id] = clamp_percent(value)
        state.pending_changed = true
    end

    if imgui.is_item_hovered ~= nil and imgui.is_item_hovered() then
        imgui.set_tooltip(target.description .. "\n100% = original game window\nLower = stricter timing\nHigher = more lenient timing")
    end
end

local function draw_ui()
    if imgui == nil or not imgui.tree_node("Onimusha Timing Windows (%)") then
        return
    end

    local enabled_changed, enabled = imgui.checkbox("Enabled", state.enabled)
    if enabled_changed then
        state.enabled = enabled
        save_config()
    end

    imgui.text("Choose the exact percentage of the original timing window.")
    imgui.text("100% = vanilla. Lower values make timing stricter, higher values make it more lenient.")
    imgui.text("This changes judgment/input windows, not invincibility frames.")
    imgui.separator()

    for _, target in ipairs(TARGETS) do
        draw_percent_control(target)
    end

    if state.pending_changed then
        imgui.text("Pending changes - press Apply")
    end
    if imgui.button("Apply") then
        apply_pending()
    end
    imgui.same_line()
    if imgui.button("All 100% (Vanilla)") then
        stage_all(100)
    end
    imgui.same_line()
    if imgui.button("All 75%") then
        stage_all(75)
    end
    imgui.same_line()
    if imgui.button("All 50%") then
        stage_all(50)
    end
    imgui.same_line()
    if imgui.button("All 25%") then
        stage_all(25)
    end
    imgui.same_line()
    if imgui.button("All 150%") then
        stage_all(150)
    end
    imgui.same_line()
    if imgui.button("All 200%") then
        stage_all(200)
    end

    imgui.separator()
    imgui.text("Timing measurement")
    imgui.text("Capture reads each game's unmodified getter once; it does not scan every frame.")
    if imgui.button("Capture vanilla frame values") then
        start_frame_capture()
    end
    if state.capture_requested then
        imgui.text("Capture armed: parry, dodge, Issen/grab and Chain Issen once.")
        if imgui.button("Stop frame capture") then
            state.capture_requested = false
            state.status = "Frame capture stopped (partial results kept)"
        end
    end

    for _, hook in ipairs(HOOKS) do
        local vanilla = state.observed_frames[hook.id]
        local percent = state.percentages[hook.target] or 100
        local effective = type(vanilla) == "number" and vanilla * percent / 100.0 or nil
        imgui.text(hook.label .. ": vanilla " .. frame_text(vanilla)
            .. " | effective " .. frame_text(effective))
    end

    if imgui.tree_node("Runtime status") then
        imgui.text("Status: " .. tostring(state.status))
        imgui.text("Hooks: " .. tostring(state.installed_hooks) .. "/" .. tostring(#HOOKS))
        imgui.text("Last error: " .. tostring(state.last_error))
        for _, hook in ipairs(HOOKS) do
            imgui.text(hook.label .. ": " .. tostring(state.hook_status[hook.id] or "Pending"))
        end
        imgui.tree_pop()
    end

    imgui.text("Version: " .. VERSION)
    imgui.text("Do not load the original timing-window script simultaneously.")
    imgui.tree_pop()
end

for _, hook in ipairs(HOOKS) do
    state.hook_status[hook.id] = "Pending"
end
load_config()

re.on_frame(function()
    state.frame = state.frame + 1
    update_capture_status()
    if state.installed_hooks == #HOOKS then
        return
    end
    if state.frame == 1 or state.frame % 120 == 0 then
        install_pending_hooks()
    end
end)

re.on_draw_ui(function()
    local ok, err = pcall(draw_ui)
    if not ok then
        warn("UI error: " .. tostring(err))
    end
end)

info("Loaded v" .. VERSION .. ". Exact timing controls are available in Script Generated UI.")
