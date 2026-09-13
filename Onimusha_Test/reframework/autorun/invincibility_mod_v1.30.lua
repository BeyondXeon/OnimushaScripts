-- Invincibility v1.30 -- Onimusha: Way of the Sword, REFramework Lua autorun.
-- v1.30: perf pass, no behavior change. Restore-engine walk 3rd tick ->
-- 6th tick (halves its game calls; 100ms restore latency is invisible on
-- bars, HP refill still runs every frame) and HP readout 15 -> 30 ticks.
--
-- v1.29: Stagger Bar is fully independent. Off disables invincibility but
-- leaves the tickbox alone; the bar stays pinned until unticked. No Hit /
-- Inf HP arm invincibility. Death guard runs while invincibility is on.
--
-- Menu: REFramework -> ScriptRunner -> "Invincibility v1.30".
-- Config: reframework/data/invincibility_mod.json (stable across versions).

local MOD, VERSION, CFG_FILE = "Invincibility", "1.30", "invincibility_mod.json"
local PROOF_FILE = "poise_proof.json"
local TAG = "[" .. MOD .. "] "
local GUARD_RETRY_TICKS = 300
local NO_HIT_FALLBACK = 7308 -- dump-proven app.PlayerNoHitLevel NO_HIT

local function L(msg) log.info(TAG .. tostring(msg)) end

local MODES = { nohit = true, infhp = true, off = true }

local cfg = { enabled = true, mode = "infhp", spoof_value = 2, poise = true }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        if type(saved.enabled) == "boolean" then cfg.enabled = saved.enabled end
        if type(saved.mode) == "string" and MODES[saved.mode] then cfg.mode = saved.mode end
        if type(saved.spoof_value) == "number" then
            cfg.spoof_value = math.max(0, math.min(10, math.floor(saved.spoof_value)))
        end
        if type(saved.poise) == "boolean" then cfg.poise = saved.poise end
        if cfg.spoof_value == 1 then cfg.spoof_value = 2 end
    else
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

local function try_field(obj, name)
    if obj == nil then return nil end
    local ok, r = pcall(obj.get_field, obj, name)
    if ok then return r end
    return nil
end

local function try_any(obj, names)
    if obj == nil or type(names) ~= "table" then return nil end
    for _, name in ipairs(names) do
        local ok, r = pcall(obj.call, obj, name)
        if ok and r ~= nil then return r end
    end
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

local function enum_number(type_name, field_name, fallback)
    local ok_td, td = pcall(sdk.find_type_definition, type_name)
    if ok_td and td ~= nil then
        local ok_f, f = pcall(td.get_field, td, field_name)
        if ok_f and f ~= nil then
            local okv, v = pcall(f.get_data, f, nil)
            if okv and type(v) == "number" then return v end
        end
    end
    return fallback
end

-- Player handles.
local mi, chara, entity, pgo, go_addr = nil, nil, nil, nil, 0
local resolve_cooldown = 0
local hmgr, hmgr_step, hp_last, hpmax_last = nil, "-", nil, nil
local deaths_blocked, poise_blocked, hit_spoofed, pre_spoofed = 0, 0, 0, 0
local poise_log_n, hp_blocks, hp_log_n = 0, 0, 0
-- v1.26 silent proof outbox (log.info goes nowhere: the game log is empty).
local proof = { gates = {}, stock_attached = false, stock_fires = 0,
    break_fires = 0, break_skips = 0, tired_evals = 0,
    restore_n = 0, restore_key = "-", gauge_found = false, gauge_step = "-",
    hp_blocks = 0, hp_hook = "-" }
-- NOTE: write_proof is defined just before re.on_frame (after ALL state),
-- so every read binds to chunk locals. Defining it here would silently read
-- globals (this exact defect hid mod:0 for six versions).
local last_event = "-"
-- v1.21 slow-tick address caches: hooks compare integers instead of doing
-- type lookups and string compares on every fire.
local entity_addr_cache, inv_addr_cache, tired_owner_cache = 0, 0, 0
local nodamage_entity_addr = 0
local poise_mod_logged = 0
-- v1.27: poise_mod_addr MUST be declared here (before refresh_addr_cache).
-- It used to be declared after its writer, so refresh wrote a global 0 and
-- every gate read a permanent-zero local: all gates silently dead v1.20-26.
local poise_mod_addr = 0
-- v1.28: player HealthManager address for write-prevention gating.
local hmgr_addr_cache = 0
-- Restore-engine tables live here (before resolve_player) so the
-- player-change branch can clear them without hitting globals.
local restore_cache, restore_last, restore_abuse, restore_raise, restore_black = {}, {}, {}, {}, {}
local restore_tracked = 0
local tick = 0 -- single frame counter; restore abuse/refill windows use it.

local function note_event(msg)
    last_event = msg
    L(msg)
end

local function resolve_player()
    if resolve_cooldown > 0 then resolve_cooldown = resolve_cooldown - 1 return chara ~= nil end
    resolve_cooldown = 60
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local nmi = pm and try_call(pm, "getControllingPlayer") or nil
    if nmi == nil and pm ~= nil then nmi = try_call(pm, "getControllingPlayerInfo") end
    if nmi == nil then return false end
    local ngo = try_call(nmi, "get_Object")
    if ngo == nil then return false end
    if ngo:get_address() ~= go_addr then
        mi, chara, entity, pgo, go_addr = nmi, nil, nil, ngo, ngo:get_address()
        hmgr, hmgr_step, hp_last, hpmax_last = nil, "-", nil, nil
        restore_cache, restore_last, restore_abuse, restore_raise, restore_black = {}, {}, {}, {}, {}
        restore_tracked = 0
        entity_addr_cache, inv_addr_cache, tired_owner_cache = 0, 0, 0
        L("player resolved: " .. tostring(try_call(ngo, "get_Name")))
    else
        mi = nmi
    end
    chara = try_call(mi, "get_Character")
    entity = try_call(mi, "get_CharacterEntity")
    return chara ~= nil
