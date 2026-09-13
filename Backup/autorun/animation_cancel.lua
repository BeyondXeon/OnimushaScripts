-- Animation Cancel  -- 1.1.1
-- Onimusha: Way of the Sword, REFramework Lua autorun.
--
-- Lets any chosen input interrupt any player animation: attack recovery into
-- dodge, dodge into attack, the next swing before the current one lands.
--
-- Mechanism: every player animation carries an app.motion_track.PlayerCommandCancel
-- track with one cCancelCommand key per command (attack, dodge, guard, ...). Each
-- key has a _Phase (NONE=0, PRE=1, ACTUAL=2, IGNORE=3) that says whether that
-- command may cancel the animation on this frame. The entity keeps the merged
-- per-layer copies in _PlayerCommandCancelMotionSeq[]; the game re-merges them
-- every frame and reads the phases directly. This script writes ACTUAL into the
-- keys of every enabled category just before the cancel checker, the command
-- controller and the action selector consume them. Same machinery as the
-- "priority" layer of the Instant Parry mod, extended to every command key.
-- Only the per-command keys are touched. Their field names follow the command
-- enum mechanically (ATTACK_LIGHT -> _AttackLightCancel), which leaves out the
-- automatic keys (idle, turns, wall, edge catch, guard stop, dash attack) that
-- the selector fires on its own, and the group keys. Forcing the automatic keys
-- makes the selector re-trigger transitions every frame and breaks movement.
-- getCancelKey() hands out merged scratch objects, so the field keys are used.
-- No self-cancel: a category's keys are left alone while the current base
-- action's class belongs to that category (cAttackStrong1 -> attack) or the
-- action state has that category's bit (ATTACK, EVADE, BLOCK/PARRY, MOVING). The
-- state bit alone is not enough: it is set during the active frames, not the
-- wind-up, so a spammed heavy would restart before it could land. Cancelling
-- *into* another category stays instant.
-- Choreographed actions are never cancelled: Issen sequences and anything derived
-- from cUsePartnerOneMotionAction (grabs, blade lock, fatal blow) play one motion
-- in lock-step with an enemy, and cancelling the player's half crashes the game.
-- Hit reactions (stagger, knockdown, launch, guard break, wall crash) are left to
-- the game's own rules while finish_damage is on, so a hit costs what it costs.
-- Sekiro rule (off by default): only the first hit of a combo cancels freely; a
-- follow-up swing (Weak2/3, Strong2/3, StrongFromWeak, WeakFromStrong) can be
-- cancelled only within its first sekiro_ms milliseconds, then plays as vanilla.
-- Command mask: actions also carry a per-frame mask of commands they refuse
-- outright, checked before any cancel window. The mask bits of enabled,
-- non-skipped commands are cleared in the command controller's update, so dodge
-- and guard can interrupt attacks instead of being dropped by the mask.
-- Menu: REFramework -> ScriptRunner -> "AnimationCancel". Config: reframework/data/animation_cancel.json.

local MOD = "AnimationCancel"
local VERSION = "1.1.1"
local CFG_FILE = "animation_cancel.json"
local PHASE_ACTUAL = 2

-- Categories, in menu order. Keys and commands are sorted into them by name.
local CATS = {
    { key = "attack", label = "Attacks (light, hard, charge, combo, skills, bow)" },
    { key = "dodge",  label = "Dodge / just dodge" },
    { key = "guard",  label = "Guard / block / parry" },
    { key = "move",   label = "Movement (run, walk, dash, lock-on) - experimental" },
    { key = "issen",  label = "Issen / counters (changes the timing game)" },
    { key = "other",  label = "Everything else (items, menus, absorb, interact, Oni)" },
}
for _, c in ipairs(CATS) do c.id = c.label .. "##" .. c.key end
local cfg = { enabled = true, attack = true, dodge = true, guard = true, move = false, issen = false, other = false, finish_parry = true, finish_damage = true, sekiro = false, sekiro_ms = 150, debug_log = false }
do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do cfg[k] = v end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
local function info(msg) log.info("[" .. MOD .. "] " .. tostring(msg)) end
local function save() pcall(json.dump_file, CFG_FILE, cfg) end

