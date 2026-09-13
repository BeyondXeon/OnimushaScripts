local MOD_NAME = "HiddenBoxMapReveal"
local VERSION = "1.0"

local SPECIAL_CHEST_FIXED = 19310

local TYPE_HIDDEN_BOX = "app.Gm002_006"
local TYPE_MAP_OBJECT_DATA = "app.user_data.MapObjectData"
local TYPE_ENV_INFO = "app.cEnvironmentInfoManager"

local METHOD_ALLOW_MAP_ICON = "isAllowRequestDisplayMapIcon"
local METHOD_CHECK_RANGE = "checkRange"
local METHOD_UPDATE_MAP_ICON = "updateMapIcon"
local METHOD_GET_DISPLAY_LIST = "getDisplayList"
local METHOD_GET_DISPLAY_OBJECT_LIST = "getDisplayObjectList"
local METHOD_ON_DISPLAY = "onDisplayObject"
local METHOD_OFF_DISPLAY = "offDisplayObject"
local METHOD_IS_RELEASE = "isReleaseObject"
local METHOD_IS_ENABLE = "isEnable"
local METHOD_IS_SPECIAL_DISABLE = "isCheckSpecialDisableCondition"

local TRUE_PTR = sdk.to_ptr(1)

local cached = {
    hidden_box_td = nil,
    map_data_td = nil,
    env_td = nil,
    method_allow = nil,
    method_check_range = nil,
    method_update_map_icon = nil,
    method_get_display_list = nil,
    method_get_display_object_list = nil,
}

local state = {
    enabled = true,
    hook_ok = false,
    allow_calls = 0,
    allow_forced = 0,
    range_forced = 0,
    reveal_count = 0,
    hide_count = 0,
    skip_disable_count = 0,
    last_log_at = 0,
    last_orig_allow = nil,
    status = "Loading",
    error = "",
}

local LOG_INTERVAL_SEC = 2.0
local LOG_FIRST_N = 8

local range_force_stack = {}
local reveal_busy = false

local function dbg(step, msg)
    print(string.format("[DEBUG] [%s/%s] %s", MOD_NAME, step, tostring(msg)))
end

local function set_error(msg)
    state.error = tostring(msg)
    state.status = "Error"
    dbg("Error", msg)
end