end

local function find_health_on(obj)
    if not is_managed_object(obj) then return nil end
    local mgr = try_any(obj, { "get_HealthManager", "get_HealthMgr" })
        or try_field(obj, "<HealthManager>k__BackingField")
    if is_managed_object(mgr) then return mgr end
    return nil
end

local function resolve_health_mgr()
    if hmgr ~= nil and is_managed_object(hmgr) then return hmgr end
    hmgr, hmgr_step = nil, "-"
    local mgr = find_health_on(mi)
    if mgr then hmgr, hmgr_step = mgr, "player-info" end
    if hmgr == nil then
        mgr = find_health_on(chara)
        if mgr then hmgr, hmgr_step = mgr, "character" end
    end
    if hmgr == nil then
        mgr = find_health_on(entity)
        if mgr then hmgr, hmgr_step = mgr, "entity" end
    end
    if hmgr == nil then
        local ctx = try_any(chara, { "get_Context", "get_ContextParam", "get_Param" })
        mgr = find_health_on(ctx)
        if mgr then hmgr, hmgr_step = mgr, "context" end
    end
    if hmgr == nil then
        local holder = try_any(mi, { "get_ContextHolder" })
            or try_field(mi, "_ContextHolder")
            or try_any(chara, { "get_ContextHolder" })
            or try_field(chara, "_ContextHolder")
        mgr = find_health_on(holder)
        if mgr then hmgr, hmgr_step = mgr, "context-holder" end
        if hmgr == nil then
            local core = try_field(holder, "_ContextCore")
                or try_any(holder, { "get_ContextCore" })
            mgr = find_health_on(core)
            if mgr then hmgr, hmgr_step = mgr, "context-core" end
        end
        if hmgr == nil then
            local contexts = try_field(holder, "Contexts") or try_any(holder, { "get_Contexts" })
            if contexts ~= nil then
                local ok, n = pcall(function() return contexts:get_size() end)
                if ok and type(n) == "number" then
                    for i = 0, math.min(n - 1, 31) do
                        local ctx = nil
                        pcall(function() ctx = contexts:get_element(i) end)
                        mgr = find_health_on(ctx)
                        if mgr then hmgr, hmgr_step = mgr, "contexts[" .. tostring(i) .. "]" break end
                    end
                end
            end
        end
    end
    if hmgr == nil and pgo ~= nil then
        local rt = nil
        pcall(function() rt = sdk.typeof("app.cHealthManager") end)
        if rt ~= nil then
            mgr = try_call(pgo, "getComponent(System.Type)", rt)
            if is_managed_object(mgr) then hmgr, hmgr_step = mgr, "gameobject-component" end
        end
    end
    return hmgr
end

-- Cached cHealthManager methods (no per-frame hashmap lookup).
local HM_METHODS = { "get_Health", "get_MaxHealth", "get_TotalHealth", "setHealth", "set_Health" }
local hm_cache = {}
local function cache_health_methods()
    local ok_td, td = pcall(sdk.find_type_definition, "app.cHealthManager")
    if not ok_td or td == nil then return end
    for _, name in ipairs(HM_METHODS) do
        local ok_m, m = pcall(td.get_method, td, name)
        if ok_m and m ~= nil then hm_cache[name] = m end
    end
end
local function cached_call(mgr, name)
    local m = hm_cache[name]
    if m == nil or mgr == nil then return nil end
    local ok, r = pcall(m.call, m, mgr)
    if ok then return r end
    return nil
end
local function cached_void(mgr, name, arg)
    local m = hm_cache[name]
    if m == nil or mgr == nil then return false end
    return pcall(m.call, m, mgr, arg)
end

local function read_hp_pair()
    local mgr = resolve_health_mgr()
    if mgr == nil then return nil, nil end
    local hp = cached_call(mgr, "get_Health") or try_any(mgr, { "get_Health", "get_TotalHealth" })
    local max_hp = cached_call(mgr, "get_MaxHealth") or try_any(mgr, { "get_MaxHealth", "get_TotalMaxHealth" })
    if type(hp) == "number" and type(max_hp) == "number" then
        hp_last, hpmax_last = hp, max_hp
        return hp, max_hp
    end
    return nil, nil
end

local function refill_health()
    local mgr = resolve_health_mgr()
    if mgr == nil then return false end
    local max_hp = cached_call(mgr, "get_MaxHealth")
    if type(max_hp) ~= "number" then
        max_hp = try_any(mgr, { "get_MaxHealth", "get_TotalMaxHealth" })
    end
    if type(max_hp) ~= "number" then return false end
    if not cached_void(mgr, "setHealth", max_hp) then
        pcall(function() mgr:call("setHealth", max_hp) end)
    end
    if not cached_void(mgr, "set_Health", max_hp) then
        pcall(function() mgr:call("set_Health", max_hp) end)
    end
    return true
end

local function mode_refills()
    return cfg.enabled and cfg.mode ~= "off"
end

-- Restore engine (v1.18 behavior, restored in v1.24): re-tops any dropping
-- numeric field on the player objects. This is what pinned the stagger bar
-- before targeted hooks replaced it and missed the fill path.
local EPS = 1e-6
local MIN_DROP = 5.0
local RATIO_DROP = 0.05
local MIN_INT = 50
local MAX_INT = 100000
local MAX_RTRACKED = 800
local ABUSE_WINDOW, ABUSE_LIMIT = 120, 8
local REFILL_WINDOW, REFILL_LIMIT = 300, 10