-- Name -> category. Works for track field names (_AttackLightCancel) and
-- command enum names (ATTACK_LIGHT) alike: compare lower-case without underscores.
local function classify(name)
    local n = name:lower():gsub("_", "")
    if n:find("menu") then return "other" end
    if n:find("issen") or n:find("grabcounter") or n:find("bladelock") then return "issen" end
    if n:find("dodge") then return "dodge" end
    if n:find("guard") or n:find("block") or n:find("parry") or n:find("defence") or n:find("justgroup") then return "guard" end
    if n:find("attack") or n:find("skill") or n:find("ultimate") or n:find("bow") or n:find("shot") then return "attack" end
    if n:find("move") or n:find("run") or n:find("walk") or n:find("dash") or n:find("turn") or n:find("strafe")
        or n:find("idle") or n:find("quickstop") or n:find("lockon") or n:find("wall") or n:find("edge") then return "move" end
    return "other"
end

-- Field offsets, read from the types so a patch cannot silently move them. The
-- per-frame code reads pointers raw at these offsets and only goes through the
-- reflection API when a pointer changed; a nil offset falls back to the API path.
local function field_off(tn, fname)
    local td = sdk.find_type_definition(tn)
    local f = td and td:get_field(fname)
    return f and f:get_offset_from_base() or nil
end
local PHASE_OFF = field_off("app.motion_track.cCancelCommand", "_Phase")
if PHASE_OFF == nil then info("cCancelCommand._Phase not found; game build changed?"); return end
local ENT_OFF  = field_off("app.PlayerActionCancelChecker", "_PlayerCharacterEntity")
local CM_OFF   = field_off("app.cPlayerCommandMask", "_CommandMasks")
local BITS_OFF = field_off("ace.Bitset", "_Value")
local ARR_DATA = 0x20   -- first element of a System.UInt32[]; checked against isOn() before use

