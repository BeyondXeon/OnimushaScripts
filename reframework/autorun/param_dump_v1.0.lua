-- ParamDump v1.1 -- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- FULL dump: learn every game function, not just HP.
-- Read-only census of types + methods + fields + enums + values.
--
-- What it dumps (all read-only, TDB versions only):
--   1. Build header (game, REF tag/commit, TDB version).
--   2. Singleton census (managed + native candidates, found/missing + typename).
--   3. TYPE REGISTRY: for every discovered type -> parent chain, sizes,
--      flags, FULL field list (type, offsets, flags, static/literal,
--      static value), FULL method list (return type, param names+types,
--      static, num params, function addr), enum values.
--   4. VALUE WALK: recursive field walk from player + singletons + components
--      (depth-limited, cycle-safe, pairs/get_elements, never ipairs).
--   5. COMPONENT TREE: GameObject get_Name + get_Components + Transform
--      Child/Next walk (limited) so you see what components exist.
--   6. Change-only trace (1/5 frames, 20k cap) + Snapshot A/B diff.
--   7. JSON export split in 3 files so no single file explodes:
--        param_dump_types.json  (type registry: functions to learn)
--        param_dump_values.json (values + diff + live changes)
--        param_dump_census.json (singletons + coverage counts)
--
-- Read-only: never set_field, never calls setters. Only get_field,
-- zero-arg get_*, and TDB introspection. Safe alongside other mods.
--
-- Menu: REFramework -> ScriptRunner -> "ParamDump v1.1".
-- Usage: 1) Enter gameplay 2) Full Scan 3) Dump All JSON
--        4) Open reframework/data/param_dump_types.json to learn functions.
-- Tip: Object Explorer > Dump SDK gives il2cpp_dump.json (minutes, ~1GB on
-- newer titles). Use the Python grep helper for offline name search; this
-- Lua dump gives you LIVE reachable types + current values.

local MOD, VERSION, CFG_FILE = "ParamDump", "1.2", "param_dump_config.json"
local OUT_TYPES, OUT_VALUES, OUT_CENSUS = "param_dump_types.json", "param_dump_values.json", "param_dump_census.json"
local TAG = "[" .. MOD .. "] "
local MAX_TRACKED = 20000
local MAX_TYPES = 300
local MAX_FIELDS_PER_TYPE = 500
local MAX_METHODS_PER_TYPE = 800
local MAX_DEPTH = 3
local MAX_ARRAY = 32
local MAX_COMP = 24

-- v1.2 targeted seeds: types the 300-cap frontier never reached in v1.1.
local TARGET_SEEDS = {
    "app.Hit", "app.HitInfo", "app.Hit.RESULT", "app.AttackSensorHitInfo",
    "app.cPlayerInvincibleSupporter", "app.cCharacterInvincibleSupporter",
    "app.cCharacterApplyDamage", "app.cPlayerApplyDamage",
    "app.cCharacterApplyDamage.cApplyParam", "app.cStockDamageInfoCharacter",
    "app.BattleInfo.cDamageInfoBase", "app.cAttackInfoBase",
    "app.PlayerNoHitLevel.TYPE_Fixed", "app.cPlayerDieSupporter",
    "app.cHealthManager",
}

-- v1.2 noise filter: list-version/capacity counters drowned the 300-change log.
local NOISE_KEYS = { "_version", "_size", "capacity", "_count", "count>" }
local function is_noisy(path)
    if type(path) ~= "string" then return false end
    local p = path:lower()
    for _, k in ipairs(NOISE_KEYS) do
        if p:find(k, 1, true) then return true end
    end
    return false
end

-- v1.2 run label: read invincibility mod config read-only so OFF vs INFHP
-- dumps are distinguishable. Returns "OFF", "INFHP", "NOHIT", or "UNKNOWN".
local run_label = "UNKNOWN"
local function read_inv_mode()
    local ok, saved = pcall(json.load_file, "invincibility_mod.json")
    if ok and type(saved) == "table" then
        if saved.enabled == false then return "OFF" end
        if saved.mode == "infhp" then return "INFHP" end
        if saved.mode == "nohit" then return "NOHIT" end
        if saved.mode == "off" then return "OFF" end
        return tostring(saved.mode or "UNKNOWN"):upper()
    end
    return "UNKNOWN"
end

local function L(msg) log.info(TAG .. tostring(msg)) end

local cfg = { tracing = true, depth = MAX_DEPTH, filter = "ALL" }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.tracing) == "boolean" then cfg.tracing = saved.tracing end
        if type(saved.depth) == "number" then
            cfg.depth = math.max(1, math.min(4, math.floor(saved.depth)))
        end
        if type(saved.filter) == "string" then cfg.filter = saved.filter end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function save_cfg() pcall(json.dump_file, CFG_FILE, cfg) end