local BLOCKED = {
    "absorb", "soul", "timer", "time", "frame", "motion", "speed", "velo",
    "pos", "cool", "interval", "rate", "count", "index",
    "rotate", "rot", "camera", "input", "angle", "quat", "euler",
}
local function is_blocked(key)
    local k = key:lower()
    for _, b in ipairs(BLOCKED) do
        if k:find(b, 1, true) then return true end
    end
    return false
end

local INTEREST = {
    "gauge", "status", "param", "vital", "hit", "life", "hp", "health",
    "body", "player", "chara", "data", "control", "manage", "point",
}
local function is_interesting(fname)
    local n = fname:lower()
    for _, k in ipairs(INTEREST) do
        if n:find(k, 1, true) then return true end
    end
    return false
end

-- HP names are skipped unless a refill mode is on: standalone Poise must
-- never pin HP. "hp" matches as a token only, to avoid false hits.
local HP_KEYS = { "health", "maxhealth", "totalhealth", "hitpoint", "vital", "life" }
local function is_hp_key(key)
    local k = key:lower()
    for _, h in ipairs(HP_KEYS) do
        if k:find(h, 1, true) then return true end
    end
    for tok in k:gmatch("[^%.@_]+") do
        if tok == "hp" then return true end
    end
    return false
end

local function type_allowed(typename, value)
    if typename == nil or typename == "?" then return true end
    local t = typename:lower()
    if t:sub(1, 7) ~= "system." then return false end
    if t:find("bool", 1, true) then return false end
    if t:find("enum", 1, true) then return false end
    if t:find("char", 1, true) then return false end
    if t:find("single", 1, true) or t:find("double", 1, true)
        or t:find("float", 1, true) or t:find("half", 1, true)
        or t:find("decimal", 1, true) then
        return true
    end
    if t:find("int", 1, true) or t:find("uint", 1, true)
        or t:find("short", 1, true) or t:find("ushort", 1, true)
        or t:find("byte", 1, true) or t:find("sbyte", 1, true)
        or t:find("long", 1, true) or t:find("ulong", 1, true) then
        return value >= MIN_INT and value <= MAX_INT
    end
    return true
end

local function restore_blacklist(key, why)
    if restore_black[key] then return end
    restore_black[key] = true
    restore_last[key] = nil
    restore_abuse[key] = nil
    restore_raise[key] = nil
end

local function restore_defs(obj)
    if obj == nil then return {} end
    local tname = type_name_of(obj)
    local hit = restore_cache[tname]
    if hit ~= nil then return hit end
    hit = {}
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if ok_td and td ~= nil then
        local okf, fields = pcall(td.get_fields, td)
        if okf and fields ~= nil then
            for _, f in pairs(fields) do
                local fname = nil
                pcall(function() fname = f:get_name() end)
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
    restore_cache[tname] = hit
    return hit
end

local function note_restore(key)
    local a = restore_abuse[key]
    if a == nil then
        restore_abuse[key] = { n = 1, window_start = tick }
        return
    end
    if tick - a.window_start > ABUSE_WINDOW then
        restore_abuse[key] = { n = 1, window_start = tick }
        return
    end
    a.n = a.n + 1
    if a.n > ABUSE_LIMIT then restore_blacklist(key, "timer-like") end
end

local function note_raise(key)
    local r = restore_raise[key]
    if r == nil then
        restore_raise[key] = { n = 1, window_start = tick }
        return
    end
    if tick - r.window_start > REFILL_WINDOW then
        restore_raise[key] = { n = 1, window_start = tick }
        return
    end
    r.n = r.n + 1
    if r.n > REFILL_LIMIT then restore_blacklist(key, "refilling gauge") end
end

local function observe_number(key, holder, fname, ftypename)
    if restore_black[key] or is_blocked(key) then return end
    if not mode_refills() and is_hp_key(key) then return end
    local okv, v = pcall(holder.get_field, holder, fname)
    if not okv or type(v) ~= "number" then return end
    if v ~= v then return end
    if v < 0 then return end
    if not type_allowed(ftypename, v) then return end
    local last = restore_last[key]
    if last == nil then
        if restore_tracked < MAX_RTRACKED then
            restore_last[key] = v
            restore_tracked = restore_tracked + 1
        end
        return
    end
    local threshold = MIN_DROP
    if last >= 0 and last <= 1.0 and v >= 0 and v <= 1.0 then threshold = RATIO_DROP end
    local drop = last - v
    if drop > threshold then
        if pcall(holder.set_field, holder, fname, last) then
            proof.restore_n = proof.restore_n + 1
            proof.restore_key = key
            note_restore(key)
        else
            restore_last[key] = v
        end
    elseif v > last + EPS then
        restore_last[key] = v
        note_raise(key)
    end
end