local function optional(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end

local function should_log(counter)
    if counter <= LOG_FIRST_N then
        return true
    end
    local now = os.clock()
    if now - state.last_log_at >= LOG_INTERVAL_SEC then
        state.last_log_at = now
        return true
    end
    return false
end

local function as_u32(v)
    if type(v) ~= "number" then
        return nil
    end
    return v & 0xFFFFFFFF
end

local function is_special_chest(cdata)
    if cdata == nil then
        return false
    end
    local t = optional(function()
        return cdata:call("get_MapObjectType")
    end)
    local u = as_u32(t)
    return u ~= nil and u == (SPECIAL_CHEST_FIXED & 0xFFFFFFFF)
end

local function is_valid_live_special_chest(cdata)
    if not is_special_chest(cdata) then
        return false
    end

    local enabled = optional(function()
        return cdata:call(METHOD_IS_ENABLE)
    end)
    if enabled ~= true then
        return false
    end

    local special_disable = optional(function()
        return cdata:call(METHOD_IS_SPECIAL_DISABLE)
    end)
    if special_disable == true then
        return false
    end

    return true
end

local function reveal_special_chests_on_map_data(map_data, step)
    if not state.enabled or map_data == nil or reveal_busy then
        return
    end

    reveal_busy = true
    local ok, err = pcall(function()
        local list = optional(function()
            return map_data:get_field("_List")
        end)
        if list == nil then
            return
        end

        local count = optional(function()
            return list:get_size()
        end)
        if type(count) ~= "number" or count <= 0 then
            count = optional(function()
                return #list
            end) or 0
        end
        if count <= 0 then
            return
        end

        local revealed = 0
        local hidden = 0
        local skipped = 0
        local max_n = math.min(count, 512)
        for i = 0, max_n - 1 do
            local cdata = optional(function()
                return list[i]
            end)
            if cdata ~= nil and is_special_chest(cdata) then
                local main_id = optional(function()
                    return cdata:call("get_MainID")
                end)
                local sub_id = optional(function()
                    return cdata:call("get_SubID")
                end)
                if main_id ~= nil and sub_id ~= nil then
                    local released = optional(function()
                        return map_data:call(METHOD_IS_RELEASE, main_id, sub_id)
                    end) == true
                    local valid = (not released) and is_valid_live_special_chest(cdata)

                    if valid then
                        local changed = optional(function()
                            return map_data:call(METHOD_ON_DISPLAY, main_id, sub_id)
                        end)
                        if changed then
                            revealed = revealed + 1
                        end
                    else
                        optional(function()
                            map_data:call(METHOD_OFF_DISPLAY, main_id, sub_id)
                        end)
                        hidden = hidden + 1
                        if not released then
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end

        if revealed > 0 or hidden > 0 then
            state.reveal_count = state.reveal_count + revealed
            state.hide_count = state.hide_count + hidden
            state.skip_disable_count = state.skip_disable_count + skipped
            dbg(step, string.format(
                "SPECIAL_CHEST on=%d off=%d skipped_disabled=%d",
                revealed, hidden, skipped))
        end
    end)
    reveal_busy = false

    if not ok then
        dbg(step .. "/Error", tostring(err))
    end
end

local function resolve_methods()
    dbg("Init", "resolve types/methods begin")

    cached.hidden_box_td = optional(function()
        return sdk.find_type_definition(TYPE_HIDDEN_BOX)
    end)
    cached.map_data_td = optional(function()
        return sdk.find_type_definition(TYPE_MAP_OBJECT_DATA)
    end)
    cached.env_td = optional(function()
        return sdk.find_type_definition(TYPE_ENV_INFO)
    end)

    if cached.hidden_box_td == nil then
        set_error("type not found: " .. TYPE_HIDDEN_BOX)
        return false
    end
    if cached.map_data_td == nil then
        set_error("type not found: " .. TYPE_MAP_OBJECT_DATA)
        return false
    end

    cached.method_allow = optional(function()
        return cached.hidden_box_td:get_method(METHOD_ALLOW_MAP_ICON)
    end)
    cached.method_check_range = optional(function()
        return cached.map_data_td:get_method(METHOD_CHECK_RANGE)
    end)
    cached.method_get_display_list = optional(function()
        return cached.map_data_td:get_method(METHOD_GET_DISPLAY_LIST)
    end)

    if cached.env_td ~= nil then
        cached.method_update_map_icon = optional(function()
            return cached.env_td:get_method(METHOD_UPDATE_MAP_ICON)
        end)
        cached.method_get_display_object_list = optional(function()
            return cached.env_td:get_method(METHOD_GET_DISPLAY_OBJECT_LIST)
        end)
    end

    if cached.method_allow == nil then
        set_error("method not found: " .. METHOD_ALLOW_MAP_ICON)
        return false
    end
    if cached.method_check_range == nil then
        set_error("method not found: " .. METHOD_CHECK_RANGE)
        return false
    end

    dbg("Init", "core methods ok")
    return true
end

local function install_allow_hook()
    sdk.hook(cached.method_allow,
        function(args)
            if not state.enabled then
                return
            end
            state.allow_calls = state.allow_calls + 1
        end,
        function(retval)
            if not state.enabled then
                return retval
            end
            state.last_orig_allow = optional(function()
                return sdk.to_int64(retval) ~= 0
            end)
            state.allow_forced = state.allow_forced + 1
            if should_log(state.allow_calls) then
                dbg("AllowMapIcon/post",
                    string.format("orig=%s forced=true", tostring(state.last_orig_allow)))
            end
            return TRUE_PTR
        end
    )
end

local function install_check_range_hook()
    sdk.hook(cached.method_check_range,
        function(args)
            local force = false
            if state.enabled then
                local cdata = optional(function()
                    return sdk.to_managed_object(args[2])
                end)
                force = is_valid_live_special_chest(cdata)
            end
            range_force_stack[#range_force_stack + 1] = force
        end,
        function(retval)
            local force = false
            local n = #range_force_stack
            if n > 0 then
                force = range_force_stack[n]
                range_force_stack[n] = nil
            end
            if force then
                state.range_forced = state.range_forced + 1
                if should_log(state.range_forced) then
                    dbg("CheckRange/post", "valid SPECIAL_CHEST range forced true")
                end
                return TRUE_PTR
            end
            return retval
        end
    )
end

local function install_update_map_icon_hook()
    if cached.method_update_map_icon == nil then
        dbg("Init", "updateMapIcon missing (optional)")
        return
    end

    sdk.hook(cached.method_update_map_icon,
        function(args)
            if not state.enabled then
                return
            end
            local map_data = optional(function()
                return sdk.to_managed_object(args[2])
            end)
            if map_data == nil then
                map_data = optional(function()
                    return sdk.to_managed_object(args[1])
                end)
            end
            reveal_special_chests_on_map_data(map_data, "UpdateMapIcon")
        end,
        function(retval)
            return retval
        end
    )
end

local function install_get_display_list_hook()
    if cached.method_get_display_list == nil then
        dbg("Init", "getDisplayList missing (optional)")
        return
    end

    sdk.hook(cached.method_get_display_list,
        function(args)
            if not state.enabled then
                return
            end
            local map_data = optional(function()
                return sdk.to_managed_object(args[1])
            end)
            reveal_special_chests_on_map_data(map_data, "GetDisplayList")
        end,
        function(retval)
            return retval
        end
    )
end

local function install_get_display_object_list_hook()
    if cached.method_get_display_object_list == nil then
        dbg("Init", "getDisplayObjectList missing (optional)")
        return
    end

    sdk.hook(cached.method_get_display_object_list,
        function(args)
            if not state.enabled then
                return
            end
            local env = optional(function()
                return sdk.to_managed_object(args[1])
            end)
            if env == nil then
                return
            end

            local dict = optional(function()
                return env:get_field("_MapObjectDataList")
            end)
            if dict == nil then
                return
            end

            local values = optional(function()
                return dict:call("get_Values")
            end)
            if values == nil then
                return
            end

            local iter = optional(function()
                return values:call("GetEnumerator")
            end)
            if iter == nil then
                return
            end

            local guard = 0
            while guard < 256 do
                guard = guard + 1
                local moved = optional(function()
                    return iter:call("MoveNext")
                end)
                if moved ~= true then
                    break
                end
                local map_data = optional(function()
                    return iter:call("get_Current")
                end)
                reveal_special_chests_on_map_data(map_data, "GetDisplayObjectList")
            end
        end,
        function(retval)
            return retval
        end
    )
end

local function install_hooks()
    local ok, err = pcall(function()
        install_allow_hook()
        install_check_range_hook()
        install_update_map_icon_hook()
        install_get_display_list_hook()
        install_get_display_object_list_hook()
    end)

    if not ok then
        set_error("hook failed: " .. tostring(err))
        return false
    end

    state.hook_ok = true
    state.status = "Ready (valid SPECIAL_CHEST only)"
    dbg("Init", state.status)
    return true
end

local function boot()
    dbg("Boot", MOD_NAME .. " v" .. VERSION)
    if not resolve_methods() then
        return
    end
    install_hooks()
end

re.on_draw_ui(function()
    if not imgui.tree_node(MOD_NAME .. " v" .. VERSION) then
        return
    end

    local changed, enabled = imgui.checkbox("Enable hidden box map reveal", state.enabled)
    if changed then
        state.enabled = enabled
        dbg("UI", "enabled=" .. tostring(enabled))
    end

    imgui.tree_pop()
end)

boot()
