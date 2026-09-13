--[[
  onimusha_qol.lua — generated release bundle. Do not edit.

  Build: npm run bundle
  Install as: reframework/autorun/onimusha_qol.lua

  Self-contained: lua/refshell/util.lua, then lua/refshell/config.lua, then lua/refshell/input.lua, then lua/refshell/theme.lua, then lua/refshell/host.lua, then lua/refshell/log.lua, then lua/refshell/ui.lua, then lua/refshell.lua, then reframework/autorun/appearance.lua, then reframework/autorun/give.lua, then reframework/autorun/main.lua.
]]
-- lua/refshell/util.lua
package.preload["refshell.util"] = function(...)
-- Shared table helpers for RefShell.

local util = {}

function util.copy_defaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = v
        elseif type(v) == "table" and type(dst[k]) == "table" and not v[1] then
            util.copy_defaults(dst[k], v)
        end
    end
    return dst
end

function util.deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        error("RefShell.Config: circular table")
    end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        out[util.deep_copy(k, seen)] = util.deep_copy(v, seen)
    end
    seen[value] = nil
    return out
end

function util.deep_equal(a, b)
    if a == b then
        return true
    end
    if type(a) ~= type(b) or type(a) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not util.deep_equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function util.is_json_safe(value)
    local t = type(value)
    if value == nil or t == "boolean" or t == "string" then
        return true
    end
    if t == "number" then
        return value == value and value ~= math.huge and value ~= -math.huge
    end
    if t ~= "table" then
        return false
    end
    for k, v in pairs(value) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
            return false
        end
        if not util.is_json_safe(v) then
            return false
        end
    end
    return true
end

return util
end

-- lua/refshell/config.lua
package.preload["refshell.config"] = function(...)
-- Tiny JSON key/value store. Files live in reframework/data/ via json.load_file.

local util = require("refshell.util")

local function create_config(opts)
    opts = opts or {}
    if type(opts.id) ~= "string" or opts.id == "" then
        error("RefShell.Config: id must be a non-empty string")
    end
    if opts.defaults ~= nil and type(opts.defaults) ~= "table" then
        error("RefShell.Config: defaults must be a table")
    end
    if opts.defaults ~= nil and not util.is_json_safe(opts.defaults) then
        error("RefShell.Config: defaults must be JSON-safe")
    end

    local id = opts.id
    local file_path = opts.file
    if type(file_path) ~= "string" or file_path == "" then
        file_path = "refshell_" .. id .. ".json"
    end
    local autosave = opts.autosave ~= false
    local defaults = util.deep_copy(opts.defaults or {})
    local store = {}
    local load_failed = false
    local cfg = {}

    local function merge_loaded(loaded)
        store = util.deep_copy(defaults)
        if type(loaded) ~= "table" then
            return
        end
        for k, v in pairs(loaded) do
            if type(k) == "string" then
                store[k] = util.deep_copy(v)
            end
        end
    end

    local loaded = nil
    local ok_load, result = pcall(json.load_file, file_path)
    if ok_load then
        loaded = result
    end
    if loaded == nil then
        merge_loaded(nil)
        log.info(string.format("[RefShell.Config] %s: no config yet (%s)", id, file_path))
    elseif type(loaded) ~= "table" then
        load_failed = true
        merge_loaded(nil)
        log.error(string.format("[RefShell.Config] %s: %s is not an object (file left untouched)", id, file_path))
    else
        merge_loaded(loaded)
        log.info(string.format("[RefShell.Config] %s: loaded %s", id, file_path))
    end

    function cfg:has(key)
        return type(key) == "string" and store[key] ~= nil
    end

    function cfg:Get(key)
        if type(key) ~= "string" or key == "" then
            error("RefShell.Config:Get: key must be a non-empty string")
        end
        local value = store[key]
        if value == nil then
            value = defaults[key]
        end
        return util.deep_copy(value)
    end

    function cfg:Set(key, value)
        if type(key) ~= "string" or key == "" then
            error("RefShell.Config:Set: key must be a non-empty string")
        end
        if value ~= nil and not util.is_json_safe(value) then
            error("RefShell.Config:Set: value must be JSON-safe")
        end

        local current = store[key]
        if current == nil then
            current = defaults[key]
        end
        if util.deep_equal(current, value) then
            return
        end

        if value == nil then
            store[key] = nil
        else
            store[key] = util.deep_copy(value)
        end
        load_failed = false
        if autosave then
            cfg:Save()
        end
    end

    function cfg:Save()
        if load_failed then
            log.error(string.format("[RefShell.Config] %s: skip save, %s did not parse", id, file_path))
            return false
        end
        local out = {}
        for k, v in pairs(store) do
            out[k] = v
        end
        local ok, err = pcall(json.dump_file, file_path, out, 4)
        if not ok then
            log.error(string.format("[RefShell.Config] %s: save failed %s — %s", id, file_path, tostring(err)))
            return false
        end
        return true
    end

    function cfg:File()
        return file_path
    end

    return cfg
end

return {
    create = create_config,
    Init = create_config,
}
end

-- lua/refshell/input.lua
package.preload["refshell.input"] = function(...)
-- Virtual-key display names for menu rebinding.

local VK_NAMES = {
    [0x08] = "Backspace",
    [0x09] = "Tab",
    [0x0D] = "Enter",
    [0x10] = "Shift",
    [0x11] = "Ctrl",
    [0x12] = "Alt",
    [0x1B] = "Esc",
    [0x20] = "Space",
    [0x25] = "Left",
    [0x26] = "Up",
    [0x27] = "Right",
    [0x28] = "Down",
    [0x2D] = "Insert",
    [0x2E] = "Delete",
    [0x70] = "F1",
    [0x71] = "F2",
    [0x72] = "F3",
    [0x73] = "F4",
    [0x74] = "F5",
    [0x75] = "F6",
    [0x76] = "F7",
    [0x77] = "F8",
    [0x78] = "F9",
    [0x79] = "F10",
    [0x7A] = "F11",
    [0x7B] = "F12",
    [0xC0] = "~",
}

local function vk_name(vk)
    if VK_NAMES[vk] then
        return VK_NAMES[vk]
    end
    if vk >= 0x30 and vk <= 0x39 then
        return string.char(vk)
    end
    if vk >= 0x41 and vk <= 0x5A then
        return string.char(vk)
    end
    return string.format("VK 0x%02X", vk)
end

return {
    VK_NAMES = VK_NAMES,
    vk_name = vk_name,
}
end

-- lua/refshell/theme.lua
package.preload["refshell.theme"] = function(...)
-- Colors, window flags, and style push/pop for REF ImGui.

local COL = {
    Text = 0,
    TextDisabled = 1,
    WindowBg = 2,
    ChildBg = 3,
    PopupBg = 4,
    Border = 5,
    BorderShadow = 6,
    FrameBg = 7,
    FrameBgHovered = 8,
    FrameBgActive = 9,
    TitleBg = 10,
    TitleBgActive = 11,
    TitleBgCollapsed = 12,
    MenuBarBg = 13,
    ScrollbarBg = 14,
    ScrollbarGrab = 15,
    ScrollbarGrabHovered = 16,
    ScrollbarGrabActive = 17,
    CheckMark = 18,
    SliderGrab = 19,
    SliderGrabActive = 20,
    Button = 21,
    ButtonHovered = 22,
    ButtonActive = 23,
    Header = 24,
    HeaderHovered = 25,
    HeaderActive = 26,
    Separator = 27,
    SeparatorHovered = 28,
    SeparatorActive = 29,
    ResizeGrip = 30,
    ResizeGripHovered = 31,
    ResizeGripActive = 32,
}

local WIN = {
    NoTitleBar = 1,
    NoResize = 2,
    NoMove = 4,
    NoScrollbar = 8,
    NoCollapse = 32,
    AlwaysAutoResize = 64,
    NoSavedSettings = 256,
}

local COND = {
    Always = 1,
    Once = 2,
    FirstUseEver = 4,
    Appearing = 8,
}

local THEMES = {
    midnight = {
        window   = { 0.08, 0.08, 0.10, 0.94 },
        -- Child windows do not show WindowBg underneath. Alpha 0 punches
        -- through to the game — the workspace is almost all children.
        child    = { 0.08, 0.08, 0.10, 0.94 },
        title    = { 0.06, 0.06, 0.07, 1.00 },
        border   = { 0.28, 0.28, 0.32, 0.80 },
        text     = { 0.92, 0.93, 0.95, 1.00 },
        muted    = { 0.62, 0.64, 0.68, 1.00 },
        frame    = { 0.14, 0.15, 0.17, 1.00 },
        frame_h  = { 0.20, 0.22, 0.26, 1.00 },
        button   = { 0.18, 0.19, 0.22, 1.00 },
        button_h = { 0.24, 0.26, 0.30, 1.00 },
        button_a = { 0.12, 0.55, 0.58, 1.00 },
        header   = { 0.16, 0.17, 0.20, 1.00 },
        header_h = { 0.22, 0.24, 0.28, 1.00 },
        accent   = { 0.20, 0.82, 0.88, 1.00 },
        accent_d = { 0.10, 0.42, 0.46, 1.00 },
        selected = { 0.16, 0.48, 0.28, 1.00 },
        check    = { 0.20, 0.82, 0.88, 1.00 },
        sep      = { 0.32, 0.33, 0.36, 0.70 },
        grab     = { 0.20, 0.82, 0.88, 1.00 },
    },
    -- DevTools workspace only. Trainer menu stays midnight.
    violet = {
        window   = { 0.07, 0.07, 0.09, 0.97 },
        child    = { 0.07, 0.07, 0.09, 0.97 },
        title    = { 0.10, 0.06, 0.12, 1.00 },
        border   = { 0.46, 0.24, 0.54, 0.90 },
        text     = { 0.94, 0.93, 0.96, 1.00 },
        muted    = { 0.64, 0.60, 0.70, 1.00 },
        frame    = { 0.12, 0.11, 0.15, 1.00 },
        frame_h  = { 0.24, 0.16, 0.28, 1.00 },
        button   = { 0.46, 0.24, 0.56, 1.00 },
        button_h = { 0.58, 0.32, 0.68, 1.00 },
        button_a = { 0.34, 0.16, 0.44, 1.00 },
        header   = { 0.28, 0.14, 0.36, 1.00 },
        header_h = { 0.40, 0.20, 0.50, 1.00 },
        accent   = { 0.80, 0.38, 0.90, 1.00 },
        accent_d = { 0.42, 0.18, 0.52, 1.00 },
        selected = { 0.52, 0.24, 0.62, 1.00 },
        check    = { 0.80, 0.38, 0.90, 1.00 },
        sep      = { 0.42, 0.28, 0.50, 0.70 },
        grab     = { 0.80, 0.38, 0.90, 1.00 },
    },
}

-- ImGuiStyleVar enum is not bound on REF 1.5.9. Indices are ImGui 1.83+
-- (DisabledAlpha inserted at 1). Wrong type on a slot is skipped via pcall.
--
-- REF push_style_color only accepts Vector4f or a packed int. Lua tables are
-- a silent no-op, so counting those "pushes" and popping them trips
-- PopStyleColor / PopStyleVar too many times.
local SV = {
    WindowPadding = 2,
    WindowRounding = 3,
    WindowBorderSize = 4,
    WindowTitleAlign = 6,
    FramePadding = 11,
    FrameRounding = 12,
    ItemSpacing = 14,
    ScrollbarRounding = 19,
    GrabRounding = 21,
}

local function as_vec4(rgba)
    if type(rgba) ~= "table" then
        return rgba
    end
    if not Vector4f or not Vector4f.new then
        return nil
    end
    return Vector4f.new(rgba[1] or 0, rgba[2] or 0, rgba[3] or 0, rgba[4] or 1)
end

local function as_vec2(value)
    if type(value) ~= "table" then
        return value
    end
    if not Vector2f or not Vector2f.new then
        return nil
    end
    return Vector2f.new(value[1] or 0, value[2] or 0)
end

local function push_color(idx, rgba)
    local color = as_vec4(rgba)
    if color == nil then
        return false
    end
    return pcall(imgui.push_style_color, idx, color)
end

local function push_theme(theme)
    local t = theme or THEMES.midnight
    local color_n = 0
    local var_n = 0

    local function c(idx, rgba)
        if push_color(idx, rgba) then
            color_n = color_n + 1
        end
    end

    local function v(idx, value)
        local packed = as_vec2(value)
        if packed == nil then
            return
        end
        if pcall(imgui.push_style_var, idx, packed) then
            var_n = var_n + 1
        end
    end

    c(COL.Text, t.text)
    c(COL.TextDisabled, t.muted)
    c(COL.WindowBg, t.window)
    c(COL.ChildBg, t.child)
    c(COL.PopupBg, t.window)
    c(COL.Border, t.border)
    c(COL.FrameBg, t.frame)
    c(COL.FrameBgHovered, t.frame_h)
    c(COL.FrameBgActive, t.frame)
    c(COL.TitleBg, t.title)
    c(COL.TitleBgActive, t.title)
    c(COL.TitleBgCollapsed, t.title)
    c(COL.CheckMark, t.check)
    c(COL.SliderGrab, t.grab)
    c(COL.SliderGrabActive, t.accent)
    c(COL.Button, t.button)
    c(COL.ButtonHovered, t.button_h)
    c(COL.ButtonActive, t.button_a)
    c(COL.Header, t.header)
    c(COL.HeaderHovered, t.header_h)
    c(COL.HeaderActive, t.accent_d)
    c(COL.Separator, t.sep)
    c(COL.ScrollbarBg, { 0.05, 0.05, 0.06, 0.60 })
    c(COL.ScrollbarGrab, { 0.32, 0.33, 0.36, 1.00 })
    c(COL.ResizeGrip, { 0.20, 0.82, 0.88, 0.35 })
    c(COL.ResizeGripHovered, t.accent)

    v(SV.WindowRounding, 8)
    v(SV.WindowBorderSize, 1)
    v(SV.WindowPadding, { 14, 16 })
    v(SV.FrameRounding, 4)
    v(SV.FramePadding, { 8, 5 })
    v(SV.ItemSpacing, { 8, 6 })
    v(SV.GrabRounding, 4)
    v(SV.ScrollbarRounding, 6)
    v(SV.WindowTitleAlign, { 0.5, 0.5 })

    return color_n, var_n
end

local function pop_theme(color_n, var_n)
    if color_n > 0 then
        pcall(imgui.pop_style_color, color_n)
    end
    if var_n > 0 then
        pcall(imgui.pop_style_var, var_n)
    end
end

local function display_size()
    local ok, size = pcall(imgui.get_display_size)
    if ok and size then
        return size.x, size.y
    end
    return 1920, 1080
end

local function dock_pos(dock, width, height, margin)
    local dw, dh = display_size()
    local y = margin
    if y < 8 then
        y = 8
    end
    if height > dh - margin * 2 then
        height = dh - margin * 2
    end
    if width > dw - margin * 2 then
        width = math.max(240, dw - margin * 2)
    end
    if dock == "left" then
        return margin, y
    elseif dock == "center" then
        return (dw - width) * 0.5, y
    end
    return dw - width - margin, y
end

local function fitted_height(margin)
    local _, dh = display_size()
    local h = dh - margin * 2
    if h < 320 then
        h = math.max(200, dh - 8)
    end
    return h
end

-- Live dual-pane: finder 40% left, DevTools 60% right, full display height.
local function live_split(margin)
    margin = margin or 16
    if margin < 8 then
        margin = 8
    end
    local dw, dh = display_size()
    local gap = 8
    local inner_w = dw - margin * 2 - gap
    if inner_w < 480 then
        gap = 4
        inner_w = math.max(320, dw - 16)
        margin = 8
    end
    local left_w = math.floor(inner_w * 0.40)
    if left_w < 280 then
        left_w = math.min(280, math.max(200, inner_w - 220))
    end
    local right_w = inner_w - left_w
    local h = fitted_height(margin)
    local y = margin
    return {
        left = { x = margin, y = y, w = left_w, h = h },
        right = { x = margin + left_w + gap, y = y, w = right_w, h = h },
    }
end

-- Remaining content width from the current cursor. Prefer ImGui's
-- region avail so a vertical scrollbar is not counted as usable space.
local function content_width()
    local ok, avail = pcall(imgui.get_content_region_avail)
    if ok and avail and type(avail.x) == "number" and avail.x > 0 then
        return math.max(120, avail.x)
    end
    local size = imgui.get_window_size()
    local cursor = imgui.get_cursor_pos()
    local left = 14
    if cursor and cursor.x then
        left = cursor.x
    end
    local scroll = 0
    local ok_s, max_y = pcall(imgui.get_scroll_max_y)
    if ok_s and type(max_y) == "number" and max_y > 1 then
        scroll = 14
    end
    local w = 320
    if size and size.x then
        w = size.x - left * 2 - scroll
    end
    if w < 120 then
        w = 120
    end
    return w
end

local theme = {
    COL = COL,
    WIN = WIN,
    COND = COND,
    SV = SV,
    themes = THEMES,
    as_vec4 = as_vec4,
    as_vec2 = as_vec2,
    push_color = push_color,
    push_theme = push_theme,
    pop_theme = pop_theme,
    display_size = display_size,
    dock_pos = dock_pos,
    fitted_height = fitted_height,
    live_split = live_split,
    content_width = content_width,
}

return theme
end

-- lua/refshell/host.lua
package.preload["refshell.host"] = function(...)
-- Optional RE Engine host: HID cursor fallback + look lock.
-- Onimusha types plus leftover Wilds names. Attach only when a game needs it:
--   RefShell.create({ host = true, lock_camera = true })

local host = {
    name = "re_engine",
}

