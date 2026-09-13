-- Item Catalog Prober v1.4 -- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- Read-only census, exhaustive. getItemFullName answers every ID; unused IDs
-- return the "name not set" placeholder. v1.4 sweeps 1-1000000, storing ONLY
-- real entries. Chunked across frames with progress + elapsed time; Stop
-- halts early and keeps what was found (dump whatever is there).
--
-- Menu: REFramework -> ScriptRunner -> "ItemCatalog v1.4".

local MOD, VERSION = "ItemCatalog", "1.4"
local TAG = "[" .. MOD .. "] "
local OUT_FILE = "item_catalog.json"
local ID_MIN, ID_MAX, CHUNK = 1, 1000000, 2000
-- Unused IDs resolve to this placeholder ("item name not set"): skip them.
local PLACEHOLDER = "設定されていません"

local function L(msg) log.info(TAG .. tostring(msg)) end

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

local helper, helper_how = nil, "-"
local tried = {}

local function note_tried(s)
    tried[#tried + 1] = s
    if #tried > 12 then table.remove(tried, 1) end
end

local function is_obj(v)
    if v == nil then return false end
    local ok, td = pcall(function() return v:get_type_definition() end)
    if not ok or td == nil then return false end
    return pcall(function() return v:get_address() end)
end

local function type_has(td, substr)
    local ok, n = pcall(td.get_full_name, td)
    return ok and type(n) == "string" and n:find(substr, 1, true) ~= nil
end

local function singleton(name)
    local s = nil
    pcall(function() s = sdk.get_managed_singleton(name) end)
    if s == nil then
        pcall(function()
            local short = name:match("^app%.(.+)$")
            if short then s = sdk.get_managed_singleton(sdk.game_namespace(short)) end
        end)
    end
    return s
end

local function resolve_helper()
    if helper ~= nil then
        local ok = pcall(function() return helper:get_address() end)
        if ok then return helper end
        helper = nil
    end
    helper_how = "-"
    -- Path 1: SaveDataManager -> get_Helper -> get__Item.
    local mgr = singleton("app.SaveDataManager")
    if mgr ~= nil then
        note_tried("SaveDataManager found")
        local shp = try_call(mgr, "get_Helper") or try_field(mgr, "_Helper")
        if shp ~= nil and is_obj(shp) then
            note_tried("get_Helper ok")
            local h = try_call(shp, "get__Item") or try_field(shp, "_Item")
            if h ~= nil and is_obj(h) then
                helper, helper_how = h, "SaveDataManager.get_Helper.get__Item"
                return helper
            end
            note_tried("get__Item MISSING on helper root")
        else
            note_tried("get_Helper MISSING")
        end
    else
        note_tried("SaveDataManager singleton MISSING")
    end
    -- Path 2: direct roots.
    for _, spec in ipairs({
        { s = "app.SaveDataHelper", get = "get__Item", fb = "_Item" },
        { s = "app.SaveDataHelper_Item" },
    }) do
        local s = singleton(spec.s)
        if s ~= nil then
            if spec.get == nil then
                helper, helper_how = s, spec.s .. " direct"
                return helper
            end
            local h = try_call(s, spec.get) or try_field(s, spec.fb)
            if h ~= nil and is_obj(h) then
                helper, helper_how = h, spec.s .. "." .. spec.get
                return helper
            end
            note_tried(spec.s .. " found, " .. spec.get .. " MISSING")
        else
            note_tried(spec.s .. " singleton MISSING")
        end
    end
    return nil
end

local scan = { running = false, next_id = ID_MIN, rows = {}, found = 0, t0 = 0 }
local status = "idle: enter gameplay, press Scan"

local function fmt_time(s)
    s = math.floor(s)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function scan_chunk()
    local h = resolve_helper()
    if h == nil then
        status = "helper not found (tried paths listed below)"
        L(status)
        scan.running = false
        return
    end
    if scan.t0 == 0 then scan.t0 = os.clock() end
    local stop = math.min(scan.next_id + CHUNK - 1, ID_MAX)
    for id = scan.next_id, stop do
        local name = try_call(h, "getItemFullName", id)
        if type(name) == "string" and #name > 0
            and not name:find(PLACEHOLDER, 1, true) then
            local count = try_call(h, "getItemCountOfId", id)
            local box = try_call(h, "getItemBoxCountOfId", id)
            local has = try_call(h, "hasObtainedItem", id)
            scan.rows[#scan.rows + 1] = {
                id = id, name = name,
                count = (type(count) == "number") and count or -1,
                box = (type(box) == "number") and box or -1,
                has = (has == true),
            }
            scan.found = scan.found + 1
        end
    end
    scan.next_id = stop + 1
    local pct = math.floor(stop / ID_MAX * 100)
    if scan.next_id > ID_MAX then
        scan.running = false
        status = string.format("done: %d real items in %d-%d (%s). Dump JSON.",
            scan.found, ID_MIN, ID_MAX, fmt_time(os.clock() - scan.t0))
        L(status)
    else
        status = string.format("scanning %d%% (%d/%d), found %d, %s in...",
            pct, stop, ID_MAX, scan.found, fmt_time(os.clock() - scan.t0))
    end
end

local function dump_json()
    local ok = pcall(json.dump_file, OUT_FILE, {
        meta = { mod = MOD, version = VERSION, range = { ID_MIN, ID_MAX },
            found = scan.found, via = helper_how },
        items = scan.rows,
    })
    status = ok and ("dumped " .. OUT_FILE .. " (" .. tostring(scan.found) .. " items)")
        or "dump failed (see log)"
    L(status)
end

re.on_frame(function()
    if scan.running then scan_chunk() end
end)

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        imgui.text("Status: " .. status)
        imgui.text("Helper: " .. helper_how)
        if #tried > 0 and helper == nil then
            imgui.text("Tried:")
            for i = 1, #tried do imgui.text("- " .. tried[i]) end
        end
        if imgui.button("Scan IDs") then
            scan.running, scan.next_id, scan.rows, scan.found, scan.t0 = true, ID_MIN, {}, 0, 0
            L("scan started")
        end
        imgui.same_line()
        if imgui.button("Stop") then
            scan.running = false
            status = string.format("stopped at %d/%d with %d found. Dump keeps them.",
                scan.next_id, ID_MAX, scan.found)
        end
        imgui.same_line()
        if imgui.button("Dump JSON") then dump_json() end
        if #scan.rows > 0 then
            imgui.text("Found: " .. tostring(scan.found))
            for i = math.max(1, #scan.rows - 19), #scan.rows do
                local r = scan.rows[i]
                imgui.text(string.format("%d: %s (x%s, box x%s)", r.id, r.name,
                    tostring(r.count), tostring(r.box)))
            end
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    helper, helper_how = nil, "-"
    tried = {}
    scan.running, scan.next_id, scan.rows, scan.found = false, ID_MIN, {}, 0
    status = "reset. Press Scan."
end)

L("loaded v" .. VERSION .. " (read-only item census)")