local function guard_object(obj, label, depth)
    if obj == nil then return end
    if depth > 2 then return end
    local addr = obj:get_address()
    local defs = restore_defs(obj)
    for i = 1, #defs do
        local d = defs[i]
        observe_number(label .. "@" .. tostring(addr) .. "." .. d.name, obj, d.name, d.tname)
    end
    if depth >= 2 then return end
    for i = 1, #defs do
        local cfname = defs[i].name
        local okc, child = pcall(obj.get_field, obj, cfname)
        if okc and is_managed_object(child) then
            local cdefs = restore_defs(child)
            for j = 1, #cdefs do
                local gd = cdefs[j]
                observe_number(label .. "@" .. tostring(addr) .. "." .. cfname .. "." .. gd.name,
                    child, gd.name, gd.tname)
                if restore_tracked >= MAX_RTRACKED then return end
            end
            if depth == 0 and is_interesting(cfname) then
                for j = 1, #cdefs do
                    local gfname = cdefs[j].name
                    if is_interesting(gfname) then
                        local okg, grand = pcall(child.get_field, child, gfname)
                        if okg and is_managed_object(grand) then
                            local gdefs = restore_defs(grand)
                            for k = 1, #gdefs do
                                local hd = gdefs[k]
                                observe_number(label .. "@" .. tostring(addr) .. "." .. cfname
                                    .. "." .. gfname .. "." .. hd.name,
                                    grand, hd.name, hd.tname)
                                if restore_tracked >= MAX_RTRACKED then return end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function reset_restore()
    restore_cache, restore_last, restore_abuse, restore_raise, restore_black = {}, {}, {}, {}, {}
    restore_tracked = 0
end

local function no_hit_level()
    return enum_number("app.PlayerNoHitLevel.TYPE_Fixed", "NO_HIT", NO_HIT_FALLBACK)
end

local function get_invincible()
    if entity == nil then return nil end
    local inv = try_any(entity, { "get_InvincibleSupporter" })
        or try_field(entity, "<InvincibleSupporter>k__BackingField")
    if is_managed_object(inv) then return inv end
    return nil
end

local function set_no_hit(on)
    local inv = get_invincible()
    if inv == nil then return false end
    if on then
        local level = no_hit_level()
        pcall(function() inv:call("requestNoHit", level) end)
        pcall(function() inv:call("requestHighestNoHit") end)
        pcall(function() inv:set_field("_RequestNoHitLevel", level) end)
        pcall(function() inv:set_field("_CurrentNoHitLevel", level) end)
    else
        pcall(function() inv:set_field("_RequestNoHitLevel", 0) end)
        pcall(function() inv:set_field("_CurrentNoHitLevel", 0) end)
    end
    return true
end

local function apply_nodamage()
    if entity == nil then return end
    -- v1.21: once per entity instead of every few ticks.
    local addr = entity:get_address()
    if addr == nodamage_entity_addr then return end
    if pcall(entity.call, entity, "setControllingPlayerNoDamage") then
        nodamage_entity_addr = addr
    end
end

local function player_entity_addr()
    if entity_addr_cache ~= 0 then return entity_addr_cache end
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local lmi = pm and try_call(pm, "getControllingPlayer") or nil
    if lmi == nil and pm ~= nil then lmi = try_call(pm, "getControllingPlayerInfo") end
    local lent = lmi and try_call(lmi, "get_CharacterEntity") or nil
    if lent ~= nil then return lent:get_address() end
    return 0
end

-- v1.21 slow-tick refresh: one pass fills every address cache hooks use.
local function refresh_addr_cache()
    entity_addr_cache = 0
    if entity ~= nil then
        pcall(function() entity_addr_cache = entity:get_address() end)
    end
    if entity_addr_cache == 0 then entity_addr_cache = player_entity_addr() end
    inv_addr_cache = 0
    local inv = get_invincible()
    if inv ~= nil then
        pcall(function() inv_addr_cache = inv:get_address() end)
    end
    poise_mod_addr = 0
    if entity ~= nil then
        local mod = try_field(entity, "_DamageInterface")
        if is_managed_object(mod) then
            pcall(function() poise_mod_addr = mod:get_address() end)
        end
    end
    if poise_mod_addr ~= poise_mod_logged then
        poise_mod_logged = poise_mod_addr
        L("poise module addr=" .. tostring(poise_mod_addr)
            .. " entity=" .. tostring(entity_addr_cache))
    end
    -- v1.28: player HealthManager address for write-prevention gating.
    hmgr_addr_cache = 0
    local hm = resolve_health_mgr()
    if hm ~= nil then
        pcall(function() hmgr_addr_cache = hm:get_address() end)
    end
end

-- Death guard: onDie SKIP, player-only, always armed.
local dieguard_armed = false
local function install_die_guard()
    if dieguard_armed then return end
    local ok_td, td = pcall(sdk.find_type_definition, "app.cPlayerCharacterEntity")
    if not ok_td or td == nil then return end
    local ok_m, m = pcall(td.get_method, td, "onDie")
    if not ok_m or m == nil then return end
    local skip = sdk.PreHookResult and sdk.PreHookResult.SKIP_ORIGINAL or nil
    if skip == nil then return end
    local ok_h = pcall(sdk.hook, m, function(args)
        local result = sdk.PreHookResult.CALL_ORIGINAL
        pcall(function()
            if not cfg.enabled then return end
            local dying = sdk.to_int64(args[2])
            if dying == 0 then return end
            local live = player_entity_addr()
            local cached = (entity ~= nil) and entity:get_address() or 0
            if dying == live or (cached ~= 0 and dying == cached) then
                deaths_blocked = deaths_blocked + 1
                note_event("death blocked #" .. tostring(deaths_blocked))
                result = skip
            end
        end)
        return result
    end, function(retval)
        return retval
    end)
    if ok_h then dieguard_armed = true L("die guard ARMED") end
end