function host.attach(menu)
    if menu._host then
        return menu
    end
    menu._host = host.name
    menu._mouse_write_ok = false
    menu._warp_skips = menu._warp_skips or 0
    menu._request_moves = menu._request_moves or 0

    -- Cursor: via.hid.Mouse ShowCursor + AbsoluteMode. No GUI mask,
    -- requestMask, or setMouseDeltaPos. Look lock is addRotationDegree skip.
    -- Onimusha uses EnableLocalMouseCursor / GUI090000 instead of
    -- Wilds isMouseCursorAvailable.
    function menu:mouse_type()
        if not self._mouse_td then
            self._mouse_td = sdk.find_type_definition("via.hid.Mouse")
        end
        return self._mouse_td
    end

    function menu:mouse_call(name, ...)
        local td = self:mouse_type()
        if not td then
            return nil, false
        end
        local method = td:get_method(name)
        if not method then
            return nil, false
        end
        local a, b = ...
        local ok, result = pcall(function()
            if b ~= nil then
                return method:call(nil, a, b)
            end
            if a ~= nil then
                return method:call(nil, a)
            end
            return method:call(nil)
        end)
        if ok then
            return result, true
        end
        return nil, false
    end

    -- Own writes must pass the setter hooks. Game writes are skipped
    -- while the menu is open so ShowCursor / clip cannot snap back.
    function menu:mouse_own(name, value)
        self._mouse_write_ok = true
        local result, ok = self:mouse_call(name, value)
        self._mouse_write_ok = false
        return result, ok
    end

    function menu:gui_manager()
        return sdk.get_managed_singleton("app.GUIManager")
    end

    -- Cursor: via.hid.Mouse ShowCursor + AbsoluteMode.
    -- Wilds: isMouseCursorAvailable + _VirtualMouseEnable + IsHighHudInput.
    -- Onimusha: EnableLocalMouseCursor + GUI090000 isEnableMouseCursor +
    -- IsHighHudInput / IsHighTitleInput. No isMouseCursorAvailable.
    -- Look: CAMERA / CAMERA_RESET button masks when those enums exist.
    -- Do not requestMask or setEnable(5).
    function menu:hook_bool_when_open(type_name, method_name, when_open)
        local td = sdk.find_type_definition(type_name)
        if not td then
            return false
        end
        local method = td:get_method(method_name)
        if not method then
            return false
        end
        local ok = pcall(sdk.hook, method, function()
            if self:wants_game_cursor() then
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(retval)
            if self:wants_game_cursor() then
                return sdk.to_ptr(when_open and 1 or 0)
            end
            return retval
        end)
        return ok
    end

    function menu:note_warp_skip()
        self._warp_skips = (self._warp_skips or 0) + 1
    end

    function menu:note_request_move()
        self._request_moves = (self._request_moves or 0) + 1
    end

    -- Count only. requestMove is the pause-menu software cursor, not the
    -- look recenter. Skipping it fights the path we want to copy.
    function menu:hook_count(type_name, method_name, on_call)
        local td = sdk.find_type_definition(type_name)
        if not td then
            return false
        end
        local method = td:get_method(method_name)
        if not method then
            return false
        end
        local ok = pcall(sdk.hook, method, function()
            if on_call then
                on_call(self)
            end
        end)
        return ok
    end

    function menu:hook_mouse_block_when_open(method_name, count_warp)
        local td = self:mouse_type()
        if not td then
            return false
        end
        local method = td:get_method(method_name)
        if not method then
            return false
        end
        local ok = pcall(sdk.hook, method, function()
            if self:wants_game_cursor() and not self._mouse_write_ok then
                if count_warp then
                    self:note_warp_skip()
                end
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end)
        return ok
    end

    -- REF patches Win32 SetCursorPos only while its own overlay is open.
    -- Lua never gets that API. These managed setters are the warp path we
    -- can skip; warp_skips stays 0 if recenter is a raw SetCursorPos.
    function menu:hook_skip_when_open(type_name, method_name, count_warp)
        local td = sdk.find_type_definition(type_name)
        if not td then
            return false
        end
        local method = td:get_method(method_name)
        if not method then
            return false
        end
        local ok = pcall(sdk.hook, method, function()
            if self:wants_game_cursor() and not self._mouse_write_ok then
                if count_warp then
                    self:note_warp_skip()
                end
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end)
        return ok
    end

    function menu:install_cursor_hooks()
        if not self.lock_cursor or self._cursor_hooks then
            return
        end
        self._cursor_hooks = true
        -- Wilds names stay so a later port can keep working.
        self:hook_bool_when_open("app.GUIManager", "isMouseCursorAvailable", true)
        self:hook_bool_when_open("app.GUIManager", "get_VirtualMouseEnable", true)
        self:hook_bool_when_open("app.GUIManager", "get_IsHighHudInput", true)
        self:hook_bool_when_open("app.GUIManager", "get_IsHighTitleInput", true)
        self:hook_bool_when_open("app.GUIManager", "get_EnableLocalMouseCursor", true)
        self:hook_bool_when_open("app.GUI090000", "isEnableMouseCursor", true)
        self:hook_bool_when_open("app.GUI090000", "isDisableMouseCursor", false)
        self:hook_bool_when_open("app.GUIManager", "isActiveMouse", true)
        self:hook_bool_when_open("app.GUIManager", "isActiveMouseOrKeybord", true)
        -- Block gameplay HID writes. Do not hook the getters — the probe
        -- needs the real ShowCursor / clip values.
        self:hook_mouse_block_when_open("set_ShowCursor")
        self:hook_mouse_block_when_open("set_AbsoluteMode")
        self:hook_mouse_block_when_open("set_ClipCursorToScreen")
        self:hook_mouse_block_when_open("set_ViewCursorPosition", true)
        self:hook_mouse_block_when_open("set_PresentRectCursorPosition", true)
        self:hook_count("app.GUIManager", "requestMoveMouseCursor", function(m)
            m:note_request_move()
        end)
        self:hook_count("app.GUI090000", "requestMove", function(m)
            m:note_request_move()
        end)
    end

    function menu:game_input()
        return sdk.get_managed_singleton("app.GameInputManager")
    end

    function menu:button_mask_user(name)
        local td = sdk.find_type_definition("app.PlayerDef.ButtonMask.USER")
        if not td then
            return nil
        end
        local field = td:get_field(name)
        if not field then
            return nil
        end
        local ok, value = pcall(function()
            return field:get_data(nil)
        end)
        if ok then
            return value
        end
        return nil
    end

    function menu:apply_player_mask(want)
        local gim = self:game_input()
        if not gim then
            return
        end
        if want then
            for _, name in ipairs({ "CAMERA", "CAMERA_RESET" }) do
                local value = self:button_mask_user(name)
                if value ~= nil then
                    pcall(function()
                        gim:call("setPlayerButtonMask", value)
                    end)
                end
            end
        end
    end

    function menu:gui_type(gui)
        if not gui then
            return nil
        end
        local ok, td = pcall(function()
            return gui:get_type_definition()
        end)
        if ok then
            return td
        end
        return nil
    end

    function menu:gui_bool(gui, names)
        if not gui then
            return nil
        end
        local td = self:gui_type(gui)
        for _, name in ipairs(names) do
            if td and td:get_method(name) then
                local ok, value = pcall(function()
                    return gui:call(name)
                end)
                if ok and value ~= nil then
                    return value and true or false
                end
            elseif td and td:get_field(name) then
                local ok, value = pcall(function()
                    return gui:get_field(name)
                end)
                if ok and value ~= nil then
                    return value and true or false
                end
            end
        end
        return nil
    end

    function menu:gui_set_bool(gui, names, value)
        if not gui then
            return
        end
        local td = self:gui_type(gui)
        if not td then
            return
        end
        for _, name in ipairs(names) do
            if td:get_method(name) then
                pcall(function()
                    gui:call(name, value)
                end)
            elseif td:get_field(name) then
                pcall(function()
                    gui:set_field(name, value)
                end)
            end
        end
    end

    function menu:gui_call(gui, name, ...)
        if not gui then
            return nil, false
        end
        local td = self:gui_type(gui)
        if not td or not td:get_method(name) then
            return nil, false
        end
        local a, b = ...
        local ok, result = pcall(function()
            if b ~= nil then
                return gui:call(name, a, b)
            end
            if a ~= nil then
                return gui:call(name, a)
            end
            return gui:call(name)
        end)
        if ok then
            return result, true
        end
        return nil, false
    end

    function menu:apply_virtual_mouse(want)
        local gui = self:gui_manager()
        -- Pause-menu input path (Wilds-style): EnableLocalMouseCursor +
        -- setEnableGameMenuInput -> setEnableCtrl. Do not openGameMenu
        -- (draws pause). Do not lockGameMenuOpen until a pause-menu
        -- probe says isLockGameMenuOpen actually flips with the cursor.
        local read_names = {
            "get_EnableLocalMouseCursor",
            "<EnableLocalMouseCursor>k__BackingField",
        }
        local write_names = {
            "set_EnableLocalMouseCursor",
            "<EnableLocalMouseCursor>k__BackingField",
        }
        if want then
            if not self._vmouse_owned then
                local prev = self:gui_bool(gui, read_names)
                self._prev_vmouse = prev and true or false
                self._vmouse_owned = true
            end
            self:gui_set_bool(gui, write_names, true)
            self:gui_call(gui, "setEnableGameMenuInput", true)
        elseif self._vmouse_owned then
            self:gui_set_bool(gui, write_names, self._prev_vmouse and true or false)
            self:gui_call(gui, "setEnableGameMenuInput", false)
            self._vmouse_owned = false
        end
    end

    function menu:apply_cursor(want)
        if not self.lock_cursor then
            return
        end

        self:apply_virtual_mouse(want)
        self:apply_player_mask(want)

        if want then
            if not self._cursor_shown then
                local shown, shown_ok = self:mouse_call("get_ShowCursor")
                local abs, abs_ok = self:mouse_call("get_AbsoluteMode")
                local clip, clip_ok = self:mouse_call("get_ClipCursorToScreen")
                if shown_ok then
                    self._prev_show_cursor = shown and true or false
                end
                if abs_ok then
                    self._prev_absolute = abs and true or false
                end
                if clip_ok then
                    self._prev_clip = clip and true or false
                end
                self._cursor_shown = true
            end
            self:mouse_own("set_ShowCursor", true)
            self:mouse_own("set_AbsoluteMode", true)
            self:mouse_own("set_ClipCursorToScreen", false)
        elseif self._cursor_shown then
            local prev_show = self._prev_show_cursor
            if prev_show == nil then
                prev_show = false
            end
            local prev_abs = self._prev_absolute
            if prev_abs == nil then
                prev_abs = false
            end
            self:mouse_own("set_ShowCursor", prev_show)
            self:mouse_own("set_AbsoluteMode", prev_abs)
            local prev_clip = self._prev_clip
            if prev_clip == nil then
                prev_clip = true
            end
            self:mouse_own("set_ClipCursorToScreen", prev_clip)
            self._cursor_shown = false
        end
    end

    function menu:tick_cursor()
        if self.lock_cursor then
            self:apply_cursor(self:wants_native_cursor())
        end
    end

    -- DMC5: forbidCameraControl. Wilds look lives on cPlayerCameraOperator
    -- (mouseRotation / padRotation), not AutoRotator and not event camera.
    -- Do not hook GUI, requestMask, setMouseDeltaPos, or markEventCamera.
    function menu:wants_camera_lock()
        return self.lock_camera and self.cfg.open
    end

    function menu:try_obj_call(obj, name)
        if not obj then
            return nil
        end
        local ok, result = pcall(function()
            return obj:call(name)
        end)
        if ok and result ~= nil and type(result) == "userdata" then
            return result
        end
        return nil
    end

    function menu:master_info()
        local pm = sdk.get_managed_singleton("app.PlayerManager")
        if not pm then
            return nil
        end
        return self:try_obj_call(pm, "getMasterPlayer")
            or self:try_obj_call(pm, "get_MasterPlayer")
    end

    function menu:camera_controller()
        local cm = sdk.get_managed_singleton("app.CameraManager")
        if cm then
            local ok, cam = pcall(function()
                return cm:get_field("_MasterPlCamera")
            end)
            if ok and cam then
                self._cam = cam
                return cam
            end
        end

        local info = self:master_info()
        local candidates = {
            info,
            self:try_obj_call(info, "get_Character"),
            self:try_obj_call(info, "get_Controller"),
            self:try_obj_call(info, "get_ContextHolder"),
            self:try_obj_call(info, "get_Hunter"),
        }
        for _, obj in ipairs(candidates) do
            local cam = self:try_obj_call(obj, "get_CameraController")
            if cam then
                self._cam = cam
                return cam
            end
        end

        local go = self:try_obj_call(info, "get_Object")
            or self:try_obj_call(info, "get_GameObject")
        local chara = self:try_obj_call(info, "get_Character")
        if not go and chara then
            go = self:try_obj_call(chara, "get_GameObject")
        end
        if go then
            local ok, cam = pcall(function()
                local typ = sdk.typeof("app.PlayerCameraController")
                if not typ then
                    return nil
                end
                return go:call("getComponent(System.Type)", typ)
            end)
            if ok and cam then
                self._cam = cam
                return cam
            end
        end
        return self._cam
    end

    function menu:camera_operator(cam)
        cam = cam or self:camera_controller()
        if not cam then
            return nil
        end
        local ok, op = pcall(function()
            return cam:get_field("_Operator") or cam:call("get_RotationOperator")
        end)
        if ok and op then
            self._cam_op = op
            return op
        end
        return self._cam_op
    end

    function menu:zero_look_input(op)
        if not op or not Vector2f then
            return
        end
        local zero = Vector2f.new(0, 0)
        for _, name in ipairs({
            "_MouseRotateAmount",
            "_PadInput",
            "_GyroInputAmount",
            "_RotAmount",
            "_RotDir",
        }) do
            pcall(function()
                op:set_field(name, zero)
            end)
        end
        pcall(function()
            op:set_field("_IsRotated", false)
        end)
        pcall(function()
            op:set_field("_IsRotatePad", false)
        end)
    end

    function menu:apply_camera_lock(want)
        if not self.lock_camera then
            return
        end
        self._cam_lock_active = want and true or false
        local cam = self:camera_controller()
        local op = self:camera_operator(cam)
        if want then
            self:zero_look_input(op)
            if cam then
                pcall(function()
                    cam:call("breakAutoRotate")
                end)
            end
        end
    end

    function menu:tick_camera()
        if self.lock_camera then
            self:apply_camera_lock(self:wants_camera_lock())
        end
    end

    function menu:install_camera_hooks()
        if self._cam_hooks then
            return
        end
        self._cam_hooks = true

        local function skip_if_locked(args)
            if not self:wants_camera_lock() then
                return
            end
            local obj = nil
            pcall(function()
                obj = sdk.to_managed_object(args[2])
            end)
            if obj then
                local tname = ""
                pcall(function()
                    tname = obj:get_type_definition():get_name()
                end)
                if tname == "cPlayerCameraOperator" or tname == "PlayerCameraController" then
                    if tname == "cPlayerCameraOperator" then
                        self._cam_op = obj
                    else
                        self._cam = obj
                    end
                end
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        local function hook_skip(td, name)
            if not td then
                return
            end
            local method = td:get_method(name)
            if not method then
                return
            end
            pcall(sdk.hook, method, skip_if_locked, function(retval)
                return retval
            end)
        end

        local cam_td = sdk.find_type_definition("app.PlayerCameraController")
        hook_skip(cam_td, "addRotationDegree(via.vec2, System.Boolean)")
        hook_skip(cam_td, "addRotationDegree")
        hook_skip(cam_td, "overwriteRotationDegree")

        local op_td = sdk.find_type_definition("app.cPlayerCameraOperator")
        hook_skip(op_td, "update")
        hook_skip(op_td, "mouseRotation")
        hook_skip(op_td, "padRotation")
        hook_skip(op_td, "gyroRotation")

        local rot_td = sdk.find_type_definition("app.cPlayerCameraAutoRotator")
        hook_skip(rot_td, "update")

        -- Onimusha look. Wilds names above stay for the later port.
        local ig_td = sdk.find_type_definition("app.cInGameCameraOperator")
        hook_skip(ig_td, "addGameCameraRotationDegree")
        hook_skip(ig_td, "setGameCameraRotationDegree")
    end

    function menu:_host_prepare_open(want)
        if want and not self._cursor_shown then
            local shown, shown_ok = self:mouse_call("get_ShowCursor")
            local abs, abs_ok = self:mouse_call("get_AbsoluteMode")
            local clip, clip_ok = self:mouse_call("get_ClipCursorToScreen")
            if shown_ok then
                self._prev_show_cursor = shown and true or false
            end
            if abs_ok then
                self._prev_absolute = abs and true or false
            end
            if clip_ok then
                self._prev_clip = clip and true or false
            end
            self._cursor_shown = true
        end
    end

    function menu:_host_reset()
        self:apply_cursor(false)
        self:apply_camera_lock(false)
    end

    function menu:_host_bind()
        self:install_camera_hooks()
        self:install_cursor_hooks()
        for _, entry in ipairs({
            "UpdateHID",
            "EndUpdateHID",
            "BeginUpdateHID",
            "BeginRendering",
            "PrepareRendering",
        }) do
            pcall(re.on_application_entry, entry, function()
                self:tick_cursor()
            end)
        end
    end

    return menu
end

return host
end

-- lua/refshell/log.lua
package.preload["refshell.log"] = function(...)
-- In-menu ring buffer. Collection is always on; the Show Logs button
-- draws this. os.clock() is 0 in REF Lua — stamp with a frame counter.

local theme = require("refshell.theme")

local COL = theme.COL
local WIN = theme.WIN
local COND = theme.COND
local push_color = theme.push_color
local push_theme = theme.push_theme
local pop_theme = theme.pop_theme
local display_size = theme.display_size
local content_width = theme.content_width

local Log = {}

local MAX = 2000
local entries = {}
local frame = 0
local seq = 0
local seen = 0

local ui_state = {
    filter = "",
    autoscroll = true,
    kind = 1,
}

local KIND_LABELS = { "All", "Info", "Warn", "Error", "Found", "Skip" }
local KIND_KEYS = { "all", "info", "warn", "error", "found", "skip" }

local KIND_COLOR = {
    info = 0xFFE8E8EE,
    warn = 0xFF66C8E6,
    error = 0xFF5A5AE6,
    found = 0xFF6EE66E,
    skip = 0xFFA0A3AD,
    done = 0xFFE0D133,
}

local function trim(s)
    if s == nil then
        return ""
    end
    return tostring(s):match("^%s*(.-)%s*$") or ""
end

function Log.tick()
    frame = frame + 1
end

function Log.frame()
    return frame
end

function Log.count()
    return #entries
end

function Log.unread()
    local n = seq - seen
    if n < 0 then
        return 0
    end
    return n
end

function Log.mark_seen()
    seen = seq
end

function Log.entries()
    return entries
end

function Log.clear()
    entries = {}
    seq = 0
    seen = 0
end