local FILTERS = {
    ALL = nil,
    HIT = { "hit", "damag", "kill", "dead", "die", "fatal", "wound", "nohit", "invinc" },
    HP = { "hp", "health", "life", "vital", "hitpoint", "stamina", "gauge" },
    PLAYER = { "player", "chara", "entity", "control", "context", "supporter" },
    SYSTEM = { "save", "scene", "gui", "manager", "service", "system" },
}
local function filter_hit(name)
    local keys = FILTERS[cfg.filter]
    if keys == nil then return true end
    if type(name) ~= "string" then return false end
    local n = name:lower()
    for _, k in ipairs(keys) do if n:find(k, 1, true) then return true end end
    return false
end

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
    local oka = pcall(function() return v:get_address() end)
    return oka
end

local function type_name_of(obj)
    if obj == nil then return "nil" end
    local ok, td = pcall(obj.get_type_definition, obj)
    if ok and td ~= nil then
        local okn, n = pcall(td.get_full_name, td)
        if okn and n then return tostring(n) end
    end
    return "?"
end

local function safe_call(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

-- Per-type field def cache to avoid hashmap lookup per frame.
local field_cache = {}
local function field_defs(obj)
    if obj == nil then return {} end
    local tname = type_name_of(obj)
    local hit = field_cache[tname]
    if hit ~= nil then return hit end
    hit = {}
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if ok_td and td ~= nil then
        local okf, fields = pcall(td.get_fields, td)
        if okf and fields ~= nil then
            for _, f in pairs(fields) do
                local fname = safe_call(function() return f:get_name() end)
                if type(fname) == "string" then
                    local ftname = "?"
                    pcall(function()
                        local ft = f:get_type()
                        if ft ~= nil then ftname = ft:get_full_name() end
                    end)
                    hit[#hit + 1] = { name = fname, tname = tostring(ftname) }
                end
            end
        end
    end
    field_cache[tname] = hit
    return hit
end

-- Build header.
local build = { game = "?", tag = "?", commit = "?", branch = "?", tdb = "?" }
pcall(function() build.game = tostring(reframework:get_game_name()) end)
pcall(function() build.tag = tostring(reframework:get_tag()) end)
pcall(function() build.commit = tostring(reframework:get_commit_hash()) end)
pcall(function() build.branch = tostring(reframework:get_branch()) end)
pcall(function() build.tdb = tostring(sdk.get_tdb_version()) end)
L(string.format("build game=%s tag=%s commit=%s branch=%s tdb=%s",
    build.game, build.tag, build.commit, build.branch, build.tdb))

local MANAGED_CANDIDATES = {
    "app.PlayerManager", "app.EnemyManager", "app.CharacterManager",
    "app.PropsManager", "app.FigureManager", "app.SaveManager",
    "app.SaveServiceManager", "app.GameManager", "app.InteractManager",
    "app.ItemManager", "app.WeaponManager", "app.CameraManager",
    "app.GuiManager", "app.SoundManager", "app.EffectManager",
    "app.HitManager", "app.DamageManager", "app.HealthManager",
    "app.SceneManager", "app.MotionManager", "app.BehaviorManager",
    "app.NavigationManager", "app.NetworkManager", "app.UIManager",
    "app.InputManager", "app.OptionManager", "app.QuestManager",
    "app.MapManager", "app.TimeManager", "app.WeatherManager",
}
local NATIVE_CANDIDATES = {
    "via.SceneManager", "via.Application", "via.RenderManager",
    "via.ResourceManager", "via.HID", "via.Sound", "via.GUI",
    "via.Physics", "via.Motion", "via.Navigation",
}

local census, roots = {}, {}
local type_registry = {} -- fullname -> dumped type table
local frontier = {}      -- typenames to expand via find_type_definition
local n_methods_total, n_fields_total = 0, 0

local function describe_field(f)
    local e = { name = "?", type = "?", static = false, literal = false,
        off_base = "?", off_fieldptr = "?", flags = "?", static_value = nil }
    pcall(function() e.name = tostring(f:get_name()) end)
    pcall(function()
        local ft = f:get_type()
        if ft ~= nil then e.type = tostring(ft:get_full_name()) end
    end)
    pcall(function() e.off_base = tostring(f:get_offset_from_base()) end)
    pcall(function() e.off_fieldptr = tostring(f:get_offset_from_fieldptr()) end)
    pcall(function() e.flags = tostring(f:get_flags()) end)
    pcall(function() e.static = f:is_static() == true end)
    pcall(function() e.literal = f:is_literal() == true end)
    if e.static then
        local okv, v = pcall(f.get_data, f, nil)
        if okv and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then
            e.static_value = v
        elseif okv and v ~= nil then
            e.static_value = tostring(v)
        end
    end
    return e
end

local function describe_method(m)
    local e = { name = "?", returns = "?", static = false, num_params = 0,
        params = {}, func = "?" }
    pcall(function() e.name = tostring(m:get_name()) end)
    pcall(function()
        local rt = m:get_return_type()
        if rt ~= nil then e.returns = tostring(rt:get_full_name()) end
    end)
    pcall(function() e.static = m:is_static() == true end)
    pcall(function() e.num_params = tonumber(m:get_num_params()) or 0 end)
    pcall(function()
        local pts = m:get_param_types()
        local pns = nil
        pcall(function() pns = m:get_param_names() end)
        if pts ~= nil then
            for i, pt in ipairs(pts) do
                local pn = (pns ~= nil and pns[i]) or ("p" .. tostring(i))
                local ptname = "?"
                pcall(function() ptname = tostring(pt:get_full_name()) end)
                e.params[#e.params + 1] = { name = tostring(pn), type = ptname }
            end
        end
    end)
    pcall(function()
        local fn = m:get_function()
        if fn ~= nil then e.func = tostring(fn) end
    end)
    return e
end

-- Dump one typedef into the registry. Returns field-type names for frontier.
local function dump_typedef(td)
    if td == nil then return {} end
    local full = safe_call(function() return td:get_full_name() end)
    if type(full) ~= "string" or type_registry[full] ~= nil then return {} end
    if not filter_hit(full) then return {} end
    local entry = { name = full, methods = {}, fields = {}, enums = {},
        parents = {}, flags = {}, size = "?", vsize = "?" }
    pcall(function() entry.namespace = tostring(td:get_namespace()) end)
    pcall(function() entry.short = tostring(td:get_name()) end)
    pcall(function() entry.size = tostring(td:get_size()) end)
    pcall(function() entry.vsize = tostring(td:get_valuetype_size()) end)
    pcall(function() entry.flags.is_value_type = td:is_value_type() == true end)
    pcall(function() entry.flags.is_primitive = td:is_primitive() == true end)
    pcall(function() entry.flags.is_pointer = td:is_pointer() == true end)
    pcall(function() entry.flags.is_by_ref = td:is_by_ref() == true end)
    pcall(function() entry.flags.is_generic = td:is_generic_type() == true end)
    -- Parent chain.
    pcall(function()
        local p = td:get_parent_type()
        local depth = 0
        while p ~= nil and depth < 8 do
            local pn = nil
            pcall(function() pn = p:get_full_name() end)
            if pn == nil then break end
            entry.parents[#entry.parents + 1] = tostring(pn)
            local up = nil
            pcall(function() up = p:get_parent_type() end)
            p = up
            depth = depth + 1
        end
    end)
    local next_types = {}
    -- Fields (full detail + enum capture).
    local okf, fields = pcall(td.get_fields, td)
    if okf and fields ~= nil then
        local n = 0
        for _, f in pairs(fields) do
            if n >= MAX_FIELDS_PER_TYPE then break end
            n = n + 1
            local e = describe_field(f)
            if filter_hit(e.name) or filter_hit(e.type) or cfg.filter == "ALL" then
                entry.fields[#entry.fields + 1] = e
                n_fields_total = n_fields_total + 1
                if e.static and type(e.static_value) == "number" and e.name ~= "value__" then
                    entry.enums[#entry.enums + 1] = { name = e.name, value = e.static_value }
                end
                if e.type ~= "?" and #frontier < MAX_TYPES * 3 then
                    next_types[#next_types + 1] = e.type
                end
            end
        end
    end
    -- Methods (full signatures).
    local okm, methods = pcall(td.get_methods, td)
    if okm and methods ~= nil then
        local n = 0
        for _, m in pairs(methods) do
            if n >= MAX_METHODS_PER_TYPE then break end
            n = n + 1
            local e = describe_method(m)
            if filter_hit(e.name) or filter_hit(e.returns) or cfg.filter == "ALL" then
                entry.methods[#entry.methods + 1] = e
                n_methods_total = n_methods_total + 1
                for _, p in ipairs(e.params) do
                    if p.type ~= "?" and #frontier < MAX_TYPES * 3 then
                        next_types[#next_types + 1] = p.type
                    end
                end
                if e.returns ~= "?" and #frontier < MAX_TYPES * 3 then
                    next_types[#next_types + 1] = e.returns
                end
            end
        end
    end
    type_registry[full] = entry
    return next_types
end

local function ensure_type(tname)
    if type(tname) ~= "string" or tname == "?" then return end
    if tname:sub(1, 7) == "System." then return end -- primitives: skip frontier
    if type_registry[tname] ~= nil then return end
    local ok, td = pcall(sdk.find_type_definition, tname)
    if ok and td ~= nil then
        local more = dump_typedef(td)
        for _, nt in ipairs(more) do
            if #frontier < MAX_TYPES * 3 then frontier[#frontier + 1] = nt end
        end
    end
end

local function expand_frontier()
    local expanded, guard = 0, 0
    while #frontier > 0 and expanded < MAX_TYPES and guard < MAX_TYPES * 4 do
        guard = guard + 1
        local tname = table.remove(frontier, 1)
        if type_registry[tname] == nil then
            ensure_type(tname)
            expanded = expanded + 1
        end
    end
end

local function discover_singletons()
    census, roots = {}, {}
    for _, name in ipairs(MANAGED_CANDIDATES) do
        local obj = nil
        pcall(function() obj = sdk.get_managed_singleton(name) end)
        if obj == nil then
            pcall(function()
                local short = name:match("^app%.(.+)$")
                if short then obj = sdk.get_managed_singleton(sdk.game_namespace(short)) end
            end)
        end
        local found = is_managed_object(obj)
        census[#census + 1] = { name = name, kind = "managed",
            found = found, typename = found and type_name_of(obj) or "-" }
        if found then
            roots[#roots + 1] = { label = "S:" .. name, obj = obj }
            local ok_td, td = pcall(obj.get_type_definition, obj)
            if ok_td and td ~= nil then
                local more = dump_typedef(td)
                for _, nt in ipairs(more) do frontier[#frontier + 1] = nt end
            end
            ensure_type(type_name_of(obj))
        end
    end
    for _, name in ipairs(NATIVE_CANDIDATES) do
        local ptr = nil
        pcall(function() ptr = sdk.get_native_singleton(name) end)
        local found = ptr ~= nil
        census[#census + 1] = { name = name, kind = "native",
            found = found, typename = found and name or "-" }
        if found then
            local ok, td = pcall(sdk.find_type_definition, name)
            if ok and td ~= nil then
                local more = dump_typedef(td)
                for _, nt in ipairs(more) do frontier[#frontier + 1] = nt end
            end
        end
    end
    local nfound = 0
    for _, c in ipairs(census) do if c.found then nfound = nfound + 1 end end
    L(string.format("census: %d/%d singletons found", nfound, #census))
end

local function resolve_player_roots()
    local list = {}
    local pm = nil
    pcall(function() pm = sdk.get_managed_singleton("app.PlayerManager") end)
    if pm == nil then return list end
    local mi = try_call(pm, "getControllingPlayer")
    if mi == nil then mi = try_call(pm, "getControllingPlayerInfo") end
    if mi == nil then return list end
    local chara = try_call(mi, "get_Character")
    local entity = try_call(mi, "get_CharacterEntity")
    local go = try_call(mi, "get_Object")
    if is_managed_object(mi) then list[#list + 1] = { label = "PlayerInfo", obj = mi } end
    if is_managed_object(chara) then list[#list + 1] = { label = "Character", obj = chara } end
    if is_managed_object(entity) then list[#list + 1] = { label = "Entity", obj = entity } end
    if is_managed_object(go) then list[#list + 1] = { label = "GameObject", obj = go } end
    -- v1.2 health roots via context-chain (ported from invincibility v1.17
    -- resolve_health_mgr): direct get_HealthManager links miss, the manager
    -- hangs under context holder/core or the GameObject component.
    local function find_health_on(obj)
        if not is_managed_object(obj) then return nil end
        local mgr = try_call(obj, "get_HealthManager")
        if mgr == nil then mgr = try_field(obj, "<HealthManager>k__BackingField") end
        if is_managed_object(mgr) then return mgr end
        return nil
    end
    do
        local mgr = find_health_on(mi) or find_health_on(chara) or find_health_on(entity)
        if mgr == nil then
            local ctx = try_call(chara, "get_Context")
            mgr = find_health_on(ctx)
        end
        if mgr == nil then
            local holder = try_field(mi, "_ContextHolder") or try_call(mi, "get_ContextHolder")
                or try_field(chara, "_ContextHolder") or try_call(chara, "get_ContextHolder")
            mgr = find_health_on(holder)
            if mgr == nil then
                local core = try_field(holder, "_ContextCore") or try_call(holder, "get_ContextCore")
                mgr = find_health_on(core)
            end
            if mgr == nil then
                local contexts = try_field(holder, "Contexts") or try_call(holder, "get_Contexts")
                if contexts ~= nil then
                    local ok, n = pcall(function() return contexts:get_size() end)
                    if ok and type(n) == "number" then
                        for i = 0, math.min(n - 1, 31) do
                            local c = nil
                            pcall(function() c = contexts:get_element(i) end)
                            mgr = find_health_on(c)
                            if mgr then break end
                        end
                    end
                end
            end
        end
        if mgr == nil and is_managed_object(go) then
            local rt = nil
            pcall(function() rt = sdk.typeof("app.cHealthManager") end)
            if rt ~= nil then
                local comp = try_call(go, "getComponent(System.Type)", rt)
                if is_managed_object(comp) then mgr = comp end
            end
        end
        if is_managed_object(mgr) then
            list[#list + 1] = { label = "HealthManager", obj = mgr }
        end
    end
    for _, r in ipairs(list) do
        local ok_td, td = pcall(r.obj.get_type_definition, r.obj)
        if ok_td and td ~= nil then
            local more = dump_typedef(td)
            for _, nt in ipairs(more) do frontier[#frontier + 1] = nt end
        end
    end
    return list
end

-- v1.2 HP pair readout (read-only): proves pinned-max vs real drop.
local hp_last, hpmax_last, hmgr_step = nil, nil, "-"
local function read_hp_pair()
    hp_last, hpmax_last, hmgr_step = nil, nil, "-"
    local prow = resolve_player_roots()
    local mgr = nil
    for _, r in ipairs(prow) do
        if r.label == "HealthManager" then mgr = r.obj break end
    end
    if mgr == nil then return nil, nil end
    local hp = try_call(mgr, "get_Health")
    local mx = try_call(mgr, "get_MaxHealth")
    if type(hp) == "number" and type(mx) == "number" then
        hp_last, hpmax_last, hmgr_step = hp, mx, "HealthManager"
    end
    return hp_last, hpmax_last
end

-- v1.2: force targeted seeds before frontier expansion so Hit/Invincible/
-- ApplyParam/StockDamage types are always in the registry.
local function seed_targeted_types()
    for _, tname in ipairs(TARGET_SEEDS) do
        if type_registry[tname] == nil then
            local ok, td = pcall(sdk.find_type_definition, tname)
            if ok and td ~= nil then
                local more = dump_typedef(td)
                for _, nt in ipairs(more) do
                    if #frontier < MAX_TYPES * 3 then frontier[#frontier + 1] = nt end
                end
            end
        end
    end
end

-- Component tree: GameObject name + components + Transform Child/Next (limited).
local function dump_components(go, rows, visited)
    if not is_managed_object(go) then return end
    local gname = try_call(go, "get_Name") or "?"
    rows[#rows + 1] = { path = "GO:" .. tostring(gname), kind = "gameobject",
        value = type_name_of(go), typename = "via.GameObject" }
    local comps = try_call(go, "get_Components")
    if comps ~= nil then
        local ok_el, els = pcall(function() return comps:get_elements() end)
        if ok_el and type(els) == "table" then
            local n = 0
            for _, c in pairs(els) do
                n = n + 1
                if n > MAX_COMP or #rows >= MAX_TRACKED then break end
                if is_managed_object(c) then
                    rows[#rows + 1] = { path = "GO:" .. tostring(gname) .. ".comp[" .. tostring(n) .. "]",
                        kind = "component", value = type_name_of(c), typename = "component" }
                    local ok_td, td = pcall(c.get_type_definition, c)
                    if ok_td and td ~= nil then
                        local more = dump_typedef(td)
                        for _, nt in ipairs(more) do
                            if #frontier < MAX_TYPES * 3 then frontier[#frontier + 1] = nt end
                        end
                    end
                end
            end
        end
    end
    -- Transform children (1 level, capped).
    local tr = try_call(go, "get_Transform")
    if is_managed_object(tr) then
        local child = try_call(tr, "get_Child")
        local n = 0
        while is_managed_object(child) and n < 8 and #rows >= 0 and #rows < MAX_TRACKED do
            n = n + 1
            local cgo = try_call(child, "get_GameObject")
            if is_managed_object(cgo) then
                rows[#rows + 1] = { path = "GO:" .. tostring(gname) .. ".child[" .. tostring(n) .. "]",
                    kind = "gameobject", value = tostring(try_call(cgo, "get_Name")),
                    typename = type_name_of(cgo) }
            end
            child = try_call(child, "get_Next")
        end
    end
end

local function walk(obj, label, depth, max_depth, visited, rows)
    if obj == nil or #rows >= MAX_TRACKED then return end
    if not is_managed_object(obj) then return end
    local addr = 0
    pcall(function() addr = obj:get_address() end)
    if addr ~= 0 then
        if visited[addr] then return end
        visited[addr] = true
    end
    if depth > max_depth then return end
    local defs = field_defs(obj)
    for i = 1, #defs do
        if #rows >= MAX_TRACKED then return end
        local d = defs[i]
        if filter_hit(d.name) or filter_hit(d.tname) or cfg.filter == "ALL" then
            local path = label .. "." .. d.name
            local okv, v = pcall(obj.get_field, obj, d.name)
            if okv then
                local vt = type(v)
                if vt == "number" then
                    if v == v then
                        rows[#rows + 1] = { path = path, kind = "number", value = v, typename = d.tname }
                    end
                elseif vt == "string" or vt == "boolean" then
                    rows[#rows + 1] = { path = path, kind = vt, value = v, typename = d.tname }
                elseif is_managed_object(v) then
                    local ok_sz, sz = pcall(function() return v:get_size() end)
                    if ok_sz and type(sz) == "number" then
                        rows[#rows + 1] = { path = path, kind = "array", value = sz, typename = type_name_of(v) }
                        if depth < max_depth then
                            local n = math.min(sz, MAX_ARRAY)
                            for idx = 0, n - 1 do
                                local el = nil
                                pcall(function() el = v:get_element(idx) end)
                                if type(el) == "number" or type(el) == "string" or type(el) == "boolean" then
                                    rows[#rows + 1] = { path = path .. "[" .. tostring(idx) .. "]",
                                        kind = type(el), value = el, typename = "element" }
                                elseif is_managed_object(el) then
                                    local ok_td, td = pcall(el.get_type_definition, el)
                                    if ok_td and td ~= nil then
                                        local more = dump_typedef(td)
                                        for _, nt in ipairs(more) do
                                            if #frontier < MAX_TYPES * 3 then frontier[#frontier + 1] = nt end
                                        end
                                    end
                                    walk(el, path .. "[" .. tostring(idx) .. "]", depth + 1, max_depth, visited, rows)
                                end
                                if #rows >= MAX_TRACKED then return end
                            end
                        end
                    else
                        rows[#rows + 1] = { path = path, kind = "object", value = type_name_of(v), typename = d.tname }
                        ensure_type(type_name_of(v))
                        if depth < max_depth then
                            walk(v, path, depth + 1, max_depth, visited, rows)
                        end
                    end
                end
            end
        end
    end
    if depth == 0 and #rows < MAX_TRACKED then
        local ok_td, td = pcall(obj.get_type_definition, obj)
        if ok_td and td ~= nil then
            local okm, methods = pcall(td.get_methods, td)
            if okm and methods ~= nil then
                local n = 0
                for _, m in pairs(methods) do
                    if #rows >= MAX_TRACKED then break end
                    n = n + 1
                    if n > 400 then break end
                    local mname = safe_call(function() return m:get_name() end)
                    if type(mname) == "string" and mname:sub(1, 4) == "get_" and filter_hit(mname) then
                        local okp, pts = pcall(m.get_param_types, m)
                        if okp and (pts == nil or #pts == 0) then
                            local v = try_call(obj, mname)
                            if type(v) == "number" and v == v then
                                rows[#rows + 1] = { path = label .. ":" .. mname .. "()",
                                    kind = "getter", value = v, typename = "getter" }
                            elseif is_managed_object(v) then
                                ensure_type(type_name_of(v))
                            end
                        end
                    end
                end
            end
        end
    end
end

local last_vals, changes, snap_a, snap_b, diff = {}, {}, nil, nil, {}
local status, scan_info, type_info = "idle: enter gameplay, press Full Scan", "not scanned", "types: 0"
local tick, tracked = 0, 0

local function current_rows()
    local prow = resolve_player_roots()
    local all_roots = {}
    for _, r in ipairs(roots) do all_roots[#all_roots + 1] = r end
    for _, r in ipairs(prow) do all_roots[#all_roots + 1] = r end
    if #all_roots == 0 then return nil, "no roots (load a save / enter gameplay)" end
    local rows, visited = {}, {}
    for _, r in ipairs(all_roots) do
        if r.label:sub(1, 10) == "GameObject" or r.label == "GameObject" then
            dump_components(r.obj, rows, visited)
        end
        walk(r.obj, r.label, 0, cfg.depth, visited, rows)
        if #rows >= MAX_TRACKED then break end
    end
    -- Also dump components of S: roots that expose a GameObject.
    for _, r in ipairs(all_roots) do
        local go = try_call(r.obj, "get_GameObject")
        if is_managed_object(go) then dump_components(go, rows, visited) end
        if #rows >= MAX_TRACKED then break end
    end
    return rows, nil
end

local function count_registry()
    local nt, nm, nf, ne = 0, 0, 0, 0
    for _, e in pairs(type_registry) do
        nt = nt + 1
        nm = nm + #e.methods
        nf = nf + #e.fields
        ne = ne + #e.enums
    end
    return nt, nm, nf, ne
end

local function full_scan()
    type_registry, frontier = {}, {}
    n_methods_total, n_fields_total = 0, 0
    run_label = read_inv_mode()
    seed_targeted_types()
    discover_singletons()
    expand_frontier()
    seed_targeted_types()
    local rows, err = current_rows()
    if rows == nil then
        status = "scan failed: " .. tostring(err)
        L(status)
        return
    end
    expand_frontier()
    seed_targeted_types()
    expand_frontier()
    read_hp_pair()
    last_vals = {}
    for _, r in ipairs(rows) do
        if r.kind == "number" or r.kind == "string" or r.kind == "boolean" or r.kind == "getter" then
            last_vals[r.path] = r.value
        end
    end
    tracked = 0
    for _ in pairs(last_vals) do tracked = tracked + 1 end
    changes = {}
    local nt, nm, nf = count_registry()
    type_info = string.format("types %d, methods %d, fields %d (filter %s)", nt, nm, nf, cfg.filter)
    scan_info = string.format("%d values, %d roots, depth %d [run %s]", tracked, #roots, cfg.depth, run_label)
    status = "scanned: " .. scan_info .. " | " .. type_info
    L(status)
end

local function snapshot(slot)
    local rows, err = current_rows()
    if rows == nil then
        status = "snapshot failed: " .. tostring(err)
        L(status)
        return
    end
    local map = {}
    for _, r in ipairs(rows) do
        if type(r.value) == "number" or type(r.value) == "string" or type(r.value) == "boolean" then
            map[r.path] = r.value
        end
    end
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    if slot == "A" then
        snap_a, snap_b, diff = map, nil, {}
        status = string.format("Snapshot A stored (%d values). Change state, then Snapshot B.", n)
    else
        if snap_a == nil then status = "take Snapshot A first" return end
        snap_b = map
        diff = {}
        for path, va in pairs(snap_a) do
            local vb = snap_b[path]
            if type(vb) == "number" and type(va) == "number" and vb ~= va then
                diff[#diff + 1] = { path = path, before = va, after = vb, delta = vb - va }
            end
        end
        table.sort(diff, function(a, b) return math.abs(a.delta) > math.abs(b.delta) end)
        status = string.format("compared: %d changed number(s).", #diff)
    end
    L(status)
end

local function dump_all()
    local nt, nm, nf, ne = count_registry()
    run_label = read_inv_mode()
    read_hp_pair()
    local suffix = "_" .. tostring(run_label)
    local tfile = "param_dump_types" .. suffix .. ".json"
    local vfile = "param_dump_values" .. suffix .. ".json"
    local cfile = "param_dump_census" .. suffix .. ".json"
    local ok1 = pcall(json.dump_file, OUT_TYPES,
        { meta = { mod = MOD, version = VERSION, build = build, filter = cfg.filter, run = run_label,
            hp = hp_last, maxhp = hpmax_last, hmgr = hmgr_step,
            types = nt, methods = nm, fields = nf, enums = ne }, types = type_registry })
    pcall(json.dump_file, tfile,
        { meta = { mod = MOD, version = VERSION, build = build, filter = cfg.filter, run = run_label,
            types = nt, methods = nm, fields = nf, enums = ne }, types = type_registry })
    local diff_top, ch_top = {}, {}
    for i = 1, math.min(#diff, 300) do diff_top[i] = diff[i] end
    for i = 1, math.min(#changes, 300) do ch_top[i] = changes[i] end
    local ok2 = pcall(json.dump_file, OUT_VALUES,
        { meta = { tick = tick, tracked = tracked, run = run_label, hp = hp_last, maxhp = hpmax_last },
            diff_top = diff_top, changes_top = ch_top,
          snapshot_a_count = snap_a and (function() local n=0 for _ in pairs(snap_a) do n=n+1 end return n end)() or 0 })
    pcall(json.dump_file, vfile,
        { meta = { tick = tick, tracked = tracked, run = run_label, hp = hp_last, maxhp = hpmax_last },
            diff_top = diff_top, changes_top = ch_top,
          snapshot_a_count = snap_a and (function() local n=0 for _ in pairs(snap_a) do n=n+1 end return n end)() or 0 })
    local ok3 = pcall(json.dump_file, OUT_CENSUS,
        { meta = { mod = MOD, version = VERSION, build = build, run = run_label }, census = census,
          scan = scan_info, types = type_info, hp = hp_last, maxhp = hpmax_last })
    pcall(json.dump_file, cfile,
        { meta = { mod = MOD, version = VERSION, build = build, run = run_label }, census = census,
          scan = scan_info, types = type_info, hp = hp_last, maxhp = hpmax_last })
    status = (ok1 and ok2 and ok3) and ("dumped [run " .. run_label .. "] " .. tfile .. " + " .. vfile .. " + " .. cfile
        .. string.format(" (%d types / %d methods / %d fields)", nt, nm, nf))
        or "dump failed (see log)"
    L(status)
end

re.on_frame(function()
    tick = tick + 1
    if not cfg.tracing then return end
    if tick % 5 ~= 0 then return end
    if next(last_vals) == nil then return end
    local rows, err = current_rows()
    if rows == nil then return end
    read_hp_pair()
    for _, r in ipairs(rows) do
        if #changes >= MAX_TRACKED then break end
        if is_noisy(r.path) then
            -- v1.2: keep list-version/capacity counters out of the 300 slots.
            if last_vals[r.path] == nil then last_vals[r.path] = r.value
            else last_vals[r.path] = r.value end
        elseif r.kind == "number" or r.kind == "getter" then
            local last = last_vals[r.path]
            if last == nil then last_vals[r.path] = r.value
            elseif r.value ~= last then
                changes[#changes + 1] = { path = r.path, before = last, after = r.value,
                    delta = (type(r.value) == "number" and type(last) == "number") and (r.value - last) or 0,
                    tick = tick }
                last_vals[r.path] = r.value
                if #changes <= 5 or #changes % 500 == 0 then
                    L(string.format("chg %s : %s -> %s", r.path, tostring(last), tostring(r.value)))
                end
            end
        elseif r.kind == "string" or r.kind == "boolean" then
            local last = last_vals[r.path]
            if last == nil then last_vals[r.path] = r.value
            elseif r.value ~= last then
                changes[#changes + 1] = { path = r.path, before = last, after = r.value, delta = 0, tick = tick }
                last_vals[r.path] = r.value
            end
        end
    end
    tracked = 0
    for _ in pairs(last_vals) do tracked = tracked + 1 end
end)

local function short(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local FILTER_ORDER = { "ALL", "HIT", "HP", "PLAYER", "SYSTEM" }
local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION .. " FULL") then return end
        imgui.text(string.format("Build: %s %s tdb %s [run %s]", build.game, build.tag, build.tdb, run_label))
        imgui.text("Status: " .. status)
        if hp_last ~= nil and hpmax_last ~= nil then
            imgui.text(string.format("HP: %s / %s (%s)", tostring(hp_last), tostring(hpmax_last), hmgr_step))
        else
            imgui.text("HP: -- (manager: " .. hmgr_step .. ")")
        end
        imgui.text("Scan: " .. scan_info)
        imgui.text("Types: " .. type_info .. " | tracked " .. tostring(tracked)
            .. " | changes " .. tostring(#changes))
        local ch, v = imgui.checkbox("Trace changes (1/5 frames)", cfg.tracing)
        if ch then cfg.tracing = v save_cfg() end
        local chd, vd = imgui.slider_int("Walk depth", cfg.depth, 1, 4)
        if chd then cfg.depth = vd save_cfg() L("depth=" .. tostring(vd) .. " (rescan)") end
        imgui.text("Filter: " .. cfg.filter)
        for _, f in ipairs(FILTER_ORDER) do
            if imgui.button(f) then
                cfg.filter = f
                save_cfg()
                L("filter=" .. f .. " (rescan to apply)")
            end
            imgui.same_line()
        end
        imgui.new_line()
        if imgui.button("Full Scan") then full_scan() end
        imgui.same_line()
        if imgui.button("Snapshot A") then snapshot("A") end
        imgui.same_line()
        if imgui.button("Snapshot B") then snapshot("B") end
        imgui.same_line()
        if imgui.button("Dump All JSON") then dump_all() end
        if imgui.button("Reset") then
            last_vals, changes, snap_a, snap_b, diff = {}, {}, nil, nil, {}
            field_cache, type_registry, frontier = {}, {}, {}
            census, roots = {}, {}
            hp_last, hpmax_last, hmgr_step = nil, nil, "-"
            run_label = read_inv_mode()
            tick, tracked = 0, 0
            scan_info, type_info = "not scanned", "types: 0"
            status = "reset. Press Full Scan."
            L("reset")
        end
        if imgui.tree_node("Coverage (singletons)") then
            if #census == 0 then imgui.text("Not scanned yet.")
            else
                for i = 1, #census do
                    local c = census[i]
                    imgui.text((c.found and "+ " or "- ") .. c.name .. " (" .. c.typename .. ")")
                end
            end
            imgui.tree_pop()
        end
        if imgui.tree_node("Type registry (first 60)") then
            local n = 0
            for fname, e in pairs(type_registry) do
                n = n + 1
                if n > 60 then imgui.text("... more in " .. OUT_TYPES) break end
                imgui.text(string.format("%s : %d methods / %d fields / %d enums",
                    short(fname, 70), #e.methods, #e.fields, #e.enums))
            end
            if n == 0 then imgui.text("Empty. Press Full Scan in gameplay.") end
            imgui.tree_pop()
        end
        if #diff > 0 and imgui.tree_node("Diff A->B (top 40)") then
            for i = 1, math.min(#diff, 40) do
                local d = diff[i]
                imgui.text(string.format("%d. %s : %s -> %s", i, short(d.path, 90),
                    tostring(d.before), tostring(d.after)))
            end
            imgui.tree_pop()
        end
        if #changes > 0 and imgui.tree_node("Live changes (latest 40)") then
            local start = math.max(1, #changes - 39)
            for i = start, #changes do
                local c = changes[i]
                imgui.text(short(c.path, 90) .. " : " .. tostring(c.before) .. " -> " .. tostring(c.after))
            end
            imgui.tree_pop()
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_script_reset(function()
    field_cache, last_vals, changes = {}, {}, {}
    snap_a, snap_b, diff = nil, nil, {}
    census, roots, type_registry, frontier = {}, {}, {}, {}
    n_methods_total, n_fields_total = 0, 0
    hp_last, hpmax_last, hmgr_step = nil, nil, "-"
    run_label = "UNKNOWN"
    tick, tracked = 0, 0
    scan_info, type_info = "not scanned", "types: 0"
    status = "reset by script reset. Press Full Scan."
end)

re.on_config_save(function() save_cfg() end)

L("loaded v" .. VERSION .. " (FULL function dump v1.2: seeds+healthchain+noisefilter+runlabel, read-only)")