-- Second net: DieSupporter.checkDie/requestGameOver, player-only.
local die2_armed = false
local function install_die2_guard()
    if die2_armed then return end
    local ok_td, td = pcall(sdk.find_type_definition, "app.cPlayerDieSupporter")
    if not ok_td or td == nil then return end
    local skip = sdk.PreHookResult and sdk.PreHookResult.SKIP_ORIGINAL or nil
    if skip == nil then return end
    local hooked = 0
    for _, mname in ipairs({ "checkDie", "requestGameOver" }) do
        local ok_m, m = pcall(td.get_method, td, mname)
        if ok_m and m ~= nil then
            local ok_h = pcall(sdk.hook, m, function(args)
                local result = sdk.PreHookResult.CALL_ORIGINAL
                pcall(function()
                    if not cfg.enabled then return end
                    if player_entity_addr() == 0 then return end
                    if mname == "checkDie" then
                        local hp = cached_call(resolve_health_mgr(), "get_Health")
                        if type(hp) == "number" and hp > 0 and mode_refills() then
                            deaths_blocked = deaths_blocked + 1
                            note_event("death blocked #" .. tostring(deaths_blocked))
                            result = skip
                        end
                    else
                        deaths_blocked = deaths_blocked + 1
                        note_event("death blocked #" .. tostring(deaths_blocked))
                        result = skip
                    end
                end)
                return result
            end, function(retval)
                return retval
            end)
            if ok_h then hooked = hooked + 1 end
        end
    end
    if hooked > 0 then die2_armed = true L("die2 guard ARMED") end
end

-- No-Hit: checkNoHit forced true, ONLY player's own supporter type.
local function player_invincible_holder(obj)
    if obj == nil then return false end
    local ok, td = pcall(obj.get_type_definition, obj)
    return ok and td ~= nil and td:get_full_name() == "app.cPlayerInvincibleSupporter"
end

local function install_nohit_hook(method)
    if method == nil then return false end
    return pcall(sdk.hook, method, function(args)
        local st = thread.get_hook_storage()
        st.force = false
        -- v1.21: integer compare against the cached supporter address.
        -- Falls back to the type check only while the cache is empty.
        local this_addr = sdk.to_int64(args[2])
        if inv_addr_cache ~= 0 then
            if cfg.enabled and cfg.mode == "nohit" and this_addr == inv_addr_cache then
                st.force = true
            end
        else
            pcall(function()
                if not (cfg.enabled and cfg.mode == "nohit") then return end
                if player_invincible_holder(sdk.to_managed_object(args[2])) then
                    st.force = true
                end
            end)
        end
        if st.force then return sdk.PreHookResult.SKIP_ORIGINAL end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local st = thread.get_hook_storage()
        if st.force then
            st.force = false
            return sdk.to_ptr(1)
        end
        return retval
    end)
end

local function safe_method(td, name)
    if td == nil then return nil end
    local ok, m = pcall(td.get_method, td, name)
    if ok then return m end
    return nil
end

local function install_nohit_hooks()
    local player_td = sdk.find_type_definition("app.cPlayerInvincibleSupporter")
    if player_td ~= nil then
        install_nohit_hook(safe_method(player_td, "checkNoHit"))
        install_nohit_hook(safe_method(player_td,
            "checkNoHit(app.PlayerNoHitLevel.TYPE_Fixed, app.HitInfo)"))
    end
    local base_td = sdk.find_type_definition("app.cCharacterInvincibleSupporter")
    if base_td ~= nil then
        install_nohit_hook(safe_method(base_td, "checkNoHit"))
        install_nohit_hook(safe_method(base_td, "checkNoHit(app.HitInfo)"))
    end
    L("nohit hooks installed")
end

-- Hit-result spoof to PASS, player victims only.
local function mark_spoof_if_player_hit(args)
    local st = thread.get_hook_storage()
    st.spoof = false
    pcall(function()
        if not (cfg.enabled and cfg.mode == "nohit") then return end
        local info = sdk.to_managed_object(args[3])
        if info == nil then return end
        local victim = try_field(info, "<DamageCharacter>k__BackingField")
        if not is_managed_object(victim) then return end
        local va = victim:get_address()
        st.spoof = (chara ~= nil and va == chara:get_address())
            or (entity ~= nil and va == entity:get_address())
    end)
end

local function spoof_post(label)
    return function(retval)
        local st = thread.get_hook_storage()
        if st.spoof then
            st.spoof = false
            if label == "pre" then pre_spoofed = pre_spoofed + 1
            else hit_spoofed = hit_spoofed + 1 end
            return sdk.to_ptr(cfg.spoof_value)
        end
        return retval
    end
end

local function install_result_spoofs()
    local ok_td, td = pcall(sdk.find_type_definition, "app.cPlayerCharacterEntity")
    if not ok_td or td == nil then return end
    local ok_pre, mpre = pcall(td.get_method, td, "evHitDamagePreProcess")
    if ok_pre and mpre ~= nil then
        pcall(sdk.hook, mpre, function(args)
            mark_spoof_if_player_hit(args)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, spoof_post("pre"))
    end
    local ok_proc, mproc = pcall(td.get_method, td, "evHitDamageProcess")
    if ok_proc and mproc ~= nil then
        pcall(sdk.hook, mproc, function(args)
            mark_spoof_if_player_hit(args)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, spoof_post("proc"))
    end
end