-- Command -> key field. ATTACK_LIGHT -> _AttackLightCancel, checked against the
-- track type so a command without a key (LOCK_ON_CHANGE_*, HEAD_OPEN) is skipped.
local CMD_T = "app.PlayerCommand.TYPE"
local KEYS = {}       -- { name = "_AttackLightCancel", off = 0x108, cat = "attack", cmd = "ATTACK_LIGHT" }
local CMD_CAT = {}    -- enum value -> cat, for the wrapper hooks
local CMDS = {}       -- { value = 23, name = "ATTACK_LIGHT", cat = "attack" }, for the mask
do
    local etd = sdk.find_type_definition(CMD_T)
    local ttd = sdk.find_type_definition("app.motion_track.PlayerCommandCancel")
    if etd ~= nil and ttd ~= nil then
        for _, f in ipairs(etd:get_fields()) do
            local n = f:get_name()
            if n ~= "value__" and n ~= "MAX" and n ~= "INVALID" then
                local ok, v = pcall(f.get_data, f, nil)
                if ok and type(v) == "number" then
                    local cat = classify(n)
                    CMD_CAT[v] = cat
                    CMDS[#CMDS + 1] = { value = v, name = n, cat = cat, word = v >> 5, bit = 1 << (v & 31) }
                    local camel = n:lower():gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end):gsub("_", "")
                    local fname = "_" .. camel .. "Cancel"
                    local fd = ttd:get_field(fname)
                    if fd ~= nil then
                        KEYS[#KEYS + 1] = { name = fname, off = fd:get_offset_from_base(), cat = cat, cmd = n }
                    end
                end
            end
        end
    end
    if #KEYS == 0 then info("no command keys resolved; game build changed?"); return end
    local counts = {}
    for _, k in ipairs(KEYS) do counts[k.cat] = (counts[k.cat] or 0) + 1 end
    local parts = {}
    for _, c in ipairs(CATS) do parts[#parts + 1] = c.key .. "=" .. tostring(counts[c.key] or 0) end
    info(#KEYS .. " command keys: " .. table.concat(parts, " "))
end

-- app.CharacterDef.ACTION_STATE_BIT values per category: while the character is
-- in one of these states, that category's keys are not forced (no self-cancel).
local STATE_BITS = {}
do
    local names = {
        attack = { "ATTACK", "SHELL_ATTACK" },
        dodge  = { "EVADE" },
        guard  = { "BLOCK", "PARRY", "GUARD_WAIT", "GUARD_HIT" },
        move   = { "MOVING" },
    }
    local etd = sdk.find_type_definition("app.CharacterDef.ACTION_STATE_BIT")
    for cat, list in pairs(names) do
        local bits = 0
        for _, n in ipairs(list) do
            local f = etd and etd:get_field(n)
            local ok, v = f and pcall(f.get_data, f, nil)
            if ok and type(v) == "number" then bits = bits | v end
        end
        STATE_BITS[cat] = bits
    end
end
-- Every ACTION_STATE_BIT name, for the debug log.
local STATE_NAMES = {}
do
    local etd = sdk.find_type_definition("app.CharacterDef.ACTION_STATE_BIT")
    for _, f in ipairs(etd and etd:get_fields() or {}) do
        local ok, v = pcall(f.get_data, f, nil)
        if ok and type(v) == "number" and v > 0 and f:get_name() ~= "CHARA_STATE_MASK" then STATE_NAMES[#STATE_NAMES + 1] = { f:get_name(), v } end
    end
    table.sort(STATE_NAMES, function(a, b) return a[2] < b[2] end)
end
local function state_str(state)
    local t = {}
    for _, e in ipairs(STATE_NAMES) do if (state & e[2]) ~= 0 then t[#t + 1] = e[1] end end
    return #t > 0 and table.concat(t, "|") or "NONE"
end
local GRAPPLE_BIT = 0   -- partnered move in progress (grab, Issen finish): hold everything
do
    local etd = sdk.find_type_definition("app.CharacterDef.ACTION_STATE_BIT")
    local f = etd and etd:get_field("GRAPPLE")
    local ok, v = f and pcall(f.get_data, f, nil)
    if ok and type(v) == "number" then GRAPPLE_BIT = v end
end

local function find_method(tn, name, last_param_type)
    local mtd = sdk.find_type_definition(tn)
    if mtd == nil then return nil end
    for _, m in ipairs(mtd:get_methods()) do
        if m:get_name() == name then
            local pts = m:get_param_types()
            if last_param_type == nil and #pts == 0 then return m end
            local last = pts[#pts]
            if last ~= nil and last:get_full_name() == last_param_type then return m end
        end
    end
    return nil
end
local function is_true(retval) return (sdk.to_int64(retval) & 0xFF) ~= 0 end
local function arg_enum(args, i) return sdk.to_int64(args[i]) & 0xFFFFFFFF end

-- Live state. Layers appear and vanish with the animation, so the live array is
-- walked every frame and only present layers are written; each layer's key
-- objects are resolved once per layer object (compared by address).
local entity, entity_addr = nil, 0
local player = nil            -- app.PlayerCharacter (a CharacterBase), for getActionState
local M_STATE, M_ACT = nil, nil   -- getActionState / get_BaseCurrentAction, resolved once per player object
local skip = {}               -- category -> true while the character is in that category's state
local act_addr, act_cat = 0, nil
local act_hold = false        -- current action is a landed parry / block reaction: nothing is forced
local act_sync = false        -- current action is choreographed with an enemy: nothing is ever forced
local act_dmg = false         -- current action is a hit reaction: nothing is forced while finish_damage is on
local act_combo = false       -- current action is a combo follow-up swing (Sekiro rule)
local act_t0 = 0              -- os.clock() when the current action started
local held = false            -- act_sync, or the GRAPPLE state bit, or act_hold / act_dmg with the matching option on
-- Issen sequences (chain, counter, break) and every action derived from
-- cUsePartnerOneMotionAction (grabs, blade lock, fatal blow, grab damage) play
-- one motion in lock-step with a partner enemy. Cancelling out of them leaves
-- the enemy mid-choreography and crashes the game, so they are never touched.
local function synced_action(td)
    while td ~= nil do
        local n = td:get_name() or ""
        if n:find("Issen") or n == "cUsePartnerOneMotionAction" then return true end
        td = td:get_parent_type()
    end
    return false
end
-- Player action classes that play after a successful deflect (one-handed parry,
-- two-handed block). The pre-window actions (cPreParry, cPreBlock) and the
-- follow-up attacks (cAttackAfterParry, cParryAttack) are not in the set, so a
-- guard press still interrupts anything and the riposte still chains.
local PARRY_HOLD = {
    cParryBlow = true, cParryShell = true, cParryDefend = true, cMultipleParry = true, cCounterStanceParry = true,
    cBlockBlow = true, cBlockShell = true, cBlockDefend = true, cMultipleBlock = true,
    cWaitJustGuardAttack = true,
}
-- Hit reactions. Every damage action lives in a Player*DamageAction namespace
-- (cSmallDamage, cLargeDamage, cLaunchDamage, cGuardBreak, cWallCrashBack,
-- cDown, ...); the two outside it carry "Damage" in the name (cIdleSmashDamage*)
-- or are the knockdown roll (cDodgeDown). Matched by name, not by list, so a
-- reaction this build does not use in the open world still holds.
local function damage_action(tn)
    local n = tn:match("([^.]+)$") or tn
    return tn:find("DamageAction%.") ~= nil or n:find("Damage") ~= nil or n:find("DodgeDown") ~= nil
end
-- Combo follow-ups: cAttackWeak2/3, cAttackStrong2/3 (digit > 1) and the stance
-- switches cAttackStrongFromWeak1/2, cAttackWeakFromStrong1/2 (always follow a hit).
-- cAttackWeak1, cAttackStrong1, charge attacks and everything else are first hits.
local function combo_followup(tn)
    local n = tn:match("([^.]+)$") or tn
    local kind, d = n:match("^cAttack(%a+)(%d)$")
    return kind ~= nil and (d ~= "1" or kind:find("From") ~= nil)
end

-- Category of an action class by its short name; attack first so cAttackAfterJustDodge is an attack.
local function classify_action(tn)
    local n = tn:match("([^.]+)$") or tn
    if n:find("Attack") then return "attack" end
    if n:find("Issen") then return "issen" end
    if n:find("Dodge") then return "dodge" end
    if n:find("Guard") or n:find("Block") or n:find("Parry") then return "guard" end
    if n:find("Run") or n:find("Walk") or n:find("Dash") or n:find("Move") or n:find("Turn") or n:find("Strafe") then return "move" end
    return "other"
end
local seq, seq_n = nil, 0
local layer_keys = {}           -- layer address -> { {obj=key, cat=...}, ... }
local raw_ok, raw_checked = false, false
local frames = 0

local verified = {}   -- layer address -> frame number of the last pointer check
local function resolve_seq()
    seq, seq_n, layer_keys, verified = nil, 0, {}, {}
    if entity == nil then return end
    local ok, a = pcall(entity.call, entity, "getCancelMotionSeq")
    if not ok or a == nil then return end
    local okn, n = pcall(a.get_size, a)
    if okn and n > 0 then seq, seq_n = a, n end
end

local function keys_for(tr)
    local addr = tr:get_address()
    local k = layer_keys[addr]
    if k ~= nil then return k end
    k = {}
    for _, kf in ipairs(KEYS) do
        local okf, fobj = pcall(tr.get_field, tr, kf.name)
        local faddr = (okf and fobj ~= nil) and fobj:get_address() or 0
        if faddr ~= 0 then
            local okr, ptr = pcall(tr.read_qword, tr, kf.off)
            -- Field API object is authoritative; the raw read is the per-frame validity check.
            k[#k + 1] = { off = kf.off, addr = faddr, obj = fobj, cat = kf.cat, raw = (okr and ptr == faddr) }
        end
    end
    layer_keys[addr] = k
    if not raw_checked and k[1] ~= nil then
        raw_checked = true
        local okw = pcall(k[1].obj.write_dword, k[1].obj, PHASE_OFF, PHASE_ACTUAL)
        local okr, v = pcall(k[1].obj.get_field, k[1].obj, "_Phase")
        raw_ok = okw and okr and v == PHASE_ACTUAL
        info("raw writes " .. (raw_ok and "on" or "off (field API)"))
    end
    return k
end

-- verify=true re-reads every key pointer from the live layer before writing (once
-- per frame, from the checker hook); the other two hooks write only layers that
-- passed that check this frame.
local function force_core(verify)
    for i = 0, seq_n - 1 do
        local tr = seq:get_element(i)
        if tr ~= nil then
            local addr = tr:get_address()
            local k = keys_for(tr)
            if verify then
                for j = 1, #k do
                    local e = k[j]
                    if e.raw and tr:read_qword(e.off) ~= e.addr then layer_keys[addr] = nil; k = nil; break end
                end
                if k ~= nil then verified[addr] = frames end
            elseif verified[addr] ~= frames then
                k = nil
            end
            if k ~= nil then
                for j = 1, #k do
                    local e = k[j]
                    if cfg[e.cat] and not skip[e.cat] then
                        if raw_ok then e.obj:write_dword(PHASE_OFF, PHASE_ACTUAL)
                        else pcall(e.obj.set_field, e.obj, "_Phase", PHASE_ACTUAL) end
                    end
                end
            end
        end
    end
end

local function force_phases(verify)
    if seq ~= nil and cfg.enabled then
        if not pcall(force_core, verify == true) then resolve_seq() end
    end
end

local function hook_pre(tn, name, ptype, fn, label)
    local m = find_method(tn, name, ptype)
    if m == nil then info(label .. " not found (game build changed?)"); return end
    sdk.hook(m, fn, nil)
end

-- The cancel checker owns the entity reference; re-resolve when it changes.
local frame_id, state_frame = 0, -1
re.on_frame(function() frame_id = frame_id + 1 end)
local update_state
local function update_state_core()
    local state = 0
    if player ~= nil then
        local oks, st = pcall(M_STATE.call, M_STATE, player)
        if oks and type(st) == "number" then state = st end
        local oka, act = pcall(M_ACT.call, M_ACT, player)
        local a = (oka and act ~= nil) and act:get_address() or 0
        if a ~= act_addr then
            act_addr = a
            local prev_t0 = act_t0
            act_cat, act_hold, act_sync, act_dmg, act_combo, act_t0 = nil, false, false, false, false, os.clock()
            if a ~= 0 then
                local okt, td = pcall(act.get_type_definition, act)
                local tn = okt and td ~= nil and td:get_full_name() or nil
                if tn ~= nil then
                    act_cat = classify_action(tn)
                    act_hold = PARRY_HOLD[tn:match("([^.]+)$") or tn] == true
                    act_dmg = damage_action(tn)
                    act_combo = combo_followup(tn)
                    local oks, s = pcall(synced_action, td)
                    act_sync = oks and s == true
                    if cfg.debug_log then
                        info(string.format("action %s cat=%s +%dms state=%s%s%s%s%s", tn:match("([^.]+)$") or tn, tostring(act_cat),
                            math.floor((act_t0 - prev_t0) * 1000), state_str(state),
                            act_sync and " SYNC" or "", act_hold and " PARRY-HOLD" or "", act_dmg and " DAMAGE" or "", act_combo and " FOLLOWUP" or ""))
                    end
                end
            elseif cfg.debug_log then
                info(string.format("action <none> +%dms state=%s", math.floor((act_t0 - prev_t0) * 1000), state_str(state)))
            end
        end
    end
    for cat, bits in pairs(STATE_BITS) do skip[cat] = (state & bits) ~= 0 or act_cat == cat end
    if act_cat ~= nil and STATE_BITS[act_cat] == nil then skip[act_cat] = true end
    -- Choreographed actions (Issen, grabs) are never cancelled: the enemy plays the
    -- other half. A landed parry / block plays out in full when finish_parry is on,
    -- a hit reaction when finish_damage is on, a combo follow-up past its window under the Sekiro rule.
    held = act_sync or (state & GRAPPLE_BIT) ~= 0 or (act_hold and cfg.finish_parry) or (act_dmg and cfg.finish_damage)
        or (cfg.sekiro and act_combo and (os.clock() - act_t0) * 1000 > cfg.sekiro_ms)
    if held then for _, c in ipairs(CATS) do skip[c.key] = true end end
end

-- Once per rendered frame, from whichever hook runs first that frame.
update_state = function()
    if state_frame == frame_id then return end
    state_frame = frame_id
    update_state_core()
end

local checker, checker_addr = nil, 0
hook_pre("app.PlayerActionCancelChecker", "lateUpdate", nil, function(args)
    local ca = sdk.to_int64(args[2])
    if ca ~= 0 then
        if ca ~= checker_addr then checker, checker_addr = sdk.to_managed_object(args[2]), ca end
        -- Raw pointer read per frame; the field API only when it changed (or ENT_OFF is unknown).
        local _, a = pcall(checker.read_qword, checker, ENT_OFF)
        if a ~= entity_addr then
            local ok, e = pcall(checker.get_field, checker, "_PlayerCharacterEntity")
            if ok then
                entity, entity_addr = e, (e ~= nil and e:get_address() or 0)
                local okp, pc = pcall(checker.get_field, checker, "_PlayerCharacter")
                player, M_STATE, M_ACT = nil, nil, nil
                if okp and pc ~= nil and pc:get_address() ~= 0 then
                    local ptd = pc:get_type_definition()
                    M_STATE = ptd and ptd:get_method("getActionState")
                    M_ACT = ptd and ptd:get_method("get_BaseCurrentAction")
                    if M_STATE ~= nil and M_ACT ~= nil then player = pc end
                end
                resolve_seq()
            end
        end
    end
    update_state()
    frames = frames + 1
    if (seq == nil and frames % 60 == 0) or frames % 600 == 0 then resolve_seq() end
    force_phases(true)
end, "checker.lateUpdate")

-- Mask clearing. The mask object arrives as the update argument; bit on = command refused.
local MASK_SET = find_method("ace.Bitset", "set", "System.Boolean")
local MASK_ISON = find_method("ace.Bitset", "isOn", "System.Int32")
local COMBAT_CAT = { attack = true, dodge = true, guard = true, issen = true }
-- mask -> _CommandMasks (ace.Bitset) -> _Value (UInt32[]): each link is re-read raw
-- every frame and re-fetched through the field API only when its pointer changed.
local mask, mask_addr, bs, bs_addr, arr, arr_addr, nwords = nil, 0, nil, 0, nil, 0, 0
local words = {}
-- Bits are read raw from the word array once per frame instead of one isOn() call
-- per command. raw_mask: nil = still checking raw reads against isOn(), true = raw
-- agreed on 2000 checks incl. a set bit, false = disagreed (or never saw a set bit),
-- use isOn() only. Writes always go through set().
local raw_mask, cal_n, cal_hits = nil, 0, 0
local function refresh_mask(mp)
    if mp ~= mask_addr then
        mask, mask_addr, bs, bs_addr, arr, arr_addr = sdk.to_managed_object(mp), mp, nil, 0, nil, 0
    end
    local okb, bp = pcall(mask.read_qword, mask, CM_OFF)
    if not okb or bp ~= bs_addr then
        local ok, b = pcall(mask.get_field, mask, "_CommandMasks")
        bs = (ok and b ~= nil) and b or nil
        bs_addr, arr, arr_addr = bs and bs:get_address() or 0, nil, 0
    end
    if bs == nil then return end
    local oka, ap = pcall(bs.read_qword, bs, BITS_OFF)
    if not oka or ap ~= arr_addr then
        local ok, a = pcall(bs.get_field, bs, "_Value")
        arr = (ok and a ~= nil) and a or nil
        arr_addr = arr and arr:get_address() or 0
        local okn, n = pcall(function() return arr:get_size() end)
        nwords = (okn and type(n) == "number" and n <= 8) and n or 0
    end
end
local function unmask(mp)
    -- Only inside combat actions: idle and movement mask the just-inputs on purpose.
    if mp == 0 or MASK_SET == nil or MASK_ISON == nil or not COMBAT_CAT[act_cat] or held then return end
    refresh_mask(mp)
    if bs == nil then return end
    local raw = raw_mask ~= false and arr ~= nil and nwords > 0
    if raw then
        for w = 0, nwords - 1 do words[w] = arr:read_dword(ARR_DATA + 4 * w) end
    end
    for i = 1, #CMDS do
        local c = CMDS[i]
        if cfg[c.cat] and not skip[c.cat] then
            local on = false
            if raw and c.word < nwords then
                on = (words[c.word] & c.bit) ~= 0
                if raw_mask == nil then
                    local okr, api = pcall(MASK_ISON.call, MASK_ISON, bs, c.value)
                    if okr then
                        if api ~= on then raw_mask = false; info("mask: raw reads disagree with isOn, using isOn")
                        else
                            cal_n = cal_n + 1
                            if on then cal_hits = cal_hits + 1 end
                            if cal_n >= 2000 and cal_hits > 0 then raw_mask = true
                            elseif cal_n >= 20000 then raw_mask = false end
                        end
                        on = api == true
                    end
                end
            else
                local okr, api = pcall(MASK_ISON.call, MASK_ISON, bs, c.value)
                on = okr and api == true
            end
            if on then pcall(MASK_SET.call, MASK_SET, bs, c.value, false) end
        end
    end
end
hook_pre("app.cPlayerCommandController", "update", "app.cPlayerCommandMask", function(args)
    update_state()
    force_phases(false)
    if cfg.enabled then unmask(sdk.to_int64(args[3])) end
end, "cmdctl.update")
hook_pre("app.cPlayerActionSelector", "update", nil, function() update_state(); force_phases(false) end, "selector.update")

-- The wrapper checks the game still calls for some commands: answer by category.
local function hook_cmd_bool(tn, name, want, label)
    local m = find_method(tn, name, CMD_T)
    if m == nil then info(label .. " not found (game build changed?)"); return end
    -- Per-call storage: these wrappers run on several job threads at once, so a
    -- file-level upvalue set in pre can be overwritten by another call before post.
    sdk.hook(m, function(args)
        local cat = CMD_CAT[arg_enum(args, 3)]
        local on = cfg.enabled and cat ~= nil and cfg[cat] == true
        if on then update_state(); on = not skip[cat] end
        thread.get_hook_storage().on = on
    end, function(retval)
        if thread.get_hook_storage().on and is_true(retval) ~= want then return sdk.to_ptr(want and 1 or 0) end
        return retval
    end)
end
hook_cmd_bool("app.cPlayerCharacterEntity", "checkCancelMotion",    true,  "entity.checkCancelMotion")
hook_cmd_bool("app.cPlayerCharacterEntity", "checkPreCancelMotion", true,  "entity.checkPreCancelMotion")
hook_cmd_bool("app.cPlayerCharacterEntity", "checkIgnoreMotion",    false, "entity.checkIgnoreMotion")
hook_cmd_bool("app.PlayerUtil", "checkCancelMotion",    true, "util.checkCancelMotion")
hook_cmd_bool("app.PlayerUtil", "checkPreCancelMotion", true, "util.checkPreCancelMotion")

re.on_draw_ui(function()
    if imgui.tree_node(MOD) then
        local changed
        changed, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled)
        if changed then save() end
        for _, c in ipairs(CATS) do
            changed, cfg[c.key] = imgui.checkbox(c.id, cfg[c.key])
            if changed then save() end
        end
        changed, cfg.finish_parry = imgui.checkbox("Let a landed parry / block finish (nothing cancels the deflect)", cfg.finish_parry)
        if changed then save() end
        changed, cfg.finish_damage = imgui.checkbox("Let hit reactions finish (stagger, knockdown, guard break play out as vanilla)", cfg.finish_damage)
        if changed then save() end
        changed, cfg.sekiro = imgui.checkbox("Sekiro rule: only the first hit of a combo cancels freely", cfg.sekiro)
        if changed then save() end
        if cfg.sekiro then
            changed, cfg.sekiro_ms = imgui.slider_int("follow-up swing cancel window (ms from swing start)", cfg.sekiro_ms, 0, 500)
            if changed then save() end
        end
        changed, cfg.debug_log = imgui.checkbox("Debug: log every action change to re2_framework_log.txt", cfg.debug_log)
        if changed then save() end
        local live = 0
        if seq ~= nil then for i = 0, seq_n - 1 do if seq:get_element(i) ~= nil then live = live + 1 end end end
        imgui.text("status: " .. (seq and (live .. "/" .. seq_n .. " layers live") or "waiting for player") .. (raw_ok and " (raw)" or ""))
        imgui.text("version " .. VERSION)
        imgui.tree_pop()
    end
end)

info("loaded " .. VERSION)