function Log.add(kind, source, text)
    kind = kind or "info"
    if KIND_COLOR[kind] == nil then
        kind = "info"
    end
    seq = seq + 1
    local line = {
        seq = seq,
        frame = frame,
        kind = kind,
        source = trim(source),
        text = trim(text),
    }
    entries[#entries + 1] = line
    if #entries > MAX then
        table.remove(entries, 1)
    end
    pcall(function()
        local prefix = "[DevTools]"
        if line.source ~= "" then
            prefix = prefix .. "[" .. line.source .. "]"
        end
        log.info(prefix .. " " .. line.text)
    end)
    return line
end

function Log.info(source, text)
    return Log.add("info", source, text)
end

function Log.warn(source, text)
    return Log.add("warn", source, text)
end

function Log.error(source, text)
    return Log.add("error", source, text)
end

function Log.found(source, text)
    return Log.add("found", source, text)
end

function Log.skipped(source, text)
    return Log.add("skip", source, text)
end

function Log.done(source, count)
    local n = tonumber(count) or 0
    if n == 1 then
        return Log.add("done", source, "Done — 1 result.")
    end
    return Log.add("done", source, string.format("Done — %d result(s).", n))
end

--- Same console shape as the UE4SS DevTools kit.
function Log.skipped_reason(source, reason)
    return Log.skipped(source, "Skipped: " .. tostring(reason))
end

function Log.found_path(source, full_name)
    return Log.found(source, "Found: " .. tostring(full_name))
end

function Log.not_found(source, what)
    return Log.add("skip", source, "Not found: " .. tostring(what))
end

local function matches(entry, needle, kind_key)
    if kind_key ~= "all" and entry.kind ~= kind_key then
        if not (kind_key == "info" and entry.kind == "done") then
            return false
        end
    end
    if needle == "" then
        return true
    end
    local hay = (entry.source .. " " .. entry.text):lower()
    return hay:find(needle, 1, true) ~= nil
end

local function format_line(entry)
    local src = entry.source
    if src ~= "" then
        return string.format("[%d] [%s] %s", entry.frame, src, entry.text)
    end
    return string.format("[%d] %s", entry.frame, entry.text)
end

local function place_window(menu, width, height)
    local dw, dh = display_size()
    local margin = (menu.cfg and menu.cfg.margin) or 16
    local rect = menu._win_rect
    local x = margin
    local y = margin
    if rect then
        local dock = menu.cfg and menu.cfg.dock or "right"
        if dock == "right" then
            x = rect.x - width - 8
            y = rect.y
            if x < margin then
                x = rect.x
                y = rect.y + rect.h + 8
            end
        elseif dock == "left" then
            x = rect.x + rect.w + 8
            y = rect.y
            if x + width > dw - margin then
                x = rect.x
                y = rect.y + rect.h + 8
            end
        else
            x = rect.x
            y = rect.y + rect.h + 8
        end
    end
    if y + height > dh - 8 then
        y = math.max(8, dh - height - 8)
    end
    if x < 8 then
        x = 8
    end
    return x, y
end

function Log.place(menu, width, height)
    return place_window(menu, width, height)
end

function Log.draw_contents(menu, opts)
    local kind = ui_state.kind
    if kind < 1 or kind > #KIND_LABELS then
        kind = 1
    end
    local next_kind = kind
    if menu and menu.ui and menu.ui.choice_grid then
        next_kind = menu.ui.choice_grid(KIND_LABELS, kind, 3)
    end
    if next_kind ~= kind then
        ui_state.kind = next_kind
    end

    local avail = content_width()
    local clear_w = 72
    local filter_w = avail - clear_w - 8
    if filter_w < 80 then
        filter_w = 80
    end
    local typed, text
    if menu and menu.ui and menu.ui.input_text then
        typed, text = menu.ui.input_text("devtools_log_filter", ui_state.filter, {
            label = "Filter logs",
            placeholder = "text in a line…",
            width = filter_w,
        })
    else
        imgui.push_item_width(filter_w)
        typed, text = imgui.input_text("##devtools_log_filter", ui_state.filter)
        imgui.pop_item_width()
    end
    if typed and type(text) == "string" then
        ui_state.filter = text
    end
    imgui.same_line()
    if imgui.button("Clear##devtools_log", { clear_w, 0 }) then
        Log.clear()
    end

    local changed_scroll, scroll_on = imgui.checkbox("Autoscroll", ui_state.autoscroll)
    if changed_scroll then
        ui_state.autoscroll = scroll_on and true or false
    end
    imgui.same_line()
    imgui.text_colored(string.format("%d / %d", #entries, MAX), 0xFFA0A3AD)

    local needle = trim(ui_state.filter):lower()
    local kind_key = KIND_KEYS[ui_state.kind] or "all"
    local shown = 0

    opts = opts or {}
    local list_h = opts.list_h
    if type(list_h) ~= "number" then
        local win = imgui.get_window_size()
        local cursor = imgui.get_cursor_pos()
        list_h = 260
        if win and cursor and win.y and cursor.y then
            list_h = win.y - cursor.y - 18
        end
    end
    if list_h < 80 then
        list_h = 80
    end

    imgui.begin_child_window("##devtools_log_list", { 0, list_h }, true)
    if #entries == 0 then
        imgui.text_colored("No log lines yet. Dev tab scans and gameplay traces land here.", 0xFFA0A3AD)
    else
        for i = 1, #entries do
            local entry = entries[i]
            if matches(entry, needle, kind_key) then
                shown = shown + 1
                imgui.text_colored(format_line(entry), KIND_COLOR[entry.kind] or KIND_COLOR.info)
            end
        end
        if shown == 0 then
            imgui.text_colored("No lines match this filter.", 0xFFA0A3AD)
        elseif ui_state.autoscroll then
            pcall(function()
                if imgui.set_scroll_here_y then
                    imgui.set_scroll_here_y(1.0)
                elseif imgui.set_scroll_y and imgui.get_scroll_max_y then
                    imgui.set_scroll_y(imgui.get_scroll_max_y())
                end
            end)
        end
    end
    imgui.end_child_window()
end

function Log.draw(menu)
    if not menu or not menu._logs_open then
        return
    end

    Log.mark_seen()

    local width = 960
    local height = 420
    local rect = menu._win_rect
    if rect and rect.h and rect.h > 240 then
        height = math.min(rect.h, 560)
    end
    local x, y = place_window(menu, width, height)
    imgui.set_next_window_pos({ x, y }, COND.Always)
    imgui.set_next_window_size({ width, height }, COND.Always)

    local color_n, var_n = push_theme(menu.theme)
    local open = imgui.begin_window("DevTools Logs", true, WIN.NoCollapse + WIN.NoSavedSettings)
    if open then
        Log.draw_contents(menu)
        menu:note_imgui_hover(true)
    end
    imgui.end_window()
    menu:note_imgui_hover(false)
    pop_theme(color_n, var_n)

    if not open then
        menu._logs_open = false
    end
end

function Log.footer_label()
    local n = Log.unread()
    if n > 0 then
        return string.format("Show Logs (%d)", n)
    end
    return "Show Logs"
end

return Log
end

-- lua/refshell/ui.lua
package.preload["refshell.ui"] = function(...)
-- Trainer widget kit: section, toggle, filter_dropdown, shell_settings.
-- RefShell.create calls Ui.make(menu). Do not draw the menu window here.

local input = require("refshell.input")
local theme_mod = require("refshell.theme")

local COL = theme_mod.COL
local COND = theme_mod.COND
local push_color = theme_mod.push_color
local content_width = theme_mod.content_width
local vk_name = input.vk_name

local Ui = {}

local function make_ui(menu)
    local ui = {}
    local theme = menu.theme

    function ui.theme()
        return theme
    end

    function ui.section(title, draw_fn, default_open)
        if default_open == nil then
            default_open = true
        end
        if default_open then
            imgui.set_next_item_open(true, COND.FirstUseEver)
        end
        local header_id = default_open and "##sec" or "##sec_closed"
        if imgui.collapsing_header(title .. header_id) then
            imgui.indent(6)
            draw_fn()
            imgui.unindent(6)
            imgui.spacing()
        end
    end

    function ui.label(text)
        imgui.text(text)
    end

    -- Label above, hint inside the box when empty. REFramework has no InputTextWithHint.
    function ui.input_text(id, value, opts)
        opts = opts or {}
        local label = opts.label
        local placeholder = opts.placeholder or ""
        local width = opts.width
        if width == nil then
            width = -1
        end
        if type(label) == "string" and label ~= "" then
            imgui.text(label)
        end
        value = tostring(value or "")
        if width ~= false then
            imgui.push_item_width(width)
        end
        local screen = imgui.get_cursor_screen_pos()
        local changed, text = imgui.input_text("##" .. id, value)
        if width ~= false then
            imgui.pop_item_width()
        end
        local current = value
        if changed and type(text) == "string" then
            current = text
        end
        local focused = imgui.is_item_active and imgui.is_item_active()
        if current == "" and placeholder ~= "" and not focused then
            local dl = imgui.get_window_draw_list()
            if dl and dl.add_text and screen then
                local x = (screen.x or screen[1] or 0) + 6
                local y = (screen.y or screen[2] or 0) + 3
                dl:add_text({ x, y }, 0xFF7A7D86, placeholder)
            end
        end
        return changed, text
    end

    local function note_width()
        local win = imgui.get_window_size()
        local cursor = imgui.get_cursor_pos()
        if win and cursor and win.x and cursor.x then
            return math.max(48, win.x - cursor.x - 18)
        end
        return 340
    end

    local function text_width(s)
        local ok, sz = pcall(imgui.calc_text_size, s)
        if ok and sz then
            return sz.x or sz[1] or (#s * 7)
        end
        return #s * 7
    end

    local function wrap_note(text, max_w)
        text = tostring(text or "")
        local out = {}
        for para in (text .. "\n"):gmatch("(.-)\n") do
            if para == "" then
                out[#out + 1] = ""
            else
                local line = ""
                for word in para:gmatch("%S+") do
                    local trial = (line == "") and word or (line .. " " .. word)
                    if line ~= "" and text_width(trial) > max_w then
                        out[#out + 1] = line
                        line = word
                    else
                        line = trial
                    end
                end
                if line ~= "" then
                    out[#out + 1] = line
                end
            end
        end
        if #out == 0 then
            out[1] = text
        end
        return out
    end

    function ui.muted(text)
        for _, line in ipairs(wrap_note(text, note_width())) do
            imgui.text_colored(line, 0xFFA0A3AD)
        end
    end

    function ui.kv(key, value)
        local text = tostring(key) .. ":  " .. tostring(value)
        for _, line in ipairs(wrap_note(text, note_width())) do
            imgui.text(line)
        end
    end

    function ui.separator()
        imgui.separator()
    end

    function ui.spacing()
        imgui.spacing()
    end

    function ui.toggle(label, value)
        return imgui.checkbox(label, value and true or false)
    end

    function ui.bind_toggle(label, tbl, key)
        if type(tbl[key .. "_vk"]) ~= "number" then
            tbl[key .. "_vk"] = 0
        end
        menu._toggle_labels = menu._toggle_labels or {}
        menu._toggle_labels[tbl] = menu._toggle_labels[tbl] or {}
        menu._toggle_labels[tbl][key] = label

        local changed, value = imgui.checkbox(label, tbl[key] and true or false)
        if changed then
            tbl[key] = value
            menu.dirty = true
        end
        return changed, value
    end

    function ui.bind_hotkey(label, tbl, key)
        if type(key) == "string" and key:sub(-3) == "_vk" then
            local bool_key = key:sub(1, -4)
            menu._toggle_labels = menu._toggle_labels or {}
            menu._toggle_labels[tbl] = menu._toggle_labels[tbl] or {}
            if not menu._toggle_labels[tbl][bool_key] then
                menu._toggle_labels[tbl][bool_key] = label
            end
        end
        local vk = tbl[key]
        local name = (type(vk) == "number" and vk > 0) and vk_name(vk) or "None"
        local dest = menu.rebinding
        local waiting = dest and dest.tbl == tbl and dest.key == key
        imgui.text(label .. ":  " .. name)
        if waiting then
            ui.muted("Press a key...  (Esc to cancel)")
            return
        end
        local has = type(vk) == "number" and vk > 0
        local avail = content_width()
        local btn_w = has and ((avail - 8) / 2) or -1
        if imgui.button("Rebind##" .. tostring(label) .. tostring(key), { btn_w, 28 }) then
            menu.rebinding = { tbl = tbl, key = key }
        end
        if has then
            imgui.same_line()
            if imgui.button("Clear##" .. tostring(label) .. tostring(key), { btn_w, 28 }) then
                tbl[key] = 0
                menu.dirty = true
            end
        end
    end

    function ui.slider_float(label, value, min_v, max_v, fmt)
        imgui.push_item_width(-1)
        local changed, new_v = imgui.slider_float(label, value, min_v, max_v, fmt)
        imgui.pop_item_width()
        return changed, new_v
    end

    function ui.bind_slider(label, tbl, key, min_v, max_v, fmt)
        local changed, value = ui.slider_float(label, tbl[key], min_v, max_v, fmt)
        if changed then
            tbl[key] = value
            menu.dirty = true
        end
        return changed, value
    end

    -- items: values, or {value, label}. tbl[key] stores the selected value.
    -- imgui.combo is 1-based in REFramework.
    function ui.bind_combo(label, tbl, key, items)
        local labels = {}
        local values = {}
        local current = 1
        for i, item in ipairs(items) do
            if type(item) == "table" then
                values[i] = item[1] or item.value
                labels[i] = item[2] or item.label or tostring(values[i])
            else
                values[i] = item
                labels[i] = tostring(item)
            end
            if tbl[key] == values[i] then
                current = i
            end
        end

        imgui.text(label)
        imgui.push_item_width(-1)
        local changed, new_i
        if imgui.combo then
            changed, new_i = imgui.combo("##" .. label, current, labels)
        else
            new_i = ui.choice_grid(labels, current, math.min(#labels, 3))
            changed = new_i ~= current
        end
        imgui.pop_item_width()

        if changed and new_i and values[new_i] ~= nil then
            tbl[key] = values[new_i]
            menu.dirty = true
            return true, values[new_i]
        end
        return false, tbl[key]
    end

    function ui.button(label, width, height)
        return imgui.button(label, { width or -1, height or 28 })
    end

    -- Floating confirm. Drawn outside the tab child so it cannot
    -- trip ImGui EndChild. opts: title, lines, yes, no, on_yes, on_no.
    function ui.confirm(opts)
        opts = opts or {}
        local lines = opts.lines
        if type(lines) ~= "table" then
            lines = { tostring(opts.body or "") }
        end
        menu._confirm = {
            title = opts.title or "Confirm",
            lines = lines,
            yes = opts.yes or "Confirm",
            no = opts.no or "Cancel",
            on_yes = opts.on_yes,
            on_no = opts.on_no,
        }
    end

    function ui.actions(items, columns)
        columns = columns or 2
        local avail = content_width()
        local gap = 8
        local btn_w = (avail - gap * (columns - 1)) / columns
        local btn_h = 30

        for i, item in ipairs(items) do
            local label = item[1] or item.label
            local fn = item[2] or item.on_click
            local col = (i - 1) % columns
            if col > 0 then
                imgui.same_line()
            end
            imgui.push_id(i)
            if imgui.button(label, { btn_w, btn_h }) and fn then
                fn()
            end
            imgui.pop_id()
        end
    end

    -- Green Pick... button that expands an inline filter list.
    -- items: labels, or {value, label}. selected is 1-based, 0 means none.
    -- state: { open = bool, filter = string } owned by the caller.
    function ui.filter_dropdown(id, button_label, items, selected, state, opts)
        opts = opts or {}
        state = state or {}
        if state.open == nil then
            state.open = false
        end
        if type(state.filter) ~= "string" then
            state.filter = ""
        end

        local function clean_label(text)
            if type(text) ~= "string" then
                return ""
            end
            local out = text
                :gsub("</?%s*[Cc][Oo][Ll][Oo][Rr][^>]*>", "")
                :gsub("</?%s*[%w_]+[^>]*>", "")
                :gsub("%s+", " ")
                :gsub("^%s+", "")
                :gsub("%s+$", "")
            if out:find("#Rejected#", 1, true) or out:find("ItemData", 1, true) then
                return ""
            end
            return (out:gsub("##", "  "))
        end

        local labels = {}
        for i, item in ipairs(items or {}) do
            if type(item) == "table" then
                labels[i] = clean_label(item[2] or item.label or tostring(item[1] or item.value or i))
            else
                labels[i] = clean_label(item)
            end
        end

        local caption = clean_label(button_label)
        if caption == "" then
            if selected and labels[selected] and labels[selected] ~= "" then
                caption = labels[selected]
            else
                caption = opts.placeholder or "Pick..."
            end
        end
        imgui.begin_group()

        local pick_pushed = 0
        if push_color(COL.Button, theme.selected) then
            pick_pushed = pick_pushed + 1
        end
        if push_color(COL.ButtonHovered, theme.button_a) then
            pick_pushed = pick_pushed + 1
        end
        local arrow_w = 28
        local btn_w = content_width() - arrow_w - 8
        if btn_w < 80 then
            btn_w = 80
        end
        local opened = false
        if imgui.button(caption .. "##" .. id .. "_pick", { btn_w, 30 }) then
            opened = true
        end
        imgui.same_line()
        -- ImGuiDir 3 = down. Stay down so this matches native combos.
        if imgui.arrow_button("##" .. id .. "_arrow", 3) then
            opened = true
        end
        if opened then
            state.open = not state.open
            state._ignore_click = true
        end
        if pick_pushed > 0 then
            imgui.pop_style_color(pick_pushed)
        end

        local changed = false
        local result = selected or 0

        if state.open then
            local needle = state.filter:lower()
            local filtered = {}
            for i, label in ipairs(labels) do
                if label ~= "" and (needle == "" or label:lower():find(needle, 1, true)) then
                    table.insert(filtered, { i = i, label = label })
                end
            end

            imgui.spacing()
            imgui.text(string.format("%s (%d)", opts.header or "Items", #filtered))

            local avail = content_width()
            local clear_w = 64
            local filter_w = avail - clear_w - 8
            if filter_w < 80 then
                filter_w = 80
            end
            local frame_pushed = 0
            if push_color(COL.Border, theme.selected) then
                frame_pushed = frame_pushed + 1
            end
            local typed, text = ui.input_text(id .. "_filter", state.filter, {
                label = "Filter",
                placeholder = opts.filter_placeholder or "Type to filter…",
                width = filter_w,
            })
            if frame_pushed > 0 then
                imgui.pop_style_color(frame_pushed)
            end
            if typed and type(text) == "string" then
                state.filter = text
            end
            imgui.same_line()
            if imgui.button("Clear##" .. id, { clear_w, 0 }) then
                state.filter = ""
            end

            local list_h = opts.height or 240
            imgui.begin_child_window("##" .. id .. "_list", { 0, list_h }, true)
            if #filtered == 0 then
                ui.muted("No matches.")
            else
                for _, row in ipairs(filtered) do
                    local is_sel = row.i == result
                    local sel_pushed = 0
                    if is_sel then
                        if push_color(COL.Button, theme.selected) then
                            sel_pushed = sel_pushed + 1
                        end
                        if push_color(COL.ButtonHovered, theme.selected) then
                            sel_pushed = sel_pushed + 1
                        end
                    end
                    imgui.push_id(id .. "_row_" .. tostring(row.i))
                    if imgui.button(row.label, { -1, 26 }) then
                        result = row.i
                        changed = true
                        state.open = false
                        menu.dirty = true
                    end
                    imgui.pop_id()
                    if sel_pushed > 0 then
                        imgui.pop_style_color(sel_pushed)
                    end
                    imgui.separator()
                end
            end
            imgui.end_child_window()
        end

        imgui.end_group()

        if state._ignore_click then
            state._ignore_click = false
        elseif state.open and imgui.is_mouse_clicked and imgui.is_mouse_clicked(0) and imgui.is_item_hovered and not imgui.is_item_hovered() then
            state.open = false
        end

        return result, changed
    end

    function ui.choice_grid(items, selected, columns)
        columns = columns or 2
        local avail = content_width()
        local gap = 8
        local btn_w = (avail - gap * (columns - 1)) / columns
        local btn_h = 28
        local result = selected

        for i, item in ipairs(items) do
            local label = item
            if type(item) == "table" then
                label = item[1] or item.label
            end
            local col = (i - 1) % columns
            if col > 0 then
                imgui.same_line()
            end

            local is_sel = (i == selected)
            local sel_pushed = 0
            if is_sel then
                if push_color(COL.Button, theme.selected) then
                    sel_pushed = sel_pushed + 1
                end
                if push_color(COL.ButtonHovered, theme.selected) then
                    sel_pushed = sel_pushed + 1
                end
            end
            imgui.push_id(1000 + i)
            if imgui.button(label, { btn_w, btn_h }) then
                result = i
                menu.dirty = true
            end
            imgui.pop_id()
            if sel_pushed > 0 then
                imgui.pop_style_color(sel_pushed)
            end
        end

        return result
    end

    function ui.shell_settings()
        ui.section("Window", function()
            ui.muted("Docks to the chosen side when you open the menu or the game window size changes.")
            ui.muted("Settings and cheats save to reframework/data/" .. menu:config_path())
            imgui.spacing()
            ui.actions({
                { "Dock Right",  function() menu:dock_now("right") end },
                { "Dock Left",   function() menu:dock_now("left") end },
                { "Dock Center", function() menu:dock_now("center") end },
                { "Reset Size",  function() menu:reset_size() end },
            }, 2)
        end, true)

        ui.section("Keybind", function()
            ui.bind_hotkey("Toggle menu", menu.cfg, "toggle_vk")
            ui.muted("Shift + this key opens Live View. The key alone leaves Live and returns to the tab you were on. Cheat binds are below.")
            if type(menu.extra_keybinds) == "function" then
                menu.extra_keybinds(ui)
            end
        end, true)
    end

    return ui
end

function Ui.make(menu)
    return make_ui(menu)
end

return Ui
end

-- lua/refshell.lua
package.preload["refshell"] = function(...)
-- RefShell: reusable ImGui trainer shell for REFramework.
-- Lua module: require("refshell")  or  _G.RefShell
--
--   local cfg = RefShell.Config.create({ id = "MyMod", defaults = { volume = 1 } })
--   cfg:Get("volume")
--   cfg:Set("volume", 0.5)  -- reframework/data/refshell_MyMod.json
--
-- Cursor lock: reframework/plugins/ref_cursor.dll  (refcursor.request)
-- Look lock / HID fallback: create({ host = true, lock_camera = true })
-- Live View is a separate product (REFrameworkLiveView). This repo is the menu shell.
--
-- REFramework has no BeginTabBar binding, so tabs are custom buttons.

local RefShell = _G.RefShell or {}
_G.RefShell = RefShell

local util = require("refshell.util")
local config_mod = require("refshell.config")
local input = require("refshell.input")
local theme = require("refshell.theme")
local log_mod = require("refshell.log")

local COL = theme.COL
local WIN = theme.WIN
local COND = theme.COND
local THEMES = theme.themes
local push_color = theme.push_color
local push_theme = theme.push_theme
local pop_theme = theme.pop_theme
local display_size = theme.display_size
local dock_pos = theme.dock_pos
local fitted_height = theme.fitted_height
local live_split = theme.live_split
local content_width = theme.content_width
local vk_name = input.vk_name
local copy_defaults = util.copy_defaults
local deep_copy = util.deep_copy
local is_json_safe = util.is_json_safe
local create_config = config_mod.create

RefShell.Config = config_mod
RefShell.Log = log_mod

local ui_mod = require("refshell.ui")

function RefShell.create(opts)
    opts = opts or {}
    local menu = {
        id = opts.id or "menu",
        title = opts.title or "TRAINER",
        theme = opts.theme or THEMES.midnight,
        tabs = {},
        active_tab = 1,
        dirty = false,
        rebinding = false,
        pending_dock = nil,
        pending_size = false,
        apply_layout = false,
        key_was_down = false,
        bound = false,
        ui = nil,
        lock_camera = opts.lock_camera == true,
        lock_cursor = opts.lock_cursor ~= false,
        can_open = opts.can_open,
        on_open_blocked = opts.on_open_blocked,
        _logs_open = false,
        _live_layout = false,
        _dock_override = nil,
        _dock_before_live = nil,
    }

    menu.cfg = copy_defaults(opts.config or {}, {
        open = opts.start_open or false,
        auto_open = false,
        auto_open_vk = 0,
        toggle_vk = opts.toggle_vk or 0x75,
        width = opts.width or 520,
        height = opts.height or 720,
        dock = opts.dock or "right",
        margin = opts.margin or 16,
        layout_rev = 0,
    })
    menu._persist = opts.persist

    menu.ui = ui_mod.make(menu)

    if opts.host then
        require("refshell.host").attach(menu)
    end

    function menu:config_path()
        return "refshell_" .. self.id .. ".json"
    end

    function menu:remember(tbl)
        self._persist = tbl
        return self
    end

    function menu:apply_store(tbl)
        if not tbl or not self.config then
            return
        end
        for k, _ in pairs(tbl) do
            if self.config:has(k) then
                tbl[k] = self.config:Get(k)
            end
        end
    end

    function menu:sync_store(tbl)
        if not tbl or not self.config then
            return
        end
        for k, v in pairs(tbl) do
            if is_json_safe(v) then
                self.config:Set(k, v)
            end
        end
    end

    function menu:load()
        if not self.config then
            self.config = create_config({
                id = self.id,
                file = self:config_path(),
                defaults = deep_copy(self.cfg),
                autosave = false,
            })
        end
        self:apply_store(self.cfg)
        self:apply_store(self._persist)
        -- Bump when default dock size/padding changes.
        if (self.cfg.layout_rev or 0) < 4 then
            self.cfg.layout_rev = 4
            self.cfg.width = opts.width or self.cfg.width
            self.cfg.margin = opts.margin or self.cfg.margin
            self.apply_layout = true
            self.dirty = true
        end
    end

    function menu:save()
        if not self.config then
            return
        end
        self:sync_store(self.cfg)
        self:sync_store(self._persist)
        self.config:Save()
        self.dirty = false
    end

    function menu:add_tab(name, draw_fn)
        self.tabs[#self.tabs + 1] = { name = name, draw = draw_fn }
        return self
    end

    function menu:dock_now(side)
        self.cfg.dock = side
        self.pending_dock = side
        self.pending_size = true
        self.dirty = true
    end

    function menu:reset_size()
        self.cfg.width = opts.width or 520
        self.pending_size = true
        self.apply_layout = true
        self.dirty = true
    end

    function menu:current_size()
        local margin = self.cfg.margin or 16
        if self._live_layout then
            local split = live_split(margin)
            return split.left.w, split.left.h
        end
        local dw = display_size()
        local w = self.cfg.width or 520
        local max_w = dw - margin * 2
        if w > max_w then
            w = math.max(240, max_w)
        end
        return w, fitted_height(margin)
    end

    -- Pixel pos is not saved. Re-dock when the menu opens or the game
    -- window size changes so a resolution swap cannot leave it off-screen.
    function menu:refresh_layout()
        local dw, dh = display_size()
        local opened = self._just_opened
        self._just_opened = false
        local resized = self._disp_w ~= dw or self._disp_h ~= dh
        if resized then
            self._disp_w = dw
            self._disp_h = dh
        end
        if opened or resized then
            self.apply_layout = true
        end
    end

    function menu:has_tab(name)
        for i = 1, #self.tabs do
            if self.tabs[i].name == name then
                return true
            end
        end
        return false
    end

    function menu:select_tab(name)
        for i = 1, #self.tabs do
            if self.tabs[i].name == name then
                self.active_tab = i
                return true
            end
        end
        return false
    end

    function menu:restore_tab_before_live()
        if type(self._tab_before_live) == "number" and self.tabs[self._tab_before_live] then
            self.active_tab = self._tab_before_live
        end
        self._tab_before_live = nil
        self._live_shortcut = false
        self._logs_open = false
        self._ws_rect = nil
    end

    function menu:open_live()
        if not self:has_tab("Live") then
            return false
        end
        if self.cfg.open and self:is_live_tab() and self._live_shortcut then
            self:restore_tab_before_live()
            self:set_open(false)
            return true
        end
        if self.cfg.open and self:is_live_tab() then
            self:set_open(false)
            return true
        end
        if not self._live_shortcut then
            self._tab_before_live = self.active_tab
            self._live_shortcut = true
        end
        self:select_tab("Live")
        self._logs_open = true
        self:set_open(true)
        return true
    end

    local function draw_tabs(self)
        local n = #self.tabs
        if n == 0 then
            return
        end

        -- same_line() uses ItemSpacing.x (we push 8). Measure the row
        -- after the cursor is inset so left and right padding match.
        local pad_y = 10
        local gap = 8
        local tab_h = 28

        local origin_pos = imgui.get_cursor_pos()
        local left = (origin_pos and origin_pos.x) or 14
        imgui.set_cursor_pos({ left, ((origin_pos and origin_pos.y) or 0) + pad_y })

        local avail = content_width()
        local inner = avail - gap * (n - 1)
        if inner < n * 40 then
            inner = n * 40
        end
        local base_w = math.floor(inner / n)
        local leftover = inner - base_w * n

        for i, tab in ipairs(self.tabs) do
            if i > 1 then
                imgui.same_line()
            end
            -- Extra pixels go on earlier pills so the last one cannot
            -- spill past the right inset / scrollbar.
            local tab_w = base_w
            if leftover > 0 then
                tab_w = tab_w + 1
                leftover = leftover - 1
            end
            local origin = imgui.get_cursor_screen_pos()
            local active = (i == self.active_tab)
            local tab_pushed = 0
            if active then
                if push_color(COL.Button, self.theme.accent_d) then
                    tab_pushed = tab_pushed + 1
                end
                if push_color(COL.ButtonHovered, self.theme.accent_d) then
                    tab_pushed = tab_pushed + 1
                end
                if push_color(COL.Text, self.theme.accent) then
                    tab_pushed = tab_pushed + 1
                end
            end
            if imgui.button(tab.name, { tab_w, tab_h }) then
                self.active_tab = i
                if tab.name ~= "Live" then
                    self._live_shortcut = false
                    self._tab_before_live = nil
                end
            end
            if tab_pushed > 0 then
                imgui.pop_style_color(tab_pushed)
                -- Underline sits just under the button so label padding stays even.
                pcall(function()
                    local dl = imgui.get_window_draw_list()
                    if dl and origin then
                        dl:add_rect_filled(
                            { origin.x, origin.y + tab_h },
                            { origin.x + tab_w, origin.y + tab_h + 2 },
                            0xFFE0D133,
                            0,
                            0
                        )
                    end
                end)
            end
        end

        local row_top = ((origin_pos and origin_pos.y) or 0) + pad_y
        imgui.set_cursor_pos({ left, row_top + tab_h + pad_y })
        imgui.separator()
    end

    function menu:is_live_tab()
        local tab = self.tabs[self.active_tab]
        return tab ~= nil and tab.name == "Live"
    end

    -- Live reads left-to-right: menu on the left, workspace on the right.
    -- Do not persist this as the user's dock setting.
    function menu:sync_live_layout()
        if not self._liveview then
            return
        end
        local live = self:is_live_tab()
        if live and not self._live_layout then
            self._live_layout = true
            self._dock_before_live = self.cfg.dock
            self._dock_override = "left"
            self._logs_open = true
            self.apply_layout = true
        elseif (not live) and self._live_layout then
            self._live_layout = false
            self._dock_override = nil
            self._logs_open = false
            self._ws_rect = nil
            self.apply_layout = true
        end
    end

    function menu:draw_window()
        self:refresh_layout()
        self:sync_live_layout()
        local w, h = self:current_size()

        if self._live_layout then
            local split = live_split(self.cfg.margin or 16)
            imgui.set_next_window_pos({ split.left.x, split.left.y }, COND.Always)
            imgui.set_next_window_size({ split.left.w, split.left.h }, COND.Always)
            self.pending_dock = nil
            self.pending_size = false
            self.apply_layout = false
        elseif self.apply_layout or self.pending_dock then
            local side = self.pending_dock or self._dock_override or self.cfg.dock
            local x, y = dock_pos(side, w, h, self.cfg.margin)
            imgui.set_next_window_pos({ x, y }, COND.Always)
            imgui.set_next_window_size({ w, h }, COND.Always)
            self.pending_dock = nil
            self.pending_size = false
            self.apply_layout = false
        elseif self.pending_size then
            imgui.set_next_window_size({ w, h }, COND.Always)
            self.pending_size = false
        end

        self._imgui_hover = false
        local color_n, var_n = push_theme(self.theme)
        local still_open = imgui.begin_window(self.title, true, WIN.NoCollapse + WIN.NoSavedSettings)
        if still_open then
            -- Safety net if ImGui or a lagged display size left us off-screen.
            local pos_ok, pos = pcall(imgui.get_window_pos)
            local size_ok, size = pcall(imgui.get_window_size)
            if pos_ok and size_ok and pos and size then
                self._win_rect = {
                    x = pos.x,
                    y = pos.y,
                    w = size.x,
                    h = size.y,
                }
                local dw, dh = display_size()
                local on_screen = pos.x + size.x > 16
                    and pos.y + size.y > 16
                    and pos.x < dw - 16
                    and pos.y < dh - 16
                if not on_screen then
                    self.apply_layout = true
                end
            end
            local ok, err = pcall(draw_tabs, self)

            local win = imgui.get_window_size()
            local cursor = imgui.get_cursor_pos()
            local close_h = 40
            local body_h = 400
            if win and cursor then
                body_h = win.y - cursor.y - close_h - 12
            end
            if body_h < 100 then
                body_h = 100
            end

            imgui.begin_child_window("##refshell_body", { 0, body_h }, false)
            local tab_ok, tab_err = true, nil
            local tab = self.tabs[self.active_tab]
            if tab and tab.draw then
                tab_ok, tab_err = pcall(tab.draw, self.ui, self)
            end
            imgui.end_child_window()

            if not ok or not tab_ok then
                local msg = tostring(tab_err or err)
                self.ui.muted(msg)
            end

            imgui.spacing()
            local avail = content_width()
            local gap = 8
            local btn_w = (avail - gap) / 2
            local log_label
            if self._liveview then
                if self._logs_open then
                    log_label = "Hide Workspace"
                else
                    local unread = log_mod.unread()
                    if unread > 0 then
                        log_label = string.format("Show Workspace (%d)", unread)
                    else
                        log_label = "Show Workspace"
                    end
                end
            else
                log_label = self._logs_open and "Hide Logs" or log_mod.footer_label()
            end
            if imgui.button(log_label .. "##refshell_show_logs", { btn_w, 30 }) then
                self._logs_open = not self._logs_open
                if self._logs_open then
                    log_mod.mark_seen()
                end
            end
            imgui.same_line()
            if imgui.button("Close", { btn_w, 30 }) then
                still_open = false
            end
            self:note_imgui_hover(true)
        end
        imgui.end_window()
        self:note_imgui_hover(false)
        pop_theme(color_n, var_n)

        if not still_open then
            self.cfg.open = false
            self.dirty = true
            self._win_rect = nil
            self._imgui_hover = false
        end
    end

    -- Bootstrap-style alert: slides up from the bottom, then out.
    function menu:toast(text, kind, duration_ms)
        self._toast = {
            text = tostring(text or ""),
            kind = kind or "warning",
            started = os.clock(),
            duration = (duration_ms or 500) / 1000,
        }
    end

    function menu:draw_toast()
        local toast = self._toast
        if not toast then
            return
        end
        local now = os.clock()
        local age = now - toast.started
        if age >= toast.duration or toast.text == "" then
            self._toast = nil
            return
        end

        local slide = 0.08
        local lift = 36
        local offset = 0
        if age < slide then
            offset = (1 - age / slide) * lift
        elseif age > toast.duration - slide then
            offset = ((age - (toast.duration - slide)) / slide) * lift
        end

        local dw, dh = display_size()
        local width = 380
        local x = dw - width - (self.cfg.margin or 16)
        local y = dh - 70 - (self.cfg.margin or 16) + offset

        local bg = { 1.00, 0.95, 0.80, 0.96 }
        local border = { 0.90, 0.75, 0.25, 1.00 }
        local text = { 0.33, 0.24, 0.04, 1.00 }
        if toast.kind == "danger" then
            bg = { 0.97, 0.85, 0.86, 0.96 }
            border = { 0.85, 0.30, 0.32, 1.00 }
            text = { 0.45, 0.08, 0.10, 1.00 }
        elseif toast.kind == "success" then
            bg = { 0.82, 0.94, 0.86, 0.96 }
            border = { 0.30, 0.70, 0.45, 1.00 }
            text = { 0.08, 0.32, 0.16, 1.00 }
        end

        imgui.set_next_window_pos({ x, y }, COND.Always)
        imgui.set_next_window_size({ width, 0 }, COND.Always)
        local flags = WIN.NoTitleBar + WIN.NoResize + WIN.NoMove + WIN.NoScrollbar
            + WIN.NoCollapse + WIN.AlwaysAutoResize + WIN.NoSavedSettings
        local color_n = 0
        if push_color(COL.WindowBg, bg) then
            color_n = color_n + 1
        end
        if push_color(COL.Border, border) then
            color_n = color_n + 1
        end
        if push_color(COL.Text, text) then
            color_n = color_n + 1
        end
        -- REF skips ImGui::Begin when the open arg is false, then End() asserts.
        local open = imgui.begin_window("##refshell_toast", nil, flags)
        if open then
            imgui.text(toast.text)
            imgui.end_window()
        end
        if color_n > 0 then
            pcall(imgui.pop_style_color, color_n)
        end
    end

    function menu:draw_confirm()
        local confirm = self._confirm
        if not confirm then
            return
        end

        local width = 360
        local rect = self._win_rect
        local x
        local y
        if rect then
            x = rect.x + (rect.w - width) * 0.5
            y = rect.y + 88
        else
            local dw, dh = display_size()
            x = (dw - width) * 0.5
            y = dh * 0.28
        end

        imgui.set_next_window_pos({ x, y }, COND.Always)
        imgui.set_next_window_size({ width, 0 }, COND.Always)
        local flags = WIN.NoResize + WIN.NoCollapse + WIN.AlwaysAutoResize + WIN.NoSavedSettings
        local color_n, var_n = push_theme(self.theme)
        local open = imgui.begin_window(confirm.title, nil, flags)
        if open then
            for _, line in ipairs(confirm.lines or {}) do
                imgui.text(tostring(line))
            end
            imgui.spacing()
            local btn_w = 150
            if imgui.button(confirm.no .. "##refshell_confirm_no", { btn_w, 30 }) then
                self._confirm = nil
                if confirm.on_no then
                    pcall(confirm.on_no)
                end
            else
                imgui.same_line()
                local yes_pushed = 0
                if push_color(COL.Button, self.theme.selected) then
                    yes_pushed = yes_pushed + 1
                end
                if imgui.button(confirm.yes .. "##refshell_confirm_yes", { btn_w, 30 }) then
                    self._confirm = nil
                    if confirm.on_yes then
                        local ok, err = pcall(confirm.on_yes)
                        if not ok then
                            log.info("[RefShell] confirm yes failed: " .. tostring(err))
                        end
                    end
                end
                if yes_pushed > 0 then
                    imgui.pop_style_color(yes_pushed)
                end
            end
            imgui.end_window()
        end
        pop_theme(color_n, var_n)
    end

    function menu:mouse_screen_pos()
        local ok, m = pcall(function()
            return imgui.get_mouse()
        end)
        if ok and m then
            local x = m.x or m[1]
            local y = m.y or m[2]
            if type(x) == "number" and type(y) == "number" then
                return x, y
            end
        end
        return nil, nil
    end

    -- Root+children while our window is current; AnyWindow after end so
    -- combo popups that hang outside the menu rect still count.
    function menu:note_imgui_hover(in_window)
        if not imgui.is_window_hovered then
            return
        end
        local flags = in_window and 3 or 4
        local hovered = false
        pcall(function()
            hovered = imgui.is_window_hovered(flags) and true or false
        end)
        if hovered then
            self._imgui_hover = true
        end
    end

    function menu:pointer_over_menu()
        if not self.cfg.open then
            return false
        end
        if self._imgui_hover then
            return true
        end
        local mx, my = self:mouse_screen_pos()
        if mx == nil then
            return false
        end
        local function inside(r)
            return r and mx >= r.x and my >= r.y and mx <= r.x + r.w and my <= r.y + r.h
        end
        return inside(self._win_rect) or inside(self._ws_rect)
    end

    function menu:has_refcursor()
        return type(refcursor) == "table" and type(refcursor.request) == "function"
    end

    function menu:sync_refcursor(want)
        if not self:has_refcursor() then
            self._refcursor_held = false
            return
        end
        want = want and true or false
        if want and not self._refcursor_held then
            pcall(function()
                refcursor.request(true)
            end)
            self._refcursor_held = true
        elseif (not want) and self._refcursor_held then
            pcall(function()
                refcursor.request(false)
            end)
            self._refcursor_held = false
        end
    end

    -- Plugin locks the engine cursor for the whole open session.
    -- Without it, HID only forces the pointer while over this window.
    function menu:wants_native_cursor()
        if not self.lock_cursor or not self.cfg.open then
            return false
        end
        if self:has_refcursor() then
            return true
        end
        return self:pointer_over_menu()
    end

    function menu:wants_game_cursor()
        return self:wants_native_cursor()
    end

    function menu:is_allowed_open()
        return true
    end

    function menu:set_open(want)
        want = want and true or false
        if self.cfg.open == want then
            return true
        end
        if self._host_prepare_open then
            self:_host_prepare_open(want)
        end
        self.cfg.open = want
        self.dirty = true
        if want then
            self._just_opened = true
        end
        self:sync_refcursor(want)
        return true
    end

    function menu:tick_auto_open()
    end

    function menu:poll_toggle()
        if self.rebinding then
            local dest = self.rebinding
            local key = reframework:get_first_key_down()
            if key ~= nil then
                if key == 0x1B then
                    self.rebinding = false
                elseif key > 0x06 then
                    if dest == true then
                        self.cfg.toggle_vk = key
                    elseif type(dest) == "table" and dest.tbl and dest.key then
                        dest.tbl[dest.key] = key
                    end
                    self.rebinding = false
                    self.dirty = true
                    self.key_was_down = true
                    self._vk_down = self._vk_down or {}
                    self._vk_down[key] = true
                end
            end
            return
        end

        local shift = reframework:is_key_down(0x10)
            or reframework:is_key_down(0xA0)
            or reframework:is_key_down(0xA1)
        local down = reframework:is_key_down(self.cfg.toggle_vk)
        if down and not self.key_was_down then
            if shift and self:has_tab("Live") then
                self:open_live()
            elseif self._live_shortcut then
                self:restore_tab_before_live()
                self:set_open(true)
            elseif self.cfg.open then
                self:set_open(false)
            else
                self:set_open(true)
            end
        end
        self.key_was_down = down
    end

    function menu:key_edge(vk)
        if type(vk) ~= "number" or vk <= 0x06 then
            return false
        end
        if vk == self.cfg.toggle_vk then
            return false
        end
        self._vk_edge = self._vk_edge or {}
        if self._vk_edge[vk] ~= nil then
            return self._vk_edge[vk]
        end
        self._vk_down = self._vk_down or {}
        local down = reframework:is_key_down(vk)
        local was = self._vk_down[vk] and true or false
        self._vk_down[vk] = down
        local edge = down and not was
        self._vk_edge[vk] = edge
        return edge
    end

    function menu:poll_toggle_table(tbl)
        if not tbl then
            return
        end
        local labels = self._toggle_labels and self._toggle_labels[tbl]
        for k, v in pairs(tbl) do
            if type(v) == "boolean" and k ~= "open" then
                local vk = tbl[k .. "_vk"]
                if self:key_edge(vk) then
                    tbl[k] = not tbl[k]
                    self.dirty = true
                    local name = labels and labels[k] or k
                    self:toast((tbl[k] and "On: " or "Off: ") .. name, "info", 1400)
                end
            end
        end
    end

    function menu:poll_feature_binds()
        self._vk_edge = {}
        if self.rebinding then
            return
        end
        self:poll_toggle_table(self.cfg)
        self:poll_toggle_table(self._persist)
    end

    function menu:bind()
        if self.bound then
            return self
        end
        self.bound = true
        self:load()
        if self._host_bind then
            self:_host_bind()
        end
        if self.lock_cursor and not self:has_refcursor() then
            if self._host then
                log.info(
                "[RefShell] ref_cursor.dll not loaded — copy reframework/plugins/ref_cursor.dll into the game plugins folder. HID fallback is active.")
            else
                log.info(
                "[RefShell] ref_cursor.dll not loaded — copy reframework/plugins/ref_cursor.dll into the game plugins folder.")
            end
        end
        if self.lock_camera and not self._host then
            log.info("[RefShell] lock_camera needs create({ host = true }).")
        end

        if not self:has_tab("Settings") then
            self:add_tab("Settings", function(ui)
                ui.shell_settings()
            end)
        end

        re.on_frame(function()
            log_mod.tick()
            self:poll_toggle()
            self:poll_feature_binds()
            self:tick_auto_open()
            if self.tick_cursor then
                self:tick_cursor()
            end
            if self.tick_camera then
                self:tick_camera()
            end
            if self.cfg.open then
                self:draw_window()
                if self._logs_open then
                    if self._draw_workspace then
                        self._draw_workspace(self)
                    else
                        log_mod.draw(self)
                    end
                else
                    self._ws_rect = nil
                end
            end
            self:draw_toast()
            self:draw_confirm()
            if self.tick_cursor then
                self:tick_cursor()
            end
            if self.dirty then
                self:save()
            end
        end)

        re.on_draw_ui(function()
            if imgui.tree_node(self.title) then
                imgui.text("Toggle: " .. vk_name(self.cfg.toggle_vk))
                local changed, open = imgui.checkbox("Menu open", self.cfg.open)
                if changed then
                    self:set_open(open)
                end
                if imgui.button("Dock right") then
                    self:dock_now("right")
                    self:set_open(true)
                end
                imgui.tree_pop()
            end
        end)

        re.on_config_save(function()
            self:save()
        end)

        re.on_script_reset(function()
            self:sync_refcursor(false)
            if self._host_reset then
                self:_host_reset()
            end
            self:save()
        end)

        return self
    end

    return menu
end

RefShell.themes = THEMES
RefShell.COL = COL
RefShell.Log = log_mod
RefShell.vk_name = vk_name
RefShell.attach_host = function(menu)
    return require("refshell.host").attach(menu)
end

return RefShell
end

require("refshell")

-- reframework/autorun/appearance.lua
do
(function()
-- Appearance tab: shrine catalog + live mesh swap.
-- Does not write unlocks. DLC only works if those files are mounted.

local Appearance = {}

local try_call, try_field, try_any, try_static, is_managed, enum_value
local get_player_entity, get_player_context, log_action

local PARTS_BODY = 0
local PARTS_CLOAK = 5
local PARTS_WEAPON = 6

local catalog = {
    sword = { parts = PARTS_WEAPON, items = {}, labels = {} },
    cloak = { parts = PARTS_CLOAK, items = {}, labels = {} },
    body = { parts = PARTS_BODY, items = {}, labels = {} },
}

local state = {
    ready = false,
    named = false,
    sword_i = 0,
    cloak_i = 0,
    body_i = 0,
}

function Appearance.bind(deps)
    deps = deps or {}
    try_call = deps.try_call
    try_field = deps.try_field
    try_any = deps.try_any
    try_static = deps.try_static
    is_managed = deps.is_managed
    enum_value = deps.enum_value
    get_player_entity = deps.get_player_entity
    get_player_context = deps.get_player_context
    log_action = deps.log_action
end

local function serial_int(obj)
    if type(obj) == "number" then
        return obj
    end
    if not is_managed(obj) then
        return nil
    end
    local value = try_any(obj, { "get_Value", "get_FixedValue" })
        or try_field(obj, "_Value")
        or try_field(obj, "value__")
    if type(value) == "number" then
        return value
    end
    return nil
end

local function foreach_managed(collection, visitor)
    if not is_managed(collection) then
        return
    end
    local size = try_any(collection, { "get_Count", "get_Length", "get_size" })
    if type(size) ~= "number" then
        local ok, n = pcall(function()
            return collection:get_size()
        end)
        if ok then
            size = n
        end
    end
    if type(size) ~= "number" then
        return
    end
    for i = 0, size - 1 do
        local item = try_call(collection, "get_Item", i)
        if item == nil then
            local ok, value = pcall(function()
                return collection[i]
            end)
            if ok then
                item = value
            end
        end
        if item == nil then
            local ok, value = pcall(function()
                return collection:get_element(i)
            end)
            if ok then
                item = value
            end
        end
        if item ~= nil then
            visitor(item)
        end
    end
end

local function get_various_setting()
    local vdm = sdk.get_managed_singleton("app.VariousDataManager")
    return try_any(vdm, { "get_Setting" }) or try_field(vdm, "_Setting")
end

local function managed_string(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    if not is_managed(value) then
        return nil
    end
    local text = try_call(value, "ToString")
    if type(text) == "string" and text ~= "" and text ~= "System.String" then
        return text
    end
    return nil
end

local function guid_text(guid)
    if guid == nil then
        return nil
    end
    local td = sdk.find_type_definition("app.MessageUtil")
    local method = td and (td:get_method("getText(System.Guid)") or td:get_method("getText"))
    if method then
        local ok, text = pcall(function()
            return method:call(nil, guid)
        end)
        if ok then
            return managed_string(text)
        end
    end
    return nil
end

local function is_placeholder_name(name)
    if type(name) ~= "string" or name == "" then
        return true
    end
    if name == "No Name" or name == "None" or name == "INVALID" then
        return true
    end
    if name:find("アイテム名が設定されていません", 1, true) then
        return true
    end
    local lower = name:lower()
    if lower:find("item name is not set", 1, true) then
        return true
    end
    return false
end

local function item_name(item_id)
    item_id = serial_int(item_id) or item_id
    if type(item_id) ~= "number" or item_id == 0 then
        return nil
    end
    local name = managed_string(try_static("app.ItemUtil", { "getItemName" }, item_id))
    if name and not is_placeholder_name(name) then
        return name
    end
    local data = try_static("app.ItemUtil", { "getData" }, item_id)
    local guid = try_any(data, { "get_NameGuid" }) or try_field(data, "_NameGuid")
    name = guid_text(guid)
    if name and not is_placeholder_name(name) then
        return name
    end
    return nil
end

local function is_dlc_enum_name(name)
    return type(name) == "string" and name:find("5%d%d$") ~= nil
end

local function pretty_mesh_name(enum_name)
    if type(enum_name) ~= "string" then
        return "Mesh"
    end
    local label = enum_name
        :gsub("^WEAPONS", "Sword ")
        :gsub("^CLOAK", "Haori ")
        :gsub("^BODY", "Clothing ")
    if is_dlc_enum_name(enum_name) then
        label = label .. " (DLC)"
    end
    return label
end

local function with_dlc_suffix(label, dlc)
    if type(label) ~= "string" or label == "" then
        return label
    end
    if dlc and not label:find("%(DLC%)", 1, false) then
        return label .. " (DLC)"
    end
    return label
end

local function enum_entries(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        return {}, nil
    end
    local ok, fields = pcall(function()
        return td:get_fields()
    end)
    if not ok or not fields then
        return {}, nil
    end
    local out = {}
    local invalid = nil
    for _, field in ipairs(fields) do
        local name = field.get_name and field:get_name()
        if type(name) == "string" then
            local ok_val, value = pcall(function()
                return field:get_data(nil)
            end)
            if ok_val and type(value) == "number" then
                if name == "INVALID" then
                    invalid = value
                elseif name ~= "value__" and name ~= "MAX" then
                    table.insert(out, { name = name, id = value })
                end
            end
        end
    end
    table.sort(out, function(a, b)
        return a.name < b.name
    end)
    return out, invalid
end

local function catalog_add(bucket, id, label, sid, named, dlc)
    id = serial_int(id) or id
    if type(id) ~= "number" then
        return
    end
    for _, item in ipairs(bucket.items) do
        if item.id == id then
            if dlc then
                item.dlc = true
            end
            if label and (named or not item.named) then
                item.label = with_dlc_suffix(label, item.dlc)
                if named then
                    item.named = true
                end
            end
            if sid and not item.sid then
                item.sid = sid
            end
            return
        end
    end
    table.insert(bucket.items, {
        id = id,
        sid = sid,
        dlc = dlc == true,
        label = with_dlc_suffix(label or ("Mesh " .. tostring(id)), dlc == true),
        named = named == true,
    })
end

local function fill_from_enum(bucket, fixed_type, seq_type)
    local seq_by_name = {}
    if seq_type then
        local seq_entries = enum_entries(seq_type)
        for _, entry in ipairs(seq_entries) do
            seq_by_name[entry.name] = entry.id
        end
    end
    local entries, invalid = enum_entries(fixed_type)
    for _, entry in ipairs(entries) do
        if entry.id ~= invalid then
            catalog_add(
                bucket,
                entry.id,
                pretty_mesh_name(entry.name),
                seq_by_name[entry.name],
                false,
                is_dlc_enum_name(entry.name)
            )
        end
    end
    return invalid
end

local function fill_from_costume_table()
    local setting = get_various_setting()
    local costume_table = try_any(setting, { "get_CostumeItemData" })
        or try_field(setting, "_CostumeItemData")
    local list = try_field(costume_table, "_ItemList") or try_any(costume_table, { "get_ItemList" })
    local invalid_weapon = enum_value("app.PlayerEquipWeaponsID.TYPE_Fixed", "INVALID")
    local invalid_cloak = enum_value("app.PlayerEquipCloakID.TYPE_Fixed", "INVALID")
    local invalid_body = enum_value("app.PlayerEquipBodyID.TYPE_Fixed", "INVALID")
    local dlc_cond = enum_value("app.user_data.CostumeItemTable.DISPLAY_CONDITION", "PURCHASED_DLC") or 5
    local named = 0
    foreach_managed(list, function(row)
        local cond = serial_int(try_any(row, { "get_Condition" }) or try_field(row, "_Condition"))
        local dlc = cond == dlc_cond
        local name = item_name(try_any(row, { "get_ItemID" }) or try_field(row, "_ItemID"))
        if not name then
            return
        end
        local weapon = serial_int(try_any(row, { "get_PlayerWeaponsID" }) or try_field(row, "_PlayerWeaponsID"))
        local cloak = serial_int(try_any(row, { "get_PlayerCloakID" }) or try_field(row, "_PlayerCloakID"))
        local body = serial_int(try_any(row, { "get_PlayerBodyID" }) or try_field(row, "_PlayerBodyID"))
        if weapon and weapon ~= invalid_weapon then
            catalog_add(catalog.sword, weapon, name, nil, true, dlc)
            named = named + 1
        end
        if cloak and cloak ~= invalid_cloak then
            catalog_add(catalog.cloak, cloak, name, nil, true, dlc)
            named = named + 1
        end
        if body and body ~= invalid_body then
            catalog_add(catalog.body, body, name, nil, true, dlc)
            named = named + 1
        end
    end)
    return named
end

local function refresh_labels(bucket)
    bucket.labels = {}
    for i, item in ipairs(bucket.items) do
        bucket.labels[i] = item.label
    end
end

local function refresh_all_labels()
    refresh_labels(catalog.sword)
    refresh_labels(catalog.cloak)
    refresh_labels(catalog.body)
end

local function build_catalog()
    catalog.sword.items = {}
    catalog.cloak.items = {}
    catalog.body.items = {}
    fill_from_enum(catalog.sword, "app.PlayerEquipWeaponsID.TYPE_Fixed", "app.PlayerEquipWeaponsID.TYPE")
    fill_from_enum(catalog.cloak, "app.PlayerEquipCloakID.TYPE_Fixed", "app.PlayerEquipCloakID.TYPE")
    fill_from_enum(catalog.body, "app.PlayerEquipBodyID.TYPE_Fixed", "app.PlayerEquipBodyID.TYPE")
    fill_from_costume_table()
    refresh_all_labels()
end

local function ensure_catalog()
    if not state.ready or #catalog.sword.items == 0 then
        build_catalog()
        state.ready = #catalog.sword.items > 0
    end
    if not state.named then
        local named = fill_from_costume_table()
        refresh_all_labels()
        if type(named) == "number" and named > 0 then
            state.named = true
        end
    end
end

local function get_game_object_supporter()
    local entity = get_player_entity()
    local go = try_any(entity, { "get_GameObjectSupporter" })
        or try_field(entity, "<GameObjectSupporter>k__BackingField")
    if is_managed(go) then
        return go
    end
    return nil
end

local EQUIP_API = {
    [PARTS_BODY] = {
        get = "get_CurrentEquipBodyID",
        set = "set_CurrentEquipBodyID",
        field = "<CurrentEquipBodyID>k__BackingField",
    },
    [PARTS_CLOAK] = {
        get = "get_CurrentEquipCloakID",
        set = "set_CurrentEquipCloakID",
        field = "<CurrentEquipCloakID>k__BackingField",
    },
    [PARTS_WEAPON] = {
        get = "get_CurrentEquipWeaponsID",
        set = "set_CurrentEquipWeaponsID",
        field = "<CurrentEquipWeaponsID>k__BackingField",
    },
}

local function read_equip_id(ctx, parts)
    local api = EQUIP_API[parts]
    if api and is_managed(ctx) then
        local value = try_call(ctx, api.get) or try_field(ctx, api.field)
        if type(value) == "number" then
            return value
        end
    end
    local td = sdk.find_type_definition("app.PlayerManager")
    local method = td and td:get_method("getCurrentEquipID")
    if method and is_managed(ctx) then
        local ok, value = pcall(function()
            return method:call(nil, parts, ctx)
        end)
        if ok and type(value) == "number" then
            return value
        end
    end
    return nil
end

local function pick_equip_id(current, fixed, seq)
    if type(current) == "number" and current > 0 and current < 64 and type(seq) == "number" then
        return seq, "seq"
    end
    if type(fixed) == "number" then
        return fixed, "fixed"
    end
    return seq, "seq"
end

local function write_equip_id(ctx, parts, id)
    local api = EQUIP_API[parts]
    if not (api and is_managed(ctx) and type(id) == "number") then
        return false
    end
    local ok = pcall(function()
        ctx:call(api.set, id)
    end)
    pcall(function()
        ctx:set_field(api.field, id)
    end)
    return ok or read_equip_id(ctx, parts) == id
end

local function refresh_live_model(gos)
    if not is_managed(gos) then
        return false
    end
    pcall(function()
        gos:call("resetChangeState")
    end)
    local ok_a = pcall(function()
        gos:call("checkEquip")
    end)
    local ok_b = pcall(function()
        gos:call("checkModelChange")
    end)
    pcall(function()
        gos:call("checkModelUpdate")
    end)
    pcall(function()
        gos:call("checkSwitchBodyModelParts")
    end)
    return ok_a or ok_b
end

local function apply_mesh(parts, id, label, sid)
    if type(id) ~= "number" then
        log_action("mesh failed: bad id")
        return
    end
    local ctx = get_player_context()
    local gos = get_game_object_supporter()
    local was = read_equip_id(ctx, parts)
    local use_id, kind = pick_equip_id(was, id, sid)
    local set_ok = write_equip_id(ctx, parts, use_id)
    local refresh_ok = refresh_live_model(gos)
    local now = read_equip_id(ctx, parts)

    local bits = {
        tostring(label),
        kind .. "=" .. tostring(use_id),
        "was=" .. tostring(was),
        "now=" .. tostring(now),
        set_ok and "set" or "noset",
        refresh_ok and "check" or "nocheck",
        is_managed(gos) and "gos" or "nogos",
        is_managed(ctx) and "ctx" or "noctx",
    }
    log_action("mesh " .. table.concat(bits, " "))
end

local function draw_mesh_picker(ui, title, bucket, index_key)
    ui.section(title, function()
        if #bucket.labels == 0 then
            ui.muted("Waiting for mesh list.")
            return
        end
        local sel = ui.choice_grid(bucket.labels, state[index_key], 1)
        if sel ~= state[index_key] then
            state[index_key] = sel
            local item = bucket.items[sel]
            if item then
                apply_mesh(bucket.parts, item.id, item.label, item.sid)
            end
        end
    end, title ~= "Clothing")
end

function Appearance.draw(ui)
    ensure_catalog()
    ui.muted("Pick a mesh. DLC skins only work for DLC you own.")
    draw_mesh_picker(ui, "Sword", catalog.sword, "sword_i")
    draw_mesh_picker(ui, "Haori Coat", catalog.cloak, "cloak_i")
    draw_mesh_picker(ui, "Clothing", catalog.body, "body_i")
end

function Appearance.reset()
    state.ready = false
    state.named = false
    catalog.sword.items = {}
    catalog.cloak.items = {}
    catalog.body.items = {}
    refresh_all_labels()
end

_G.OnimushaAppearance = Appearance
return Appearance
end)()
end

-- reframework/autorun/give.lua
do
(function()
-- Give tab: ItemData master table, same Type groups as the pause Items tab.
-- _Category is CATEGORY_Fixed. Grant via SaveDataHelper_Item.addItem.

local Give = {}

local try_call, try_field, try_any, try_static, is_managed, enum_value
local get_item_helper, log_action

local CAT_SKIP = {
    INVALID = true,
    VIRTUAL = true,
    MAX = true,
}

-- Pause Items tab groups, plus Genma Notes (picture book / portraits).
-- Pouches and skins stay omitted.
local CAT_OMIT = {
    MEDICINE_BAG = true,
    APPEARANCE_CHANGE = true,
}

local UI_CAT = {
    { "items", "Items" },
    { "materials", "Materials" },
    { "offerings", "Offerings" },
    { "valuables", "Valuables" },
    { "genma_notes", "Genma Notes" },
}

local UI_KEYS = {
    all = true,
    items = true,
    materials = true,
    offerings = true,
    valuables = true,
    genma_notes = true,
}

local ENGINE_TO_UI = {
    equipable = "items",
    growth_material = "materials",
    medicine_bag_material = "materials",
    tribute = "offerings",
    important = "valuables",
    picture_book = "genma_notes",
}

local AMOUNT_OPTIONS = {
    { 1, "1" },
    { 5, "5" },
    { 10, "10" },
    { 50, "50" },
    { 99, "99" },
}

local items = {}
local visible = { items = {}, labels = {} }
local cat_options = { { "all", "All" } }
local cat_seq = {}
local cat_fixed = {}
local seq_to_enum = {}
local fixed_to_seq = {}
local fixed_to_enum = {}

local state = {
    ready = false,
    named = false,
    name_tries = 0,
    category = "all",
    selected = 0,
    amount = 1,
    drop = { open = false, filter = "" },
}

function Give.bind(deps)
    deps = deps or {}
    try_call = deps.try_call
    try_field = deps.try_field
    try_any = deps.try_any
    try_static = deps.try_static
    is_managed = deps.is_managed
    enum_value = deps.enum_value
    get_item_helper = deps.get_item_helper
    log_action = deps.log_action
end

local function serial_int(obj)
    if type(obj) == "number" then
        return obj
    end
    if not is_managed(obj) then
        return nil
    end
    local value = try_any(obj, { "get_Value", "get_FixedValue" })
        or try_field(obj, "_Value")
        or try_field(obj, "value__")
    if type(value) == "number" then
        return value
    end
    return nil
end

local function foreach_managed(collection, visitor)
    if not is_managed(collection) then
        return
    end
    local size = try_any(collection, { "get_Count", "get_Length", "get_size" })
    if type(size) ~= "number" then
        local ok, n = pcall(function()
            return collection:get_size()
        end)
        if ok then
            size = n
        end
    end
    if type(size) ~= "number" then
        return
    end
    for i = 0, size - 1 do
        local item = try_call(collection, "get_Item", i)
        if item == nil then
            local ok, value = pcall(function()
                return collection[i]
            end)
            if ok then
                item = value
            end
        end
        if item == nil then
            local ok, value = pcall(function()
                return collection:get_element(i)
            end)
            if ok then
                item = value
            end
        end
        if item ~= nil then
            visitor(item)
        end
    end
end

local function get_various_setting()
    local vdm = sdk.get_managed_singleton("app.VariousDataManager")
    return try_any(vdm, { "get_Setting" }) or try_field(vdm, "_Setting")
end

local function managed_string(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    if not is_managed(value) then
        return nil
    end
    local text = try_call(value, "ToString")
    if type(text) == "string" and text ~= "" and text ~= "System.String" then
        return text
    end
    return nil
end

local function guid_text(guid)
    if guid == nil then
        return nil
    end
    local td = sdk.find_type_definition("app.MessageUtil")
    local method = td and (td:get_method("getText(System.Guid)") or td:get_method("getText"))
    if method then
        local ok, text = pcall(function()
            return method:call(nil, guid)
        end)
        if ok then
            return managed_string(text)
        end
    end
    return nil
end

local function strip_markup(name)
    if type(name) ~= "string" then
        return ""
    end
    local text = name
        :gsub("</?%s*[Cc][Oo][Ll][Oo][Rr][^>]*>", "")
        :gsub("</?%s*[%w_]+[^>]*>", "")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    return text
end

local function is_rejected_name(name)
    local text = strip_markup(name)
    if text == "" then
        return false
    end
    if text:find("#Rejected#", 1, true) then
        return true
    end
    if text:find("ItemData", 1, true) then
        return true
    end
    return false
end

local function is_placeholder_name(name)
    local text = strip_markup(name)
    if text == "" then
        return true
    end
    if is_rejected_name(text) then
        return true
    end
    if text == "No Name" or text == "None" or text == "INVALID" then
        return true
    end
    if text:find("アイテム名が設定されていません", 1, true) then
        return true
    end
    local lower = text:lower()
    if lower:find("item name is not set", 1, true) then
        return true
    end
    return false
end

local function lookup_name(item_id)
    item_id = serial_int(item_id) or item_id
    if type(item_id) ~= "number" or item_id == 0 then
        return nil
    end
    local name = strip_markup(managed_string(try_static("app.ItemUtil", { "getItemName" }, item_id)))
    if name ~= "" and not is_placeholder_name(name) then
        return name
    end
    local data = try_static("app.ItemUtil", { "getData" }, item_id)
    local guid = try_any(data, { "get_NameGuid" }) or try_field(data, "_NameGuid")
    name = strip_markup(guid_text(guid))
    if name ~= "" and not is_placeholder_name(name) then
        return name
    end
    return nil
end

local function item_name(item_id, fixed_id)
    return lookup_name(item_id) or lookup_name(fixed_id)
end

local function pretty_enum_name(enum_name)
    if type(enum_name) ~= "string" then
        return "Item"
    end
    local label = enum_name
        :gsub("^PLGROWTH_", "Growth ")
        :gsub("^CONSUME_", "Consume ")
        :gsub("^COLLECTION_", "Collection ")
        :gsub("^PLSKILL_", "Skill ")
        :gsub("^SWORDSKIN_", "Sword Skin ")
        :gsub("^BODYSKIN_", "Clothing Skin ")
        :gsub("^CLOAKSKIN_", "Haori Skin ")
        :gsub("^GAUNTLETSKIN_", "Gauntlet Skin ")
        :gsub("^NPCSKIN_", "NPC Skin ")
        :gsub("^DLC_SWORDSKIN_", "Sword Skin DLC ")
        :gsub("^DLC_CLOAKSKIN_", "Haori Skin DLC ")
        :gsub("^DLC_BODYSKIN_", "Clothing Skin DLC ")
        :gsub("^DLC_GAUNTLETSKIN_", "Gauntlet Skin DLC ")
        :gsub("^DLC_NPCSKIN_", "NPC Skin DLC ")
        :gsub("^ENEMYBOOK_", "Enemy Book ")
        :gsub("^TREASUREMAP_", "Treasure Map ")
        :gsub("^MEDICINE_BAG", "Medicine Bag")
        :gsub("^STAGE", "Stage ")
        :gsub("_", " ")
    return label
end

local function category_from_enum_name(name)
    if type(name) ~= "string" then
        return nil
    end
    if name:find("^VIRTUAL_") then
        return "skip"
    end
    if name:find("^ENEMYBOOK_") then
        return "picture_book"
    end
    if name:find("SKIN") or name:find("^DLC_") then
        return "appearance_change"
    end
    if name:find("^MEDICINE_BAG") or name == "MEDICINE" then
        return "skip"
    end
    if name:find("^PLGROWTH_") or name:find("^PLSKILL_") then
        return "growth_material"
    end
    if name:find("^CONSUME_") then
        return "equipable"
    end
    if name:find("^COLLECTION_") then
        return "tribute"
    end
    if name:find("^STAGE") or name:find("^TREASUREMAP") or name:find("^event_") then
        return "important"
    end
    return nil
end

local function enum_entries(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        return {}
    end
    local ok, fields = pcall(function()
        return td:get_fields()
    end)
    if not ok or not fields then
        return {}
    end
    local out = {}
    for _, field in ipairs(fields) do
        local name = field.get_name and field:get_name()
        if type(name) == "string" and name ~= "value__" then
            local ok_val, value = pcall(function()
                return field:get_data(nil)
            end)
            if ok_val and type(value) == "number" then
                table.insert(out, { name = name, id = value })
            end
        end
    end
    table.sort(out, function(a, b)
        return a.name < b.name
    end)
    return out
end

local function map_category(dest, type_name, name, key)
    local value = enum_value(type_name, name)
    if type(value) == "number" then
        dest[value] = key
    end
end

local function ui_category(item_or_key)
    local key = item_or_key
    if type(item_or_key) == "table" then
        key = item_or_key.category
    end
    return ENGINE_TO_UI[key]
end

local function is_omitted_cat(category)
    return category == "skip" or (category ~= nil and ENGINE_TO_UI[category] == nil)
end

local function build_category_maps()
    cat_options = { { "all", "All" } }
    cat_seq = {}
    cat_fixed = {}
    for _, row in ipairs(UI_CAT) do
        table.insert(cat_options, row)
    end
    local order = {
        "EQUIPABLE",
        "IMPORTANT",
        "TRIBUTE",
        "GROWTH_MATERIAL",
        "MEDICINE_BAG_MATERIAL",
        "PICTURE_BOOK",
    }
    for _, name in ipairs(order) do
        local key = name:lower()
        map_category(cat_seq, "app.ItemEnum.CATEGORY", name, key)
        map_category(cat_fixed, "app.ItemEnum.CATEGORY_Fixed", name, key)
    end
    for name, _ in pairs(CAT_SKIP) do
        map_category(cat_seq, "app.ItemEnum.CATEGORY", name, "skip")
        map_category(cat_fixed, "app.ItemEnum.CATEGORY_Fixed", name, "skip")
    end
    for name, _ in pairs(CAT_OMIT) do
        map_category(cat_seq, "app.ItemEnum.CATEGORY", name, "skip")
        map_category(cat_fixed, "app.ItemEnum.CATEGORY_Fixed", name, "skip")
    end
end

-- ItemData._Category is CATEGORY_Serializable: _Value / get_Value is CATEGORY_Fixed.
-- EQUIPABLE_Fixed=0 and IMPORTANT_Fixed=1 collide with sequential INVALID/EQUIPABLE.
-- Resolve Fixed first, then sequential 0-10.
local function category_from_int(value)
    if type(value) ~= "number" then
        return nil
    end
    if cat_fixed[value] then
        return cat_fixed[value]
    end
    if value >= 0 and value <= 10 then
        return cat_seq[value]
    end
    return nil
end

local function category_key(value)
    if type(value) == "number" then
        return category_from_int(value)
    end
    if not is_managed(value) then
        return nil
    end
    local fixed = try_any(value, { "get_FixedValue" })
        or try_field(value, "_Value")
        or try_any(value, { "get_Value" })
    local key = category_from_int(fixed)
    if key then
        return key
    end
    return category_from_int(try_field(value, "value__"))
end

local function find_item(id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function item_kind(item)
    if type(item.id) == "number" and (fixed_to_seq[item.id] or item.id < 0 or item.id > 1000) then
        return "hash"
    end
    return "seq"
end

local function item_id(value)
    if type(value) == "number" then
        return value
    end
    if not is_managed(value) then
        return nil
    end
    local seq = try_any(value, { "get_Value" }) or try_field(value, "value__")
    if type(seq) == "number" then
        return seq
    end
    return serial_int(value)
end

local function resolve_enum(id, fixed)
    if type(id) == "number" and seq_to_enum[id] then
        return seq_to_enum[id]
    end
    if type(fixed) == "number" and fixed_to_enum[fixed] then
        return fixed_to_enum[fixed]
    end
    if type(id) == "number" and fixed_to_enum[id] then
        return fixed_to_enum[id]
    end
    return nil
end

local function catalog_remove(id)
    for i, item in ipairs(items) do
        if item.id == id then
            table.remove(items, i)
            return
        end
    end
end

local function catalog_add(id, label, category, max_count, named, fixed, enum_name)
    id = item_id(id) or id
    if type(id) ~= "number" then
        return
    end
    if is_omitted_cat(category) then
        catalog_remove(id)
        return
    end
    enum_name = enum_name or resolve_enum(id, fixed)
    local item = find_item(id)
    if item then
        -- Master table wins over enum-name guesses.
        if category then
            item.category = category
        end
        if type(max_count) == "number" and max_count > 0 then
            item.max_count = max_count
        end
        if type(fixed) == "number" then
            item.fixed = fixed
        end
        if enum_name and not item.enum_name then
            item.enum_name = enum_name
        end
        if label and (named or not item.named) then
            item.label = label
            if named then
                item.named = true
            end
        end
        return
    end
    table.insert(items, {
        id = id,
        fixed = (type(fixed) == "number") and fixed or nil,
        label = label or ("Item " .. tostring(id)),
        category = category,
        max_count = (type(max_count) == "number" and max_count > 0) and max_count or nil,
        named = named == true,
        enum_name = enum_name,
    })
end

local function fill_from_enum()
    -- Enum sequential IDs are kept for name maps. Grant uses ID_Fixed.
    seq_to_enum = {}
    fixed_to_seq = {}
    fixed_to_enum = {}
    local fixed_by_name = {}
    for _, entry in ipairs(enum_entries("app.ItemEnum.ID_Fixed")) do
        fixed_by_name[entry.name] = entry.id
        fixed_to_enum[entry.id] = entry.name
    end
    local invalid = enum_value("app.ItemEnum.ID", "INVALID")
    for _, entry in ipairs(enum_entries("app.ItemEnum.ID")) do
        seq_to_enum[entry.id] = entry.name
        local fixed = fixed_by_name[entry.name]
        if type(fixed) == "number" then
            fixed_to_seq[fixed] = entry.id
        end
        if entry.id ~= invalid then
            local category = category_from_enum_name(entry.name)
            catalog_add(entry.id, pretty_enum_name(entry.name), category, nil, false, fixed, entry.name)
        end
    end
end

local function get_item_master()
    local setting = get_various_setting()
    local master = try_any(setting, { "get_ItemData" }) or try_field(setting, "_ItemData")
    if is_managed(master) then
        return master
    end
    return nil
end

local function fill_from_table()
    local master = get_item_master()
    local list = try_call(master, "getValues")
        or try_any(master, { "get_Values" })
        or try_field(master, "_Values")
    local base = try_field(master, "_BaseItemData") or try_any(master, { "get_BaseItemData" })
    if not is_managed(list) then
        list = try_call(base, "getValues")
            or try_any(base, { "get_Values" })
            or try_field(base, "_Values")
    end
    local named = 0
    local function ingest(row)
        local id = item_id(try_any(row, { "get_Id" }) or try_field(row, "_Id"))
        local category = category_key(try_any(row, { "get_Category" }) or try_field(row, "_Category"))
        if not id or category == "skip" then
            return
        end
        local max_count = serial_int(try_any(row, { "get_MaxCountInit" }) or try_field(row, "_MaxCountInit"))
        local name = item_name(id)
        if not name then
            local guid = try_any(row, { "get_NameGuid" }) or try_field(row, "_NameGuid")
            name = guid_text(guid)
        end
        if is_rejected_name(name) then
            return
        end
        name = strip_markup(name)
        if is_placeholder_name(name) then
            name = nil
        end
        catalog_add(id, name, category, max_count, name ~= nil)
        local item = find_item(id)
        if item then
            local stock = serial_int(try_any(row, { "get_StockCount" }) or try_field(row, "_StockCount"))
            if type(stock) == "number" then
                item.stock = stock
            end
            local sort_id = serial_int(try_any(row, { "get_SortId" }) or try_field(row, "_SortId"))
            if type(sort_id) == "number" then
                item.sort_id = sort_id
            end
        end
        if name then
            named = named + 1
        end
    end
    if is_managed(list) then
        foreach_managed(list, ingest)
    else
        local n = try_call(master, "getDataNum") or try_call(base, "getDataNum")
        if type(n) == "number" then
            for i = 0, n - 1 do
                ingest(try_call(master, "getDataByIndex", i) or try_call(base, "getDataByIndex", i))
            end
        end
    end
    return named
end

-- Skins / books / keys often have MaxCountInit 1. addItem is for stacks.
local UNIQUE_CAT = {
    appearance_change = true,
}

local function is_unique_enum(enum_name)
    if type(enum_name) ~= "string" then
        return false
    end
    if enum_name:find("SKIN", 1, true) or enum_name:find("^DLC_") then
        return true
    end
    return false
end

local function is_stackable(item)
    if not item then
        return false
    end
    -- addItem / getItemCountOfId use ID_Fixed. Sequential enum ids return
    -- added=amount and 0->0. Keep the hash row only.
    if item_kind(item) ~= "hash" then
        return false
    end
    if item.category == "medicine_bag" then
        return false
    end
    if UNIQUE_CAT[item.category] or is_unique_enum(item.enum_name) then
        return false
    end
    local max = item.max_count
    return type(max) == "number" and max > 1
end

-- Hash rows the pause Items tab can show, plus Genma Notes.
local function is_listable(item)
    if not item then
        return false
    end
    if item_kind(item) ~= "hash" then
        return false
    end
    if not ui_category(item) then
        return false
    end
    if is_rejected_name(item.label) or is_placeholder_name(item.label) then
        return false
    end
    return true
end

local function item_less(a, b)
    local sa = type(a.sort_id) == "number" and a.sort_id or 999999
    local sb = type(b.sort_id) == "number" and b.sort_id or 999999
    if sa ~= sb then
        return sa < sb
    end
    return tostring(a.label or "") < tostring(b.label or "")
end

-- addItem runs execSpecialItemObtainEffect → activateAndEquipSkill.
-- That AVs in the skill-tree cache if the node is not ready.
local function is_skill_obtain(item)
    if not item then
        return false
    end
    if item.category == "growth_material" then
        return true
    end
    local name = item.enum_name
    if type(name) == "string" and (name:find("^PLSKILL_", 1) or name:find("^PLGROWTH_", 1)) then
        return true
    end
    return false
end

local function is_story_item(item)
    if not item then
        return false
    end
    if item.category == "important" then
        return true
    end
    local name = item.enum_name
    if type(name) == "string" then
        if name:find("^STAGE") or name:find("^TREASUREMAP") or name:find("^event_") then
            return true
        end
    end
    local label = strip_markup(item.label)
    if label:find("Key", 1, true) then
        return true
    end
    return false
end

local function is_bulk_safe(item)
    return is_stackable(item) and not is_skill_obtain(item) and not is_story_item(item)
end

local function category_label()
    for _, opt in ipairs(cat_options) do
        if opt[1] == state.category then
            return opt[2]
        end
    end
    return "Category"
end

local function row_probe_text(item)
    local label = strip_markup(item.label)
    local kind = "seq"
    if type(item.id) == "number" and (item.id < 0 or item.id > 1000) then
        kind = "hash"
    end
    if type(item.id) == "number" and fixed_to_seq[item.id] then
        kind = "hash"
    end
    return string.format(
        "%s | id=%s kind=%s fixed=%s seq=%s cat=%s enum=%s max=%s stock=%s named=%s",
        label,
        tostring(item.id),
        kind,
        tostring(item.fixed),
        tostring(fixed_to_seq[item.id] or item.id),
        tostring(item.category),
        tostring(item.enum_name or resolve_enum(item.id, item.fixed) or ""),
        tostring(item.max_count),
        tostring(item.stock),
        tostring(item.named)
    )
end

local function probe_duplicates()
    if state.dup_probed then
        return
    end
    state.dup_probed = true
    local keep = 0
    local skip_max = 0
    local skip_cat = 0
    local ui = { items = 0, materials = 0, offerings = 0, valuables = 0, genma_notes = 0 }
    for _, item in ipairs(items) do
        local key = ui_category(item)
        if is_listable(item) then
            keep = keep + 1
            if ui[key] then
                ui[key] = ui[key] + 1
            end
        elseif UNIQUE_CAT[item.category] or is_unique_enum(item.enum_name) then
            skip_cat = skip_cat + 1
        else
            skip_max = skip_max + 1
        end
    end
    log.info(string.format(
        "[onimusha] give-ui keep=%d items=%d mats=%d offer=%d val=%d notes=%d skip_unique=%d skip_other=%d rows=%d",
        keep,
        ui.items,
        ui.materials,
        ui.offerings,
        ui.valuables,
        ui.genma_notes,
        skip_cat,
        skip_max,
        #items
    ))
end

local function probe_shown(filter)
    filter = type(filter) == "string" and filter or ""
    local key = tostring(state.category) .. "|" .. filter:lower() .. "|" .. tostring(#visible.items)
    if state.drop._probe_key == key then
        return
    end
    state.drop._probe_key = key
    local needle = filter:lower()
    local n = 0
    for _, item in ipairs(visible.items) do
        local label = strip_markup(item.label)
        if needle == "" or label:lower():find(needle, 1, true) then
            n = n + 1
            log.info("[onimusha] give-row " .. row_probe_text(item))
        end
    end
    log.info(string.format("[onimusha] give-shown n=%d filter=%q cat=%s", n, filter, tostring(state.category)))
end

local function pouch_level(enum_name)
    if type(enum_name) ~= "string" then
        return nil
    end
    return enum_name:match("LV0*(%d+)$")
end

local function disambiguate_labels()
    local by_label = {}
    for _, item in ipairs(items) do
        local label = strip_markup(item.label)
        if label ~= "" then
            by_label[label] = by_label[label] or {}
            table.insert(by_label[label], item)
        end
    end
    for label, group in pairs(by_label) do
        if #group < 2 then
            -- only one row, nothing to split
        else
            local seen = {}
            local unique = 0
            for _, item in ipairs(group) do
                local key = item.enum_name or tostring(item.id)
                if not seen[key] then
                    seen[key] = true
                    unique = unique + 1
                end
            end
            if unique > 1 then
                for _, item in ipairs(group) do
                    local lv = pouch_level(item.enum_name)
                    if lv then
                        item.label = label .. " Lv" .. lv
                    end
                end
            end
        end
    end
end

local function refresh_visible()
    visible.items = {}
    visible.labels = {}
    for _, item in ipairs(items) do
        local ui_cat = ui_category(item)
        if ui_cat
            and (state.category == "all" or ui_cat == state.category)
            and is_listable(item)
        then
            table.insert(visible.items, item)
            table.insert(visible.labels, strip_markup(item.label))
        end
    end
    if state.selected > #visible.items then
        state.selected = 0
    end
end

local function named_count()
    local n = 0
    for _, item in ipairs(items) do
        if item.named then
            n = n + 1
        end
    end
    return n
end

local function refresh_names()
    local before = named_count()
    for _, item in ipairs(items) do
        if item.named and is_rejected_name(item.label) then
            item.named = false
        end
        if not item.named then
            local name = item_name(item.id, item.fixed)
            if name then
                item.label = name
                item.named = true
            end
        end
    end
    fill_from_table()
    local after = named_count()
    if after > before then
        disambiguate_labels()
        table.sort(items, item_less)
    end
    refresh_visible()
    state.name_tries = (state.name_tries or 0) + 1
    if after == #items or state.name_tries > 90 then
        state.named = true
        probe_duplicates()
    end
end

local function build_catalog()
    items = {}
    build_category_maps()
    fill_from_enum()
    fill_from_table()
    disambiguate_labels()
    table.sort(items, item_less)
    refresh_visible()
end

local function ensure_catalog()
    if not state.ready or #items == 0 then
        build_catalog()
        state.ready = #items > 0
    end
    if not state.named then
        refresh_names()
    end
end

local function find_method_arity(td, name, arity)
    if not td or not td.get_methods then
        return nil
    end
    local methods = td:get_methods()
    if not methods then
        return nil
    end
    for _, method in ipairs(methods) do
        if method.get_name and method:get_name() == name then
            local n = method.get_num_params and method:get_num_params()
            if n == arity then
                return method
            end
        end
    end
    return nil
end

local function helper_method(helper, signatures, ...)
    local td = sdk.find_type_definition("app.SaveDataHelper_Item")
    if not td or not helper then
        return nil
    end
    local n = select("#", ...)
    local a, b, c, d, e = ...
    for _, sig in ipairs(signatures) do
        local method = td:get_method(sig)
        if not method and type(sig) == "string" then
            local name, arity = sig:match("^([%w_]+)#(%d+)$")
            if name and arity then
                method = find_method_arity(td, name, tonumber(arity))
            end
        end
        if method then
            local ok, result = pcall(function()
                if n >= 5 then
                    return method:call(helper, a, b, c, d, e)
                end
                if n >= 4 then
                    return method:call(helper, a, b, c, d)
                end
                if n >= 3 then
                    return method:call(helper, a, b, c)
                end
                if n >= 2 then
                    return method:call(helper, a, b)
                end
                if n >= 1 then
                    return method:call(helper, a)
                end
                return method:call(helper)
            end)
            if ok then
                return result
            end
        end
    end
    return nil
end

local function item_count(helper, id)
    if type(id) ~= "number" then
        return nil
    end
    local n = helper_method(helper, {
        "getItemCountOfId(System.Int32)",
        "getItemCountOfId",
    }, id)
    if type(n) == "number" then
        return n
    end
    return try_call(helper, "getItemCountOfId", id)
end

local function extra_param()
    local ok, obj = pcall(function()
        return sdk.create_instance("app.ItemUtil.cIdAmountPair.cAdditionalParam")
    end)
    if ok and obj then
        return obj
    end
    return nil
end

local function try_box(helper, id, amount)
    return helper_method(helper, {
        "addItemToBox(System.Int32, System.UInt32)",
        "addItemToBox#2",
        "addItemToBox",
    }, id, amount)
end

-- Inventory count only. Does not run obtain / skill / objective.
local function try_add_num(helper, id, amount)
    local data = helper_method(helper, {
        "getItem(System.Int32)",
        "getItem#1",
        "getItem",
    }, id)
    if not is_managed(data) then
        return nil
    end
    return helper_method(helper, {
        "addItemNum(app.SaveDataHelper_Item.cItemData, System.UInt32)",
        "addItemNum#2",
        "addItemNum",
    }, data, amount)
end

local function count_grew(before, after)
    return type(before) == "number" and type(after) == "number" and after > before
end

local function try_add(helper, id, amount, notify)
    -- Family addItem is 5 args. REF invoke requires every param, including optionals.
    if notify == nil then
        notify = true
    end
    local extra = extra_param()
    local added = nil
    for _, force in ipairs({ true, false }) do
        added = helper_method(helper, {
            "addItem(System.Int32, System.UInt32, System.Boolean, System.Boolean, app.ItemUtil.cIdAmountPair.cAdditionalParam)",
            "addItem#5",
        }, id, amount, notify, force, extra)
        if type(added) == "number" and added > 0 then
            return added
        end
    end
    helper_method(helper, {
        "addItemHasObtainNum(System.Int32, System.UInt32)",
        "addItemHasObtainNum#2",
    }, id, amount)
    added = helper_method(helper, {
        "addItem(System.Int32, System.UInt32, System.Boolean, System.Boolean, app.ItemUtil.cIdAmountPair.cAdditionalParam)",
        "addItem#5",
    }, id, amount, false, true, extra)
    if type(added) ~= "number" or added <= 0 then
        added = try_box(helper, id, amount)
    end
    return added
end

local function give_item(item, amount, notify)
    if not item then
        return false, "no item"
    end
    if item_kind(item) ~= "hash" then
        return false, "not hash"
    end
    local helper = get_item_helper and get_item_helper()
    if not is_managed(helper) then
        return false, "no item helper"
    end
    amount = tonumber(amount) or 1
    if amount < 1 then
        amount = 1
    end
    if item.max_count and item.max_count > 0 and amount > item.max_count then
        amount = item.max_count
    end

    local id = item.id
    local before = item_count(helper, id)
    local added = try_add_num(helper, id, amount)
    local after = item_count(helper, id)
    -- New stacks have no cItemData yet. addItem creates the slot.
    -- Skip addItem for skill books — that AVs in activateAndEquipSkill.
    if not count_grew(before, after) and not is_skill_obtain(item) then
        added = try_add(helper, id, amount, notify)
        after = item_count(helper, id)
    end
    if not count_grew(before, after) and is_skill_obtain(item) then
        added = try_box(helper, id, amount)
        after = item_count(helper, id)
    end

    if item.category == "medicine_bag" then
        helper_method(helper, {
            "addDirectMedicineBag(System.Int32, System.Boolean)",
            "addDirectMedicineBag",
        }, id, notify == true)
    end

    after = item_count(helper, id)
    return count_grew(before, after), before, after, added, amount
end

local function give_selected()
    local item = visible.items[state.selected]
    if not item then
        log_action("give failed: no item")
        return
    end
    local amount = tonumber(state.amount) or 1
    local ok, before, after, added, used = give_item(item, amount, true)
    if type(before) == "number" and type(after) == "number" then
        log_action(
            "give "
                .. tostring(item.label)
                .. " x"
                .. tostring(used)
                .. " "
                .. tostring(before)
                .. "->"
                .. tostring(after)
                .. " added="
                .. tostring(added)
        )
        return
    end
    if not ok then
        log_action("give failed: addItem " .. tostring(item.label) .. " id=" .. tostring(item.id))
        return
    end
    log_action("give " .. tostring(item.label) .. " x" .. tostring(used) .. " id=" .. tostring(item.id))
end

local bulk = {
    active = false,
    queue = {},
    index = 0,
    ok = 0,
    fail = 0,
    label = "",
}

local function start_give_category()
    if state.category ~= "picture_book" then
        log_action("give all blocked: picture book only")
        return
    end
    bulk.queue = {}
    local skipped = 0
    for _, item in ipairs(visible.items) do
        if is_bulk_safe(item) then
            table.insert(bulk.queue, item)
        else
            skipped = skipped + 1
        end
    end
    bulk.index = 0
    bulk.ok = 0
    bulk.fail = 0
    bulk.label = category_label()
    bulk.active = #bulk.queue > 0
    if not bulk.active then
        log_action("give all " .. bulk.label .. " failed: empty list skip=" .. tostring(skipped))
        return
    end
    log_action("give all " .. bulk.label .. " start n=" .. tostring(#bulk.queue) .. " skip=" .. tostring(skipped))
end

function Give.busy()
    return bulk.active == true
end

function Give.tick()
    if not bulk.active then
        return
    end
    bulk.index = bulk.index + 1
    local item = bulk.queue[bulk.index]
    if not item then
        bulk.active = false
        log_action(string.format(
            "give all %s done ok=%s fail=%s",
            bulk.label,
            tostring(bulk.ok),
            tostring(bulk.fail)
        ))
        return
    end
    log_action(string.format(
        "give all %s %d/%d %s id=%s",
        bulk.label,
        bulk.index,
        #bulk.queue,
        tostring(item.label),
        tostring(item.id)
    ))
    local call_ok, ok, before, after, added = pcall(give_item, item, 1, false)
    if not call_ok then
        bulk.fail = bulk.fail + 1
        log_action("give all lua-fail " .. tostring(item.label) .. " " .. tostring(ok))
        return
    end
    if ok then
        bulk.ok = bulk.ok + 1
        if type(before) == "number" and type(after) == "number" then
            log_action(string.format(
                "give all ok %s %s->%s added=%s",
                tostring(item.label),
                tostring(before),
                tostring(after),
                tostring(added)
            ))
        end
        return
    end
    bulk.fail = bulk.fail + 1
    log_action("give all miss " .. tostring(item.label) .. " id=" .. tostring(item.id))
end

function Give.draw(ui)
    local catalog_ok, catalog_err = pcall(ensure_catalog)
    if not catalog_ok then
        ui.muted("Item list failed: " .. tostring(catalog_err))
        return
    end
    ui.muted("Best effort. Most items can be added. Some will not add if they have story requirements.")
    if #items == 0 then
        ui.muted("Waiting for item list.")
        return
    end

    if not UI_KEYS[state.category] then
        state.category = "all"
        state.selected = 0
        refresh_visible()
    end
    local cat_changed = ui.bind_combo("Category", state, "category", cat_options)
    if cat_changed then
        state.selected = 0
        state.amount = 1
        state.drop.open = false
        state.drop.filter = ""
        refresh_visible()
    end

    if #visible.labels == 0 then
        if not state.named then
            ui.muted("Waiting for item list.")
        else
            ui.muted("No items in this category.")
        end
        return
    end

    ui.label("Item")
    if state.drop.open then
        probe_shown(state.drop.filter)
    end
    local pick = visible.items[state.selected]
    local caption = pick and pick.label or "Pick..."
    local sel = ui.filter_dropdown("give_item", caption, visible.labels, state.selected, state.drop, {
        header = "Items",
        placeholder = "Pick...",
        height = 240,
    })
    if sel ~= state.selected then
        state.selected = sel
        state.amount = 1
        pick = visible.items[state.selected]
    end

    ui.bind_combo("Amount", state, "amount", AMOUNT_OPTIONS)

    if pick then
        if ui.button("Give " .. pick.label) then
            local amount = tonumber(state.amount) or 1
            local warn = "Best effort. Writes the save."
            if is_story_item(pick) then
                warn = "Story / key item. May not add if the story is not ready. Can skip objectives if it does."
            end
            ui.confirm({
                title = "Give item?",
                lines = {
                    "Give " .. pick.label .. " x" .. tostring(amount) .. "?",
                    warn,
                },
                yes = "Give",
                no = "Cancel",
                on_yes = function()
                    state.amount = amount
                    give_selected()
                end,
            })
        end
    else
        ui.muted("Pick an item, then Give.")
    end

    if bulk.active then
        imgui.spacing()
        ui.muted(string.format(
            "Give all %s %d/%d  ok=%d  fail=%d",
            bulk.label,
            bulk.index,
            #bulk.queue,
            bulk.ok,
            bulk.fail
        ))
    end
end

function Give.reset()
    bulk.active = false
    bulk.queue = {}
    bulk.index = 0
    bulk.ok = 0
    bulk.fail = 0
    bulk.label = ""
    state.ready = false
    state.named = false
    state.name_tries = 0
    state.drop.open = false
    state.drop.filter = ""
    state.drop._probe_key = nil
    state.dup_probed = false
    items = {}
    refresh_visible()
end

_G.OnimushaGive = Give
return Give
end)()
end

-- reframework/autorun/main.lua
do
(function()
-- Onimusha: Way of the Sword QOL on RefShell.
-- ~ toggles. Cursor lock uses the refcursor plugin when present.

local RefShell = _G.RefShell
if not RefShell then
    local ok, mod = pcall(require, "refshell")
    if ok then
        RefShell = mod
    end
end

if not RefShell then
    log.error("[onimusha] refshell missing — run npm run bundle (inlines ../REFrameworkRefShell)")
    return
end

local COL_OK = 0xFF6EE66E
local COL_WAIT = 0xFF66C8E6

local features = {
    god_mode = false,
    inf_health = false,
    inf_stamina = false,
    inf_oni_power = false,
    inf_oni_change = false,
    inf_items = false,
    easier_issen = false,
    always_issen = false,
    always_deflect = false,
    auto_absorb = false,
    soul_mult_on = false,
    soul_mult = 2.0,
    god_mode_vk = 0,
    inf_health_vk = 0,
    inf_stamina_vk = 0,
    inf_oni_power_vk = 0,
    inf_oni_change_vk = 0,
    inf_items_vk = 0,
    easier_issen_vk = 0,
    always_issen_vk = 0,
    always_deflect_vk = 0,
    auto_absorb_vk = 0,
    soul_mult_on_vk = 0,
    issen_split = false,
}

local menu

local runtime = {
    last_log = "(none)",
    hooked = false,
    player = "—",
    hp = nil,
    max_hp = nil,
    stamina = nil,
    max_stamina = nil,
    oni = nil,
    max_oni = nil,
    oni_change = nil,
    max_oni_change = nil,
    god_was_on = false,
    health_was_on = false,
    stamina_was_on = false,
    oni_was_on = false,
    oni_change_was_on = false,
    items_was_on = false,
    item_hooks = false,
    just_hooks = false,
    pouch = nil,
    god_hooks = false,
    absorb_hooks = false,
    absorb_was_on = false,
    souls_ready = false,
    soul_hooks = false,
}

local function log_action(text)
    runtime.last_log = text
    local L = RefShell and RefShell.Log
    if L and L.info then
        L.info("onimusha", text)
        return
    end
    log.info("[onimusha] " .. text)
end

local function try_call(obj, name, ...)
    if not obj then
        return nil
    end
    local n = select("#", ...)
    local a, b, c, d, e = ...
    local ok, result = pcall(function()
        if n >= 5 then
            return obj:call(name, a, b, c, d, e)
        end
        if n >= 4 then
            return obj:call(name, a, b, c, d)
        end
        if n >= 3 then
            return obj:call(name, a, b, c)
        end
        if n >= 2 then
            return obj:call(name, a, b)
        end
        if n >= 1 then
            return obj:call(name, a)
        end
        return obj:call(name)
    end)
    if ok then
        return result
    end
    return nil
end

local function enum_value(type_name, field_name)
    local td = sdk.find_type_definition(type_name)
    if not td then
        return nil
    end
    local field = td:get_field(field_name)
    if not field then
        return nil
    end
    local ok, value = pcall(function()
        return field:get_data(nil)
    end)
    if ok then
        return value
    end
    return nil
end

local function try_field(obj, name)
    if not obj then
        return nil
    end
    local ok, result = pcall(function()
        return obj:get_field(name)
    end)
    if ok then
        return result
    end
    return nil
end

local function obj_type(obj)
    if obj == nil then
        return "nil"
    end
    local ok, td = pcall(function()
        return obj:get_type_definition()
    end)
    if ok and td then
        local ok_name, name = pcall(function()
            return td:get_full_name()
        end)
        if ok_name and name then
            return name
        end
    end
    return type(obj)
end

local function try_any(obj, names, ...)
    if not obj then
        return nil
    end
    for _, name in ipairs(names) do
        local result = try_call(obj, name, ...)
        if result ~= nil then
            return result
        end
    end
    return nil
end

local function try_static(type_name, names, ...)
    local td = sdk.find_type_definition(type_name)
    if not td then
        return nil
    end
    local a = ...
    for _, name in ipairs(names) do
        local method = td:get_method(name)
        if method then
            local ok, result = pcall(function()
                if a ~= nil then
                    return method:call(nil, a)
                end
                return method:call(nil)
            end)
            if ok and result ~= nil then
                return result
            end
        end
    end
    return nil
end

local function is_managed(obj)
    if obj == nil then
        return false
    end
    local ok, td = pcall(function()
        return obj:get_type_definition()
    end)
    return ok and td ~= nil
end

local function to_managed(ptr)
    if ptr == nil then
        return nil
    end
    local ok, obj = pcall(sdk.to_managed_object, ptr)
    if ok and obj ~= nil then
        return obj
    end
    return nil
end

local function is_type(obj, name)
    if not is_managed(obj) then
        return false
    end
    local ok, td = pcall(function()
        return obj:get_type_definition()
    end)
    return ok and td and td:get_full_name() == name
end

local function get_player_info()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local info = try_any(pm, {
        "getControllingPlayer",
        "getControllingPlayerInfo",
        "getMasterPlayer",
        "get_MasterPlayer",
    })
    if is_managed(info) then
        return info
    end
    return nil
end

local function get_player_character(info)
    local chara = try_static("app.PlayerUtil", { "getControllingPlayerCharacter" })
    if is_managed(chara) then
        return chara
    end
    info = info or get_player_info()
    chara = try_any(info, { "get_Character", "get_Hunter" })
    if is_managed(chara) then
        return chara
    end
    return nil
end

local function get_player_entity(info)
    local entity = try_static("app.PlayerUtil", { "getControllingPlayerCharacterEntity" })
    if is_managed(entity) then
        return entity
    end
    info = info or get_player_info()
    entity = try_any(info, { "get_CharacterEntity" })
        or try_field(info, "<CharacterEntity>k__BackingField")
    if is_managed(entity) then
        return entity
    end
    local chara = get_player_character(info)
    entity = try_field(chara, "_PlayerCharacterEntity")
        or try_any(chara, { "get_PlayerCharacterEntity" })
    if is_managed(entity) then
        return entity
    end
    return nil
end

local function get_invincible(entity)
    entity = entity or get_player_entity()
    local inv = try_any(entity, { "get_InvincibleSupporter" })
        or try_field(entity, "<InvincibleSupporter>k__BackingField")
    if is_managed(inv) then
        return inv
    end
    return nil
end

local function find_health_on(obj)
    if not is_managed(obj) then
        return nil
    end
    local mgr = try_any(obj, { "get_HealthManager", "get_HealthMgr" })
        or try_field(obj, "<HealthManager>k__BackingField")
    if is_managed(mgr) then
        return mgr
    end
    return nil
end

local function get_health_mgr(info)
    info = info or get_player_info()
    local mgr = find_health_on(info)
        or find_health_on(get_player_character(info))
        or find_health_on(get_player_entity(info))
    if mgr then
        return mgr
    end

    local chara = get_player_character(info)
    mgr = find_health_on(try_any(chara, { "get_Context", "get_ContextParam", "get_Param" }))
    if mgr then
        return mgr
    end

    local holder = try_any(info, { "get_ContextHolder" })
        or try_field(info, "_ContextHolder")
        or try_any(chara, { "get_ContextHolder" })
        or try_field(chara, "_ContextHolder")
    mgr = find_health_on(holder)
        or find_health_on(try_field(holder, "_ContextCore"))
        or find_health_on(try_any(holder, { "get_ContextCore" }))
    if mgr then
        return mgr
    end

    local contexts = try_field(holder, "Contexts") or try_any(holder, { "get_Contexts" })
    if contexts then
        local ok, n = pcall(function()
            return contexts:get_size()
        end)
        if ok and type(n) == "number" then
            for i = 0, n - 1 do
                local ctx = nil
                pcall(function()
                    ctx = contexts:get_element(i)
                end)
                if ctx == nil then
                    pcall(function()
                        ctx = contexts[i]
                    end)
                end
                mgr = find_health_on(ctx)
                if mgr then
                    return mgr
                end
            end
        end
    end

    local go = try_static("app.PlayerUtil", { "getControllingPlayerGameObject" })
        or try_any(info, { "get_Object" })
        or try_field(info, "<Object>k__BackingField")
    local td = sdk.find_type_definition("app.cHealthManager")
    if go and td then
        local rt = nil
        pcall(function()
            rt = sdk.typeof("app.cHealthManager")
        end)
        if not rt then
            pcall(function()
                rt = td:get_runtime_type()
            end)
        end
        if rt then
            mgr = try_call(go, "getComponent(System.Type)", rt)
            if is_managed(mgr) then
                return mgr
            end
        end
    end
    return nil
end

local function read_hp()
    local mgr = get_health_mgr()
    if not mgr then
        return nil, nil
    end
    local hp = try_any(mgr, { "get_Health", "get_TotalHealth" })
    local max_hp = try_any(mgr, { "get_MaxHealth", "get_TotalMaxHealth" })
    if type(hp) == "number" and type(max_hp) == "number" then
        return hp, max_hp
    end
    return nil, nil
end

local function refill_health()
    local mgr = get_health_mgr()
    if not mgr then
        return false
    end
    local max_hp = try_any(mgr, { "get_MaxHealth", "get_TotalMaxHealth" })
    if type(max_hp) ~= "number" then
        return false
    end
    pcall(function()
        mgr:call("setHealth", max_hp)
    end)
    pcall(function()
        mgr:call("set_Health", max_hp)
    end)
    return true
end

local function no_hit_fixed()
    return enum_value("app.PlayerNoHitLevel.TYPE_Fixed", "NO_HIT") or 7308
end

local function set_no_damage(on)
    local inv = get_invincible()
    if not inv then
        return false
    end
    if on then
        local level = no_hit_fixed()
        pcall(function()
            inv:call("requestNoHit", level)
        end)
        pcall(function()
            inv:call("requestHighestNoHit")
        end)
        pcall(function()
            inv:set_field("_RequestNoHitLevel", level)
        end)
        pcall(function()
            inv:set_field("_CurrentNoHitLevel", level)
        end)
    else
        pcall(function()
            inv:set_field("_RequestNoHitLevel", 0)
        end)
        pcall(function()
            inv:set_field("_CurrentNoHitLevel", 0)
        end)
    end
    return true
end

local function is_player_invincible(this)
    if not this then
        return false
    end
    local ok, td = pcall(function()
        return this:get_type_definition()
    end)
    return ok and td and td:get_full_name() == "app.cPlayerInvincibleSupporter"
end

local function hook_check_no_hit(method)
    if not method then
        return
    end
    local force = false
    pcall(sdk.hook, method, function(args)
        force = false
        if not features.god_mode then
            return
        end
        if not is_player_invincible(to_managed(args[2])) then
            return
        end
        force = true
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function(retval)
        if force then
            return sdk.to_ptr(1)
        end
        return retval
    end)
end

local function install_god_hooks()
    if runtime.god_hooks then
        return
    end
    local player_td = sdk.find_type_definition("app.cPlayerInvincibleSupporter")
    if not player_td then
        return
    end
    runtime.god_hooks = true
    hook_check_no_hit(player_td:get_method("checkNoHit"))
    hook_check_no_hit(
        player_td:get_method("checkNoHit(app.PlayerNoHitLevel.TYPE_Fixed, app.HitInfo)")
    )
    local base_td = sdk.find_type_definition("app.cCharacterInvincibleSupporter")
    if base_td then
        hook_check_no_hit(base_td:get_method("checkNoHit"))
        hook_check_no_hit(base_td:get_method("checkNoHit(app.HitInfo)"))
    end
end

local function apply_god_mode(want)
    install_god_hooks()
    if want then
        local first = not runtime.god_was_on
        local ok = set_no_damage(true)
        refill_health()
        runtime.god_was_on = true
        if first and ok then
            log_action("god mode on")
        end
        return ok
    elseif runtime.god_was_on then
        set_no_damage(false)
        runtime.god_was_on = false
        log_action("god mode off")
    end
    return true
end

local function get_context_holder(info)
    info = info or get_player_info()
    local holder = try_any(info, { "get_ContextHolder" })
        or try_field(info, "_ContextHolder")
    if is_managed(holder) then
        return holder
    end
    local chara = get_player_character(info)
    holder = try_any(chara, { "get_ContextHolder" })
        or try_field(chara, "_ContextHolder")
    if is_managed(holder) then
        return holder
    end
    local entity = get_player_entity(info)
    holder = try_any(entity, { "get_ContextHolder" })
        or try_field(entity, "_ContextHolder")
    if is_managed(holder) then
        return holder
    end
    return nil
end

local function get_player_context(info)
    info = info or get_player_info()
    local ctx = try_any(info, { "get_Context", "get_ContextParam", "get_Param" })
    if is_type(ctx, "app.cPlayerContextParam") then
        return ctx
    end
    local chara = get_player_character(info)
    ctx = try_any(chara, { "get_Context", "get_ContextParam", "get_Param" })
    if is_type(ctx, "app.cPlayerContextParam") then
        return ctx
    end
    local holder = get_context_holder(info)
    ctx = try_any(holder, { "get_Player" })
    if is_type(ctx, "app.cPlayerContextParam") then
        return ctx
    end
    local contexts = try_field(holder, "Contexts") or try_any(holder, { "get_Contexts" })
    if contexts then
        local ok, n = pcall(function()
            return contexts:get_size()
        end)
        if ok and type(n) == "number" then
            for i = 0, n - 1 do
                local item = nil
                pcall(function()
                    item = contexts:get_element(i)
                end)
                if item == nil then
                    pcall(function()
                        item = contexts[i]
                    end)
                end
                if is_type(item, "app.cPlayerContextParam") then
                    return item
                end
            end
        end
    end
    return nil
end

local function read_oni()
    local ctx = get_player_context()
    if not ctx then
        return nil, nil
    end
    local cur = try_any(ctx, { "get_OniEnergy" })
        or try_field(ctx, "<OniEnergy>k__BackingField")
    local max_oni = try_any(ctx, { "get_OniEnergyMax" })
        or try_field(ctx, "<OniEnergyMax>k__BackingField")
    if type(cur) == "number" and type(max_oni) == "number" then
        return cur, max_oni
    end
    return nil, nil
end

local function refill_oni()
    local ctx = get_player_context()
    if not ctx then
        return false
    end
    local ok = pcall(function()
        ctx:call("setOniEnergyToMax")
    end)
    if ok then
        return true
    end
    local max_oni = try_any(ctx, { "get_OniEnergyMax" })
        or try_field(ctx, "<OniEnergyMax>k__BackingField")
    if type(max_oni) ~= "number" then
        return false
    end
    pcall(function()
        ctx:call("setOniEnergy", max_oni)
    end)
    pcall(function()
        ctx:set_field("<OniEnergy>k__BackingField", max_oni)
    end)
    return true
end

-- Purple souls fill OniChangeEnergy on the same context. Max = ultimate transform.
local function read_oni_change()
    local ctx = get_player_context()
    if not ctx then
        return nil, nil
    end
    local cur = try_any(ctx, { "get_OniChangeEnergy" })
        or try_field(ctx, "<OniChangeEnergy>k__BackingField")
    local max_chg = try_any(ctx, { "get_OniChangeEnergyMax" })
        or try_field(ctx, "<OniChangeEnergyMax>k__BackingField")
    if type(cur) == "number" and type(max_chg) == "number" then
        return cur, max_chg
    end
    return nil, nil
end

local function refill_oni_change()
    local ctx = get_player_context()
    if not ctx then
        return false
    end
    local max_chg = try_any(ctx, { "get_OniChangeEnergyMax" })
        or try_field(ctx, "<OniChangeEnergyMax>k__BackingField")
    if type(max_chg) ~= "number" then
        return false
    end
    local ok = pcall(function()
        ctx:call("setOniChangeEnergy", max_chg)
    end)
    if not ok then
        pcall(function()
            ctx:call("setOniChangeEnergy", max_chg, true)
        end)
        pcall(function()
            ctx:call("set_OniChangeEnergy", max_chg)
        end)
    end
    pcall(function()
        ctx:set_field("<OniChangeEnergy>k__BackingField", max_chg)
    end)
    return true
end

local function find_rikido_on(obj)
    if not is_managed(obj) then
        return nil
    end
    local sup = try_any(obj, { "get_RikidoSupporter" })
        or try_field(obj, "<RikidoSupporter>k__BackingField")
    if is_managed(sup) then
        return sup
    end
    return nil
end

local function get_rikido_supporter(info)
    info = info or get_player_info()
    local sup = find_rikido_on(get_player_entity(info))
        or find_rikido_on(get_player_character(info))
        or find_rikido_on(info)
        or find_rikido_on(get_player_context(info))
    if sup then
        return sup
    end
    local holder = get_context_holder(info)
    sup = find_rikido_on(holder)
        or find_rikido_on(try_any(holder, { "get_ContextCore" }))
        or find_rikido_on(try_field(holder, "_ContextCore"))
    if sup then
        return sup
    end
    local contexts = try_field(holder, "Contexts") or try_any(holder, { "get_Contexts" })
    if contexts then
        local ok, n = pcall(function()
            return contexts:get_size()
        end)
        if ok and type(n) == "number" then
            for i = 0, n - 1 do
                local ctx = nil
                pcall(function()
                    ctx = contexts:get_element(i)
                end)
                if ctx == nil then
                    pcall(function()
                        ctx = contexts[i]
                    end)
                end
                sup = find_rikido_on(ctx)
                if sup then
                    return sup
                end
            end
        end
    end
    return nil
end

local function get_rikido_gauge(sup)
    sup = sup or get_rikido_supporter()
    local gauge = try_any(sup, { "get_Guage", "get_Gauge", "get_Rikido" })
        or try_field(sup, "_Guage")
    if is_managed(gauge) then
        return gauge
    end
    return nil
end

local function read_stamina()
    local sup = get_rikido_supporter()
    if not sup then
        return nil, nil
    end
    local cur = try_any(sup, { "getRikidoValue" })
    local max_st = try_any(sup, { "getRikidoMaxValue" })
    local gauge = get_rikido_gauge(sup)
    if type(cur) ~= "number" then
        cur = try_any(gauge, { "get_CurrentValue" }) or try_field(gauge, "_CurrentValue")
    end
    if type(max_st) ~= "number" then
        max_st = try_any(gauge, { "get_MaxValue" }) or try_field(gauge, "_MaxValue")
    end
    if type(cur) == "number" and type(max_st) == "number" then
        return cur, max_st
    end
    return nil, nil
end

local function refill_stamina()
    local sup = get_rikido_supporter()
    if not sup then
        return false
    end
    pcall(function()
        sup:call("setRikidoValueFromRate", 1.0)
    end)
    local gauge = get_rikido_gauge(sup)
    local max_st = try_any(sup, { "getRikidoMaxValue" })
        or try_any(gauge, { "get_MaxValue" })
        or try_field(gauge, "_MaxValue")
    if type(max_st) == "number" then
        local value = math.floor(max_st + 0.5)
        pcall(function()
            gauge:call("setValue", value, true)
        end)
        pcall(function()
            gauge:set_field("_CurrentValue", value)
        end)
        pcall(function()
            sup:call("addRecoveryValue", value, true)
        end)
    end
    return true
end

local function apply_inf_health(want)
    if want then
        local first = not runtime.health_was_on
        local ok = refill_health()
        runtime.health_was_on = true
        if first and ok then
            log_action("infinite health on")
        end
        return ok
    elseif runtime.health_was_on then
        runtime.health_was_on = false
        log_action("infinite health off")
    end
    return true
end

local function apply_inf_stamina(want)
    if want then
        local first = not runtime.stamina_was_on
        local ok = refill_stamina()
        runtime.stamina_was_on = true
        if first and ok then
            log_action("infinite stamina on")
        end
        return ok
    elseif runtime.stamina_was_on then
        runtime.stamina_was_on = false
        log_action("infinite stamina off")
    end
    return true
end

local function apply_inf_oni(want)
    if want then
        local first = not runtime.oni_was_on
        local ok = refill_oni()
        runtime.oni_was_on = true
        if first and ok then
            log_action("oni power on")
        end
        return ok
    elseif runtime.oni_was_on then
        runtime.oni_was_on = false
        log_action("oni power off")
    end
    return true
end

local function apply_inf_oni_change(want)
    if want then
        local first = not runtime.oni_change_was_on
        local ok = refill_oni_change()
        runtime.oni_change_was_on = true
        if first and ok then
            log_action("oni change on")
        end
        return ok
    elseif runtime.oni_change_was_on then
        runtime.oni_change_was_on = false
        log_action("oni change off")
    end
    return true
end

local function get_item_helper()
    local sdm = sdk.get_managed_singleton("app.SaveDataManager")
    local helper = try_any(sdm, { "get_Helper", "get_SaveDataHelper" })
        or try_field(sdm, "_Helper")
    local item = try_any(helper, { "get_Item" }) or try_field(helper, "_Item")
    if is_type(item, "app.SaveDataHelper_Item") then
        return item
    end
    item = try_any(sdm, { "get_Item" }) or try_field(sdm, "_Item")
    if is_type(item, "app.SaveDataHelper_Item") then
        return item
    end
    return nil
end

local function read_pouch()
    -- ItemUtil.getHaveMedicineBag AVs on the title screen. Wait for a save helper.
    local helper = get_item_helper()
    if not helper then
        return nil
    end
    local bag_id = try_static("app.ItemUtil", { "getHaveMedicineBag" })
    if type(bag_id) ~= "number" or bag_id <= 0 then
        return nil
    end
    local count = try_call(helper, "getMedicineBagCount", bag_id)
    if type(count) == "number" then
        return count
    end
    return nil
end

local function refill_pouch()
    local ok = pcall(function()
        local td = sdk.find_type_definition("app.ItemUtil")
        local method = td and td:get_method("forceFullReloadHaveMedicineBag")
        if method then
            method:call(nil)
        end
    end)
    return ok
end

local function remaining_after_skip(args)
    local item = to_managed(args[3])
    if is_managed(item) then
        local n = try_any(item, { "get_EquipNum" })
            or try_field(item, "<EquipNum>k__BackingField")
        if type(n) == "number" then
            return n
        end
    end
    local this = to_managed(args[2])
    local id = sdk.to_int64(args[3])
    if this and type(id) == "number" then
        local data = try_call(this, "getItem", id)
        local n = try_any(data, { "get_EquipNum" })
            or try_field(data, "<EquipNum>k__BackingField")
        if type(n) == "number" then
            return n
        end
    end
    return 1
end

local function hook_skip_consume(method, returns_count)
    if not method then
        return
    end
    local force = false
    local remain = 1
    pcall(sdk.hook, method, function(args)
        force = false
        if not features.inf_items then
            return
        end
        force = true
        if returns_count then
            remain = remaining_after_skip(args)
        end
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function(retval)
        if force and returns_count then
            return sdk.to_ptr(remain)
        end
        return retval
    end)
end

local function install_item_hooks()
    if runtime.item_hooks then
        return
    end
    local td = sdk.find_type_definition("app.SaveDataHelper_Item")
    if not td then
        return
    end
    runtime.item_hooks = true
    hook_skip_consume(td:get_method("subItem"), true)
    hook_skip_consume(td:get_method("subItem(System.Int32, System.UInt32, System.Boolean)"), true)
    hook_skip_consume(td:get_method("subItemNum"), true)
    hook_skip_consume(
        td:get_method("subItemNum(app.SaveDataHelper_Item.cItemData, System.UInt32, System.Boolean)"),
        true
    )
    hook_skip_consume(td:get_method("subItemHasObtainNum"), false)
end

local function apply_inf_items(want)
    install_item_hooks()
    if want then
        local first = not runtime.items_was_on
        refill_pouch()
        runtime.items_was_on = true
        if first then
            log_action("infinite items on")
        end
        return true
    elseif runtime.items_was_on then
        runtime.items_was_on = false
        log_action("infinite items off")
    end
    return true
end

local JF_COUNTER_ISSEN = 0
local JF_BLOCK = 2
local GRADE_SUCCESS_GREAT = 1
local CHAIN_INPUT_SUCCESS = 1

local SOUL_MULT_OPTIONS = {
    { 1.0,  "1x" },
    { 1.5,  "1.5x" },
    { 2.0,  "2x" },
    { 3.0,  "3x" },
    { 5.0,  "5x" },
    { 10.0, "10x" },
}

local function as_float(value)
    local n = tonumber(value)
    if not n then
        return 1.0
    end
    return n
end

local function soul_scale()
    if not features.soul_mult_on then
        return 1.0
    end
    local n = as_float(features.soul_mult)
    if n <= 0 then
        return 1.0
    end
    return n
end

local function hook_force_bool(method, should_force, value)
    if not method then
        return
    end
    local force = false
    pcall(sdk.hook, method, function()
        force = false
        if not should_force() then
            return
        end
        force = true
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function(retval)
        if force then
            return sdk.to_ptr(value and 1 or 0)
        end
        return retval
    end)
end

local function just_type_from_args(args)
    local ok, value = pcall(function()
        return sdk.to_int64(args[3])
    end)
    if ok and value ~= nil then
        return tonumber(value)
    end
    return nil
end

local function get_guard_controller(entity)
    entity = entity or get_player_entity()
    local gc = try_any(entity, { "get_GuardController" })
        or try_field(entity, "<GuardController>k__BackingField")
    if is_managed(gc) then
        return gc
    end
    return nil
end

local function is_block_held(entity)
    entity = entity or get_player_entity()
    local gc = get_guard_controller(entity)
    if is_managed(gc) then
        if try_any(gc, { "get_IsGuard" }) then
            return true
        end
        if try_field(gc, "_IsGuardButton") then
            return true
        end
    end
    if try_any(entity, { "isGuardStance" }) then
        return true
    end
    return false
end

local function deflect_active(entity)
    return features.always_deflect and is_block_held(entity)
end

local function issen_assist()
    return features.easier_issen or features.always_issen
end

local function want_just_type(jf_type)
    if jf_type == JF_COUNTER_ISSEN then
        return issen_assist()
    end
    if jf_type == JF_BLOCK then
        return deflect_active()
    end
    return false
end

local function hook_check_grade(method)
    if not method then
        return
    end
    local force = false
    pcall(sdk.hook, method, function(args)
        force = false
        if want_just_type(just_type_from_args(args)) then
            force = true
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(retval)
        if force then
            return sdk.to_ptr(GRADE_SUCCESS_GREAT)
        end
        return retval
    end)
end

local function install_just_hooks()
    if runtime.just_hooks then
        return
    end
    runtime.just_hooks = true

    local jf = sdk.find_type_definition("app.cPlayerJustFrameUpdater")
    if jf then
        hook_check_grade(jf:get_method("checkGrade"))
        hook_check_grade(jf:get_method("checkGradeForShell"))
    end

    local sensor = sdk.find_type_definition("app.cPlayerIssenSensorController")
    if sensor then
        hook_force_bool(sensor:get_method("getIssenSuccess"), function()
            return issen_assist()
        end, true)
    end

    local guard = sdk.find_type_definition("app.cPlayerJustGuardSupporter")
    if guard then
        hook_force_bool(guard:get_method("isCheckJustGuard"), function()
            return deflect_active()
        end, true)
        hook_force_bool(guard:get_method("isCheckShellJustGuard"), function()
            return deflect_active()
        end, true)
        local grade = guard:get_method("getJustGuardGrade")
        if grade then
            local force = false
            pcall(sdk.hook, grade, function()
                force = false
                if not deflect_active() then
                    return
                end
                force = true
                return sdk.PreHookResult.SKIP_ORIGINAL
            end, function(retval)
                if force then
                    return sdk.to_ptr(GRADE_SUCCESS_GREAT)
                end
                return retval
            end)
        end
    end

    local chain = sdk.find_type_definition("app.cPlayerChainIssenSupporter")
    if chain then
        hook_force_bool(chain:get_method("isChainIssenDetectionInput"), function()
            return issen_assist()
        end, true)
        hook_force_bool(chain:get_method("isChainIssenStartActionSuccess"), function()
            return issen_assist()
        end, true)
        hook_force_bool(chain:get_method("isChainIssenFail"), function()
            return issen_assist()
        end, false)
    end
end

local function just_is_active(updater, jf_type)
    if not updater then
        return false
    end
    local active = false
    pcall(function()
        active = updater:call("isActive", jf_type) and true or false
    end)
    return active
end

local function hold_just_input(updater, jf_type)
    if not updater then
        return
    end
    if not just_is_active(updater, jf_type) then
        pcall(function()
            updater:call("enableParam", jf_type)
        end)
    end
    pcall(function()
        updater:call("forceEnableInput", jf_type)
    end)
    pcall(function()
        updater:call("setInputOn", jf_type)
    end)
end

local function get_issen_sensor(entity)
    entity = entity or get_player_entity()
    local sensor = try_any(entity, { "get_IssenSensor" })
        or try_field(entity, "<IssenSensor>k__BackingField")
    if is_managed(sensor) then
        return sensor
    end
    return nil
end

local function issen_has_target(entity)
    local sensor = get_issen_sensor(entity)
    if not is_managed(sensor) then
        return false
    end
    if try_any(sensor, { "getTargetContext" }) then
        return true
    end
    local info = try_any(sensor, { "get_SelectInfo" })
        or try_field(sensor, "<SelectInfo>k__BackingField")
    if not is_managed(info) then
        return false
    end
    return try_any(info, { "get_TargetObject", "get_TargetContext" }) ~= nil
end

local function poke_chain_issen(entity)
    local chain = try_any(entity, { "get_ChainIssenSuporter", "get_ChainIssenSupporter" })
        or try_field(entity, "<ChainIssenSuporter>k__BackingField")
    local detect = try_any(chain, {
        "isChainIssenDetectionStart",
        "isChainIssenDetectionInput",
    }) or try_field(chain, "IsDetection")
    if not detect then
        return
    end
    pcall(function()
        chain:set_field("_InputChainIssen", true)
        chain:set_field("_ChainIssenJustSuccessTiming", true)
        chain:set_field("_CounterIssenJustSuccess", true)
        chain:set_field("<InputState>k__BackingField", CHAIN_INPUT_SUCCESS)
    end)
end

local function apply_just_actions()
    install_just_hooks()
    if not (features.easier_issen or features.always_issen or features.always_deflect) then
        return
    end
    local entity = get_player_entity()
    local updater = try_any(entity, { "get_JustFrameUpdater" })
        or try_field(entity, "<JustFrameUpdater>k__BackingField")
    if features.always_issen and not is_block_held(entity) then
        if just_is_active(updater, JF_COUNTER_ISSEN) or issen_has_target(entity) then
            hold_just_input(updater, JF_COUNTER_ISSEN)
        end
        poke_chain_issen(entity)
    elseif features.easier_issen then
        poke_chain_issen(entity)
    end
    if deflect_active(entity) then
        hold_just_input(updater, JF_BLOCK)
    end
end

local function get_soul_absorption(info)
    local entity = get_player_entity(info)
    local sup = try_any(entity, { "get_SoulAbsorption" })
        or try_field(entity, "<SoulAbsorption>k__BackingField")
    if is_type(sup, "app.cPlayerSoulAbsorptionSupporter") then
        return sup
    end
    local chara = get_player_character(info)
    sup = try_any(chara, { "get_SoulAbsorption" })
        or try_field(chara, "<SoulAbsorption>k__BackingField")
    if is_type(sup, "app.cPlayerSoulAbsorptionSupporter") then
        return sup
    end
    return nil
end

local function get_equip_skill_cache(info)
    local entity = get_player_entity(info)
    local go = try_any(entity, { "get_GameObjectSupporter" })
        or try_field(entity, "<GameObjectSupporter>k__BackingField")
    local cache = try_any(go, { "get_EquipSkillCache" })
        or try_field(go, "_EquipSkillCache")
    if is_type(cache, "app.user_data.cPlayerEquipSkill") then
        return cache
    end
    return nil
end

local function list_count(list)
    if not is_managed(list) then
        return 0
    end
    local n = try_any(list, { "get_Count", "get_Size" })
    if type(n) == "number" then
        return n
    end
    local ok, size = pcall(function()
        return list:get_size()
    end)
    if ok and type(size) == "number" then
        return size
    end
    return 0
end

local function list_item(list, index)
    local item = nil
    pcall(function()
        item = list:call("get_Item", index)
    end)
    if item == nil then
        pcall(function()
            item = list:get_element(index)
        end)
    end
    if item == nil then
        pcall(function()
            item = list[index]
        end)
    end
    return item
end

local function active_soul_count()
    local sm = sdk.get_managed_singleton("app.SoulManager")
    local n = try_any(sm, { "get_ActiveSoulCount" })
        or try_field(sm, "<ActiveSoulCount>k__BackingField")
    if type(n) == "number" then
        return n
    end
    return list_count(try_field(sm, "_ActiveSoulList"))
end

-- Souls on screen, or any active soul if InScreen cannot be read.
local function souls_are_absorbable()
    local sm = sdk.get_managed_singleton("app.SoulManager")
    if not is_managed(sm) then
        return false
    end
    if active_soul_count() <= 0 then
        return false
    end
    local list = try_field(sm, "_ActiveSoulList")
    local n = list_count(list)
    if n <= 0 then
        return true
    end
    local checked = 0
    for i = 0, n - 1 do
        local soul = list_item(list, i)
        if is_managed(soul) then
            checked = checked + 1
            local on = try_any(soul, { "get_InScreen" })
                or try_field(soul, "<InScreen>k__BackingField")
            if on then
                return true
            end
        end
    end
    return checked == 0
end

local function absorb_should_hold(sup)
    if try_any(sup, { "get_IsAbsorption" }) then
        return true
    end
    if try_any(sup, { "get_IsAbsorptionEnableAction" }) then
        return true
    end
    return souls_are_absorbable()
end

local function install_absorb_hooks()
    if runtime.absorb_hooks then
        return
    end
    local td = sdk.find_type_definition("app.user_data.cPlayerEquipSkill")
    if not td then
        return
    end
    runtime.absorb_hooks = true
    hook_force_bool(td:get_method("get_IsAutoSoulAbsorbe"), function()
        return features.auto_absorb and runtime.souls_ready
    end, true)
end

local function apply_auto_absorb(want)
    install_absorb_hooks()
    if not want then
        runtime.souls_ready = false
        if runtime.absorb_was_on then
            runtime.absorb_was_on = false
            log_action("auto absorb off")
        end
        return true
    end

    local first = not runtime.absorb_was_on
    local sup = get_soul_absorption()
    local ready = absorb_should_hold(sup)
    runtime.souls_ready = ready

    if ready then
        local cache = get_equip_skill_cache()
        if cache then
            pcall(function()
                cache:set_field("_IsAutoSoulAbsorbe", true)
            end)
        end
        pcall(function()
            sup:set_field("_IsCommandAbsorb", true)
        end)
        pcall(function()
            sup:call("requestSoulAbsorptionAction", true)
        end)
    elseif is_managed(sup) then
        pcall(function()
            sup:set_field("_IsCommandAbsorb", false)
        end)
    end

    runtime.absorb_was_on = true
    if first then
        log_action("auto absorb on")
    end
    return true
end

local function scale_int_arg(args, index)
    local scale = soul_scale()
    if scale == 1.0 then
        return
    end
    local ok, n = pcall(function()
        return sdk.to_int64(args[index])
    end)
    if not ok or type(n) ~= "number" or n <= 0 then
        return
    end
    local scaled = math.floor(n * scale + 0.5)
    if scaled < 1 then
        scaled = 1
    end
    args[index] = sdk.to_ptr(scaled)
end

local function install_soul_hooks()
    if runtime.soul_hooks then
        return
    end
    local td = sdk.find_type_definition("app.cPlayerSoulAbsorptionSupporter")
    if not td then
        return
    end
    runtime.soul_hooks = true
    local method = td:get_method("addSoulAbsorption")
        or td:get_method("addSoulAbsorption(app.SoulDef.ID_Fixed, System.Int32, System.Boolean)")
    if method then
        pcall(sdk.hook, method, function(args)
            scale_int_arg(args, 4)
        end)
    end
end

local function apply_soul_mult()
    install_soul_hooks()
end

local function refresh_player_status()
    local info = get_player_info()
    local chara = get_player_character(info)
    if chara then
        runtime.player = obj_type(chara)
        runtime.hooked = true
    elseif info then
        runtime.player = obj_type(info)
        runtime.hooked = true
    else
        runtime.player = "—"
        runtime.hooked = false
    end
    runtime.hp, runtime.max_hp = read_hp()
    runtime.stamina, runtime.max_stamina = read_stamina()
    runtime.oni, runtime.max_oni = read_oni()
    runtime.oni_change, runtime.max_oni_change = read_oni_change()
    runtime.pouch = read_pouch()
end

menu = RefShell.create({
    id = "onimusha",
    title = "ONIMUSHA QOL",
    toggle_vk = 0xC0,
    dock = "right",
    width = 520,
    height = 720,
    start_open = false,
    persist = features,
    host = true,
    lock_camera = true,
    lock_cursor = true,
})

menu:add_tab("Samurai", function(ui)
    ui.section("Status", function()
        imgui.text("Hooks:")
        imgui.same_line()
        imgui.text_colored(
            runtime.hooked and "Ready" or "Waiting for player",
            runtime.hooked and COL_OK or COL_WAIT
        )
        local god_label = "Off"
        local god_col = COL_WAIT
        if features.god_mode then
            if runtime.god_was_on and runtime.hooked then
                god_label = "Active"
                god_col = COL_OK
            else
                god_label = "Waiting for player"
            end
        end
        imgui.text("God:")
        imgui.same_line()
        imgui.text_colored(god_label, god_col)
        ui.kv("Player", runtime.player)
        if runtime.hp and runtime.max_hp then
            ui.kv("HP", string.format("%s / %s", runtime.hp, runtime.max_hp))
        else
            ui.kv("HP", "—")
        end
        if runtime.stamina and runtime.max_stamina then
            ui.kv("Stamina", string.format("%s / %s", runtime.stamina, runtime.max_stamina))
        else
            ui.kv("Stamina", "—")
        end
        if runtime.oni and runtime.max_oni then
            ui.kv("Oni Power", string.format("%s / %s", runtime.oni, runtime.max_oni))
        else
            ui.kv("Oni Power", "—")
        end
        if runtime.oni_change and runtime.max_oni_change then
            ui.kv("Oni Change", string.format("%.0f / %.0f", runtime.oni_change, runtime.max_oni_change))
        else
            ui.kv("Oni Change", "—")
        end
        if runtime.pouch then
            ui.kv("Hozuki pouch", tostring(runtime.pouch))
        else
            ui.kv("Hozuki pouch", "—")
        end
        ui.kv("Last action", runtime.last_log)
        ui.muted("~ toggles this menu (rebind on Settings). Look input pauses while it is open.")
    end, false)

    ui.section("Cheats", function()
        ui.bind_toggle("Infinite Health", features, "inf_health")
        ui.bind_toggle("Infinite Stamina", features, "inf_stamina")
        ui.bind_toggle("Infinite Oni Power", features, "inf_oni_power")
        ui.bind_toggle("Always Oni Change", features, "inf_oni_change")
        ui.bind_toggle("Infinite Items", features, "inf_items")
        ui.bind_toggle("Easier Issen", features, "easier_issen")
        ui.bind_toggle("Always Issen", features, "always_issen")
        ui.bind_toggle("Always Deflect", features, "always_deflect")
        ui.bind_toggle("God Mode (No Hit)", features, "god_mode")
        ui.bind_toggle("Auto Absorb Souls", features, "auto_absorb")
        ui.bind_toggle("Soul Multiplier", features, "soul_mult_on")
        ui.bind_combo("Soul Amount", features, "soul_mult", SOUL_MULT_OPTIONS)
        ui.muted(
        "Always Oni Change pins the purple-soul transform bar. Easier Issen widens the X/Y timing and keeps the chain. Always Issen auto-counters when a hit is coming — no button. Deflect turns a held block into a perfect just-guard. Auto absorb only holds L2 when souls are out. Soul multiplier is opt-in and scales red, yellow, blue, and purple. Appearance swaps meshes from this menu — it does not write unlocks to the save. Give writes the inventory. Optional hotkeys live under Settings → Keybind.")
    end, true)
end)

local Appearance = _G.OnimushaAppearance
if type(Appearance) ~= "table" then
    local ok, mod = pcall(require, "appearance")
    if ok then
        Appearance = mod
    end
end
if type(Appearance) == "table" and Appearance.bind then
    Appearance.bind({
        try_call = try_call,
        try_field = try_field,
        try_any = try_any,
        try_static = try_static,
        is_managed = is_managed,
        enum_value = enum_value,
        get_player_entity = get_player_entity,
        get_player_context = get_player_context,
        log_action = log_action,
    })
end

menu:add_tab("Appearance", function(ui)
    if type(Appearance) == "table" and Appearance.draw then
        Appearance.draw(ui)
        return
    end
    ui.muted("Appearance module failed to load.")
end)

local Give = _G.OnimushaGive
if type(Give) ~= "table" then
    local ok, mod = pcall(require, "give")
    if ok then
        Give = mod
    end
end
if type(Give) == "table" and Give.bind then
    Give.bind({
        try_call = try_call,
        try_field = try_field,
        try_any = try_any,
        try_static = try_static,
        is_managed = is_managed,
        enum_value = enum_value,
        get_item_helper = get_item_helper,
        log_action = log_action,
    })
end

menu:add_tab("Give", function(ui)
    if type(Give) == "table" and Give.draw then
        Give.draw(ui)
        return
    end
    ui.muted("Give module failed to load.")
end)

menu.extra_keybinds = function(ui)
    ui.bind_hotkey("Infinite Health", features, "inf_health_vk")
    ui.bind_hotkey("Infinite Stamina", features, "inf_stamina_vk")
    ui.bind_hotkey("Infinite Oni Power", features, "inf_oni_power_vk")
    ui.bind_hotkey("Always Oni Change", features, "inf_oni_change_vk")
    ui.bind_hotkey("Infinite Items", features, "inf_items_vk")
    ui.bind_hotkey("Easier Issen", features, "easier_issen_vk")
    ui.bind_hotkey("Always Issen", features, "always_issen_vk")
    ui.bind_hotkey("Always Deflect", features, "always_deflect_vk")
    ui.bind_hotkey("God Mode (No Hit)", features, "god_mode_vk")
    ui.bind_hotkey("Auto Absorb Souls", features, "auto_absorb_vk")
    ui.bind_hotkey("Soul Multiplier", features, "soul_mult_on_vk")
end

re.on_frame(function()
    refresh_player_status()
    apply_god_mode(features.god_mode)
    apply_inf_health(features.inf_health)
    apply_inf_stamina(features.inf_stamina)
    apply_inf_oni(features.inf_oni_power)
    apply_inf_oni_change(features.inf_oni_change)
    apply_inf_items(features.inf_items)
    local give_busy = type(Give) == "table" and Give.busy and Give.busy()
    if not give_busy then
        apply_just_actions()
    end
    apply_auto_absorb(features.auto_absorb)
    apply_soul_mult()
    if type(Give) == "table" and Give.tick then
        Give.tick()
    end
end)

re.on_script_reset(function()
    if runtime.god_was_on then
        set_no_damage(false)
        runtime.god_was_on = false
    end
end)

menu:bind()
if menu.cfg.toggle_vk == 0x2D then
    menu.cfg.toggle_vk = 0xC0
    menu.dirty = true
end
if not features.issen_split then
    features.issen_split = true
    if features.always_issen and not features.easier_issen then
        features.easier_issen = true
        features.always_issen = false
        if (features.easier_issen_vk or 0) == 0 and (features.always_issen_vk or 0) ~= 0 then
            features.easier_issen_vk = features.always_issen_vk
            features.always_issen_vk = 0
        end
    end
    menu.dirty = true
end
end)()
end