-- Poise: Rikido gauge never fills on the player, break never starts,
-- tired state forced off. All gates compare the player's own damage-module
-- / entity address, so enemies are untouched by construction.
-- Rikido gauge hunter: pins the live gauge object's numeric fields to
-- max-seen (HP-refill pattern, scoped to that one object). Found two ways:
-- field-type scan for app.cRikidoGuage, or harvested from break args.
local rgauge, rgauge_fields, rgauge_last, rgauge_step, rg_cool = nil, {}, {}, "-", 0
local function cache_gauge_fields(g)
    rgauge_fields, rgauge_last = {}, {}
    local ok_td, td = pcall(g.get_type_definition, g)
    if not ok_td or td == nil then return end
    local okf, fields = pcall(td.get_fields, td)
    if not okf or fields == nil then return end
    for _, f in pairs(fields) do
        local fname = nil
        pcall(function() fname = f:get_name() end)
        if type(fname) == "string" then
            local v = try_field(g, fname)
            if type(v) == "number" and v == v then
                rgauge_fields[#rgauge_fields + 1] = fname
                rgauge_last[fname] = v
            end
        end
    end
end
local function claim_gauge(g, how)
    if not is_managed_object(g) then return end
    if type_name_of(g) ~= "app.cRikidoGuage" then return end
    local addr = g:get_address()
    if rgauge ~= nil and is_managed_object(rgauge) and rgauge:get_address() == addr then return end
    rgauge, rgauge_step = g, how
    cache_gauge_fields(g)
    proof.gauge_found = true
    proof.gauge_step = how
    L("rikido gauge found via " .. how .. " (" .. tostring(#rgauge_fields) .. " numeric fields)")
end
local function scan_gauge_field(obj, step)
    if not is_managed_object(obj) then return end
    local ok_td, td = pcall(obj.get_type_definition, obj)
    if not ok_td or td == nil then return end
    local okf, fields = pcall(td.get_fields, td)
    if not okf or fields == nil then return end
    for _, f in pairs(fields) do
        local fname, ftname = nil, "?"
        pcall(function() fname = f:get_name() end)
        pcall(function()
            local ft = f:get_type()
            if ft ~= nil then ftname = ft:get_full_name() end
        end)
        if type(fname) == "string" and ftname == "app.cRikidoGuage" then
            claim_gauge(try_field(obj, fname), step .. "." .. fname)
            if rgauge ~= nil then return end
        end
    end
end
local function find_gauge_obj()
    if rgauge ~= nil and is_managed_object(rgauge) then return rgauge end
    rgauge = nil
    if rg_cool > 0 then rg_cool = rg_cool - 1 return nil end
    rg_cool = 60
    scan_gauge_field(mi, "player-info")
    if rgauge == nil then scan_gauge_field(chara, "character") end
    if rgauge == nil then scan_gauge_field(entity, "entity") end
    return rgauge
end
local function topup_gauge()
    local g = find_gauge_obj()
    if g == nil then return false end
    if #rgauge_fields == 0 then cache_gauge_fields(g) end
    for _, fname in ipairs(rgauge_fields) do
        local okv, v = pcall(g.get_field, g, fname)
        if okv and type(v) == "number" and v == v then
            local last = rgauge_last[fname]
            if last == nil then
                rgauge_last[fname] = v
            elseif v < last then
                if pcall(g.set_field, g, fname, last) then
                    poise_blocked = poise_blocked + 1
                else
                    rgauge_last[fname] = v
                end
            elseif v > last then
                rgauge_last[fname] = v
            end
        end
    end
    return true
end

local poise_armed = false
local function install_poise_gate(td, mname)
    local ok_m, m = pcall(td.get_method, td, mname)
    if not ok_m or m == nil then
        L("poise gate " .. mname .. ": METHOD NOT FOUND")
        return false
    end
    local attached = pcall(sdk.hook, m, function(args)
        local st = thread.get_hook_storage()
        st.poise_gate = false
        pcall(function()
            if not cfg.poise then return end
            if poise_mod_addr == 0 then return end
            if sdk.to_int64(args[2]) == poise_mod_addr then st.poise_gate = true end
        end)
        if st.poise_gate then return sdk.PreHookResult.SKIP_ORIGINAL end
        return sdk.PreHookResult.CALL_ORIGINAL
    end, function(retval)
        local st = thread.get_hook_storage()
        if st.poise_gate then
            st.poise_gate = false
            poise_blocked = poise_blocked + 1
            proof.gates[mname].fires = (proof.gates[mname].fires or 0) + 1
            -- Proof log, capped: shows the gate actually fires in-game.
            if poise_log_n < 3 then
                poise_log_n = poise_log_n + 1
                L("poise: " .. mname .. " skipped x" .. tostring(poise_blocked))
            end
            return sdk.to_ptr(0) -- gate returns bool: false = damage not enabled
        end
        return retval
    end)
    proof.gates[mname] = { attached = attached, fires = 0 }
    L("poise gate " .. mname .. ": " .. (attached and "ATTACHED" or "HOOK FAILED"))
    return attached
end
local function install_poise_hooks()
    if poise_armed then return end
    local skip = sdk.PreHookResult and sdk.PreHookResult.SKIP_ORIGINAL or nil
    if skip == nil then return end
    local ok_td, td = pcall(sdk.find_type_definition, "app.cPlayerCharacterEntity")
    if ok_td and td ~= nil then
        local ok_m, m = pcall(td.get_method, td, "evStartRikidoBreak")
        if ok_m and m ~= nil then
            pcall(sdk.hook, m, function(args)
                local result = sdk.PreHookResult.CALL_ORIGINAL
                -- v1.21: cached entity address, no singleton lookup per fire.
                -- v1.23: harvest the gauge object from the break args while here.
                local target = sdk.to_int64(args[2])
                if target ~= 0 then
                    local is_player = false
                    if entity_addr_cache ~= 0 then
                        is_player = (target == entity_addr_cache)
                    else
                        pcall(function()
                            if target == player_entity_addr() then is_player = true end
                        end)
                    end
                    if is_player then
                        proof.break_fires = proof.break_fires + 1
                        pcall(function()
                            claim_gauge(sdk.to_managed_object(args[3]), "break-args")
                        end)
                        if cfg.poise then
                            poise_blocked = poise_blocked + 1
                            proof.break_skips = proof.break_skips + 1
                            result = skip
                        end
                    end
                end
                return result
            end, function(retval)
                return retval
            end)
        end
    end
    local ok_td2, td2 = pcall(sdk.find_type_definition, "app.cPlayerRikidoTiredMotionController")
    if ok_td2 and td2 ~= nil then
        local ok_m2, m2 = pcall(td2.get_method, td2, "isRikidoTired")
        if ok_m2 and m2 ~= nil then
            pcall(sdk.hook, m2, function(args)
                local st = thread.get_hook_storage()
                st.poise = false
                if cfg.poise then
                    -- v1.21: controller address verified once, then compared
                    -- as integers (this hook is on the player-only class).
                    local this_addr = sdk.to_int64(args[2])
                    if tired_owner_cache ~= 0 then
                        if this_addr == tired_owner_cache then st.poise = true end
                    else
                        pcall(function()
                            local self_obj = sdk.to_managed_object(args[2])
                            if self_obj == nil then return end
                            local owner = try_call(self_obj, "get__PlayerEntity")
                            if not is_managed_object(owner) then return end
                            local live = player_entity_addr()
                            if owner:get_address() == live then
                                tired_owner_cache = this_addr
                                st.poise = true
                            end
                        end)
                    end
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                local st = thread.get_hook_storage()
                if st.poise then
                    st.poise = false
                    poise_blocked = poise_blocked + 1
                    proof.tired_evals = proof.tired_evals + 1
                    return sdk.to_ptr(0)
                end
                return retval
            end)
        end
    end
    -- Rikido gates: isEnable* controls reactions; calcRikidoDamage is the
    -- writer that fills the gauge (full cCharacterApplyDamage method list
    -- in the dump). Player's own damage module only.
    local ok_gtd, gtd = pcall(sdk.find_type_definition, "app.cPlayerApplyDamage")
    if ok_gtd and gtd ~= nil then
        install_poise_gate(gtd, "isEnableRikidoDamage")
        install_poise_gate(gtd, "isEnablePartsRikidoDamage")
        install_poise_gate(gtd, "isEnableGuardBreakDamage")
        install_poise_gate(gtd, "calcRikidoDamage")
    else
        L("poise: cPlayerApplyDamage TYPE NOT FOUND")
    end
    -- Stock level: zero Rikido amounts on incoming damage stock before the
    -- engine accumulates them into the gauge. Gated to the player entity
    -- (args[2] = this entity, args[3] = cStockDamageInfoCharacter).
    local ok_etd, etd = pcall(sdk.find_type_definition, "app.cPlayerCharacterEntity")
    if ok_etd and etd ~= nil then
        local ok_m, m = pcall(etd.get_method, etd, "evOnRequestDamage")
        if not ok_m or m == nil then
            L("poise stock hook: METHOD NOT FOUND")
        else
            local attached = pcall(sdk.hook, m, function(args)
                pcall(function()
                    if not cfg.poise then return end
                    local target = sdk.to_int64(args[2])
                    if target == 0 then return end
                    local live = entity_addr_cache
                    if live == 0 then live = player_entity_addr() end
                    if target ~= live then return end
                    proof.stock_fires = proof.stock_fires + 1
                    local stock = sdk.to_managed_object(args[3])
                    if stock == nil then return end
                    pcall(function() stock:call("set_RikidoDamage", 0.0) end)
                    pcall(function() stock:call("set_FixedRikidoDamage", 0.0) end)
                    poise_blocked = poise_blocked + 1
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, nil)
            proof.stock_attached = attached
            L("poise stock hook: " .. (attached and "ATTACHED" or "HOOK FAILED"))
        end
    end
    poise_armed = true
    L("poise hooks installed")
end

-- v1.28 HP write prevention: SKIP damage writes on the player's own
-- HealthManager so the value (and the visual bar) never dips. Heals,
-- max-writes and the refill's own top-ups pass through; enemy managers
-- never match the address gate. Per-frame refill stays as backup.
local hp_guards_armed = false
local function to_int32(v)
    local raw = sdk.to_int64(v) % 0x100000000
    if raw >= 0x80000000 then raw = raw - 0x100000000 end
    return raw
end
local function install_hp_guards()
    if hp_guards_armed then return end
    local ok_td, td = pcall(sdk.find_type_definition, "app.cHealthManager")
    if not ok_td or td == nil then
        proof.hp_hook = "type missing"
        return
    end
    local hooked = 0
    local function guard(mname, is_damage)
        local ok_m, m = pcall(td.get_method, td, mname)
        if not ok_m or m == nil then return end
        local attached = pcall(sdk.hook, m, function(args)
            local result = sdk.PreHookResult.CALL_ORIGINAL
            pcall(function()
                if not mode_refills() then return end
                if hmgr_addr_cache == 0 then return end
                if sdk.to_int64(args[2]) ~= hmgr_addr_cache then return end
                if is_damage(args) then
                    hp_blocks = hp_blocks + 1
                    proof.hp_blocks = hp_blocks
                    if hp_log_n < 3 then
                        hp_log_n = hp_log_n + 1
                        L("hp: " .. mname .. " damage write skipped x" .. tostring(hp_blocks))
                    end
                    result = sdk.PreHookResult.SKIP_ORIGINAL
                end
            end)
            return result
        end, nil)
        if attached then hooked = hooked + 1 end
    end
    guard("addHealth", function(args)
        return to_int32(args[3]) < 0 -- negative adds are damage; positives heal
    end)
    local function sub_current(args)
        local val = to_int32(args[3])
        local self_obj = sdk.to_managed_object(args[2])
        local cur = self_obj and try_call(self_obj, "get_Health") or nil
        return type(val) == "number" and type(cur) == "number" and val < cur
    end
    guard("setHealth", sub_current)
    guard("set_Health", sub_current)
    guard("setHealthNormalized", function(args)
        local okf, f = pcall(sdk.to_float, args[3])
        return okf and type(f) == "number" and f < 0.9999
    end)
    proof.hp_hook = tostring(hooked) .. "/4 attached"
    if hooked > 0 then hp_guards_armed = true end
    L("hp guards: " .. proof.hp_hook)
end

cache_health_methods()
install_die_guard()
install_die2_guard()
install_nohit_hooks()
install_result_spoofs()
install_poise_hooks()
install_hp_guards()

local function set_mode(m)
    if cfg.mode == m then return end
    cfg.mode = m
    save()
    hit_spoofed, pre_spoofed = 0, 0
    L("mode=" .. m)
end

local nohit_applied = false
local function sync_nohit_levels()
    -- v1.21: apply once, not every few ticks. Release still runs on exit.
    if cfg.enabled and cfg.mode == "nohit" then
        if nohit_applied then return end
        if set_no_hit(true) then
            nohit_applied = true
            note_event("no-hit levels requested")
        end
    elseif nohit_applied then
        nohit_applied = false
        set_no_hit(false)
        L("no-hit levels released")
    end
end

-- v1.27: defined HERE (after all state) so reads bind to chunk locals.
local function write_proof()
    pcall(json.dump_file, PROOF_FILE, {
        version = VERSION, tick = tick,
        cfg = { enabled = cfg.enabled, mode = cfg.mode, poise = cfg.poise },
        addrs = { entity = entity_addr_cache, mod = poise_mod_addr, inv = inv_addr_cache },
        hp = { last = hp_last, max = hpmax_last, step = hmgr_step },
        proof = proof,
    })
end

local ui_threw = false
re.on_draw_ui(function()
    local ok, err = pcall(function()
        if not imgui.tree_node(MOD .. " v" .. VERSION) then return end
        -- Active state, front and center.
        local parts = {}
        if cfg.mode ~= "off" then
            parts[#parts + 1] = cfg.mode == "nohit" and "NO HIT" or "INF HP"
        end
        if cfg.poise then parts[#parts + 1] = "POISE" end
        local active = #parts > 0 and table.concat(parts, " + ") or "OFF"
        imgui.text_colored("ACTIVE: " .. active, #parts > 0 and 0xFF40FF40 or 0xFF808080)
        if hp_last ~= nil and hpmax_last ~= nil then
            imgui.text(string.format("HP: %s / %s", tostring(hp_last), tostring(hpmax_last)))
        else
            imgui.text("HP: -- (enter gameplay)")
        end
        if imgui.button("No Hit") then cfg.enabled = true set_mode("nohit") end
        imgui.same_line()
        if imgui.button("Inf HP") then cfg.enabled = true set_mode("infhp") end
        imgui.same_line()
        if imgui.button("Off") then
            cfg.enabled = false
            cfg.mode = "off"
            save()
            sync_nohit_levels()
            L("invincibility off (stagger bar untouched)")
        end
        local chp, vpoise = imgui.checkbox("Stagger Bar (Always full)", cfg.poise)
        if chp then
            cfg.poise = vpoise
            if vpoise then cfg.enabled = true end
            save()
            L("poise=" .. tostring(vpoise))
        end
        imgui.tree_pop()
    end)
    if not ok and not ui_threw then ui_threw = true L("UI error: " .. tostring(err)) end
end)

re.on_frame(function()
    tick = tick + 1
    if tick % GUARD_RETRY_TICKS == 0 then
        if not dieguard_armed then install_die_guard() end
        if not die2_armed then install_die2_guard() end
        if not poise_armed then install_poise_hooks() end
        if not hp_guards_armed then install_hp_guards() end
    end
    -- Refill runs EVERY frame (same-frame multi-hits must never observe a
    -- lowered value). Gauge top-up + HP readout ride the slow ticks.
    if tick % 5 == 0 and cfg.poise then
        if resolve_player() then topup_gauge() end
    end
    if mode_refills() and resolve_player() then
        if hmgr ~= nil or tick % 30 == 0 then
            refill_health()
            if tick % 30 == 0 then read_hp_pair() end
        end
    elseif tick % 30 == 0 and resolve_player() then
        read_hp_pair()
    end
    if tick % 60 == 0 then refresh_addr_cache() end
    if tick % 600 == 0 then write_proof() end
    if tick % 6 ~= 0 then return end
    if not resolve_player() then return end
    if cfg.enabled then
        apply_nodamage()
        sync_nohit_levels()
    end
    -- Restore engine runs for refill modes AND standalone stagger bar.
    -- HP names skip themselves unless a refill mode is on.
    if mode_refills() or cfg.poise then
        guard_object(chara, "C", 0)
        guard_object(entity, "E", 0)
        if mi ~= nil then guard_object(mi, "I", 0) end
    end
end)

re.on_script_reset(function()
    write_proof()
    mi, chara, entity, pgo, go_addr = nil, nil, nil, nil, 0
    nohit_applied = false
    deaths_blocked, poise_blocked, hit_spoofed, pre_spoofed = 0, 0, 0, 0
    poise_log_n, hp_blocks, hp_log_n = 0, 0, 0
    hmgr, hmgr_step, hp_last, hpmax_last = nil, "-", nil, nil
    reset_restore()
    poise_mod_addr = 0
    hmgr_addr_cache = 0
    rgauge, rgauge_fields, rgauge_last, rgauge_step, rg_cool = nil, {}, {}, "-", 0
    entity_addr_cache, inv_addr_cache, tired_owner_cache = 0, 0, 0
    nodamage_entity_addr = 0
    poise_mod_logged = 0
    last_event = "-"
end)

re.on_config_save(function() save() end)

L("loaded v" .. VERSION .. " (independent stagger bar)")
