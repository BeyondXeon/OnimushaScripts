-- FOV Slider v1.2 -- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- v1.2: the fight persisted, so the per-frame writer is not Camera.set_FOV.
-- Three changes: (1) hook via.render.Renderer.set_Fov as well - the visible
-- projection may be driven there; (2) both hooks rewrite ONLY writes near
-- the captured game default, so aim zoom and cinematics (which write very
-- different values) pass through untouched; (3) the fallback write moved to
-- right-before-render every frame, so it always lands last.
--
-- Menu: REFramework -> ScriptRunner -> "FOVSlider v1.2".
-- Config: reframework/data/fov_slider.json (stable across versions).

local MOD, VERSION, CFG_FILE = "FOVSlider", "1.2", "fov_slider.json"
local TAG = "[" .. MOD .. "] "
local FOV_MIN, FOV_MAX = 30.0, 120.0

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { fov = 0.0, enabled = true } -- fov 0 = not set yet
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.fov) == "number" then
            cfg.fov = math.max(FOV_MIN, math.min(FOV_MAX, saved.fov))
        end
        if type(saved.enabled) == "boolean" then cfg.enabled = saved.enabled end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end

local camera, cam_addr, default_fov, fails = nil, 0, 0.0, 0

local function resolve_camera()
    if camera ~= nil then
        local ok, a = pcall(function() return camera:get_address() end)
        if ok and a ~= 0 then return camera end
        camera, cam_addr = nil, 0
    end
    pcall(function() camera = sdk.get_primary_camera() end)
    if camera == nil then return nil end
    local ok, a = pcall(function() return camera:get_address() end)
    if not ok or a == 0 then camera = nil return nil end
    cam_addr = a
    return camera
end

local function read_fov()
    local cam = resolve_camera()
    if cam == nil then return nil end
    local ok, v = pcall(cam.call, cam, "get_FOV")
    if ok and type(v) == "number" then
        fails = 0
        if default_fov == 0.0 then
            default_fov = v
            if cfg.fov == 0.0 then cfg.fov = v save() end
            L(string.format("default FOV captured: %.1f", v))
        end
        return v
    end
    fails = fails + 1
    if fails > 10 then camera = nil fails = 0 end
    return nil
end

local function write_fov(v)
    local cam = resolve_camera()
    if cam == nil then return false end
    return pcall(cam.call, cam, "set_FOV", v)
end

-- v1.2: rewrite the game's own FOV writes to the slider value, but ONLY
-- writes near the captured game default (the fight-back value). Aim zoom,
-- cinematics and photo mode write very different values and pass through.
-- Primary camera only for the Camera hook; the Renderer is global.
local fov_hooks_ok = 0
local function install_fov_hook(td_name, mname, need_cam_match)
    local ok_td, td = pcall(sdk.find_type_definition, td_name)
    if not ok_td or td == nil then return end
    local ok_m, m = pcall(td.get_method, td, mname)
    if not ok_m or m == nil then return end
    local attached = pcall(sdk.hook, m, function(args)
        pcall(function()
            if not cfg.enabled or cfg.fov <= 0.0 then return end
            if default_fov <= 0.0 then return end
            if math.abs(cfg.fov - default_fov) <= 0.05 then return end
            if need_cam_match then
                if cam_addr == 0 then return end
                local okaddr, this_addr = pcall(sdk.to_int64, args[2])
                if not okaddr or this_addr ~= cam_addr then return end
            end
            local oka, cur = pcall(sdk.to_float, args[3])
            if oka and type(cur) == "number"
                and math.abs(cur - default_fov) < 2.0
                and math.abs(cur - cfg.fov) > 0.01 then
                args[3] = sdk.float_to_ptr(cfg.fov)
            end
        end)
        return sdk.PreHookResult.CALL_ORIGINAL
    end, nil)
    if attached then
        fov_hooks_ok = fov_hooks_ok + 1
        L(td_name .. "." .. mname .. " hook ATTACHED")
    end
end

install_fov_hook("via.Camera", "set_FOV", true)
install_fov_hook("via.render.Renderer", "set_Fov", false)

local tick = 0
re.on_frame(function()
    tick = tick + 1
    if tick % 60 == 0 then resolve_camera() end -- keep the hook gate fresh
    if not cfg.enabled then return end
    if cfg.fov <= 0.0 and tick % 60 == 0 then read_fov() end -- capture default
end)

-- v1.2 fallback: write right before render, every frame, so it lands after
-- any native direct writes the hooks cannot see.
re.on_pre_application_entry("BeginRendering", function()
    if not cfg.enabled or cfg.fov <= 0.0 then return end
    if default_fov > 0.0 and math.abs(cfg.fov - default_fov) <= 0.05 then return end
    local cur = read_fov()
    if cur ~= nil and math.abs(cur - cfg.fov) > 0.05 then
        write_fov(cfg.fov)
    end
end)

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        local active = cfg.enabled and cfg.fov > 0.0 and default_fov > 0.0
            and math.abs(cfg.fov - default_fov) > 0.05
        imgui.text_colored(active and string.format("ACTIVE: FOV %.0f", cfg.fov) or "ACTIVE: OFF",
            active and 0xFF40FF40 or 0xFF808080)
        local chen, ven = imgui.checkbox("Enabled", cfg.enabled)
        if chen then
            cfg.enabled = ven
            save()
            if not ven and default_fov > 0.0 then write_fov(default_fov) end
            L("enabled=" .. tostring(ven))
        end
        if default_fov > 0.0 then
            imgui.text(string.format("Game default: %.0f", default_fov))
        else
            imgui.text("Game default: -- (enter gameplay)")
        end
        local chv, vv = imgui.slider_float("Field of View", cfg.fov > 0.0 and cfg.fov or (default_fov > 0.0 and default_fov or 70.0), FOV_MIN, FOV_MAX, "%.0f")
        if chv then
            cfg.fov = vv
            save()
            write_fov(vv)
        end
        if imgui.button("Reset to default") and default_fov > 0.0 then
            cfg.fov = default_fov
            save()
            write_fov(default_fov)
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    camera, cam_addr, fails = nil, 0, 0
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION)
