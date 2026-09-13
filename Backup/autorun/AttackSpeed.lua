-- AttackSpeed 1.1 -- Onimusha: Way of the Sword
-- Speeds up the player's attack swings. Settings: reframework/data/AttackSpeed.json

local MOD, VERSION = "AttackSpeed", "1.1"
local CFG_FILE = "AttackSpeed.json"
local TAG = "[" .. MOD .. "] "

local function L(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  log.info(TAG .. table.concat(t, " "))
end

local function try(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return r end
  return nil
end

if try(function() return reframework:get_game_name() end) ~= "onimusha_wots" then return end

local TARGET = {
  ["app.PlayerOneHandedAction.cAttackWeak1"]           = "light",
  ["app.PlayerOneHandedAction.cAttackWeak2"]           = "light",
  ["app.PlayerOneHandedAction.cAttackWeak3"]           = "light",
  ["app.PlayerOneHandedAction.cAttackWeakFromStrong1"] = "light",
  ["app.PlayerOneHandedAction.cAttackWeakFromStrong2"] = "light",
  ["app.PlayerOneHandedAction.cAttackStrong1"]         = "heavy",
  ["app.PlayerOneHandedAction.cAttackStrong2"]         = "heavy",
  ["app.PlayerOneHandedAction.cAttackStrong3"]         = "heavy",
  ["app.PlayerOneHandedAction.cAttackStrongFromWeak1"] = "heavy",
  ["app.PlayerOneHandedAction.cAttackStrongFromWeak2"] = "heavy",
}

local DEFAULTS = { enabled = true, light = 1.5, heavy = 1.5, window = 0.60, measure = false }

local cfg = {}
for k, v in pairs(DEFAULTS) do cfg[k] = v end

local dirty, dirty_at = false, 0

local function load_cfg()
  local disk = try(function() return json.load_file(CFG_FILE) end)
  if type(disk) ~= "table" then return false end
  local changed = false
  for k, default in pairs(DEFAULTS) do
    local v = disk[k]
    if v ~= nil and type(v) == type(default) and v ~= cfg[k] then cfg[k] = v changed = true end
  end
  return changed
end

local function save_cfg()
  local out = {}
  for k in pairs(DEFAULTS) do out[k] = cfg[k] end
  try(function() return json.dump_file(CFG_FILE, out) end)
end

if not load_cfg() then save_cfg() end
L("v" .. VERSION, "loaded. enabled=" .. tostring(cfg.enabled),
  "light=" .. tostring(cfg.light), "heavy=" .. tostring(cfg.heavy),
  "window=" .. tostring(cfg.window))

local function player_motion()
  local pm = sdk.get_managed_singleton("app.PlayerManager")
  if not pm then return nil end
  local info = try(function() return pm:call("getControllingPlayerInfo") end)
  if not info then return nil end
  local chara = try(function() return info:call("get_Character") end)
  if not chara then return nil end
  local go = try(function() return chara:call("get_GameObject") end)
  if not go then return nil end
  return try(function()
    return go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
  end)
end

local function player_entity_addr()
  local pm = sdk.get_managed_singleton("app.PlayerManager")
  if not pm then return nil end
  local info = try(function() return pm:call("getControllingPlayerInfo") end)
  if not info then return nil end
  local ce = try(function() return info:call("get_CharacterEntity") end)
  if not ce then return nil end
  return try(function() return ce:get_address() end)
end

local function action_entity_addr(act)
  local ce = try(function() return act:call("get_CharacterEntity") end)
  if not ce then return nil end
  return try(function() return ce:get_address() end)
end

local function layer0_norm(motion)
  local ly = try(function() return motion:call("getLayer", 0) end)
  if not ly then return nil end
  return try(function() return ly:call("get_NormalizeTime") end)
end

local active_name, active_addr, active_started = nil, nil, nil
local boosting = false
local threw = false

local base_td = sdk.find_type_definition("app.PlayerActionBase.cPlayerActionBase")
local m_enter = base_td and try(function() return base_td:get_method("doEnter") end)
local m_exit  = base_td and try(function() return base_td:get_method("doExit") end)

if not (m_enter and m_exit) then
  L("!! doEnter/doExit unresolved -- mod inactive")
  return
end

sdk.hook(m_enter, function(args)
  local st = thread.get_hook_storage()
  st.act, st.tn = nil, nil
  pcall(function()
    local act = sdk.to_managed_object(args[2])
    if not act then return end
    local tn = try(function() return act:get_type_definition():get_full_name() end)
    if not tn or not TARGET[tn] then return end
    local a1, a2 = action_entity_addr(act), player_entity_addr()
    if not a1 or not a2 or a1 ~= a2 then return end
    st.act, st.tn = act, tn
  end)
  return sdk.PreHookResult.CALL_ORIGINAL
end, function(retval)
  local st = thread.get_hook_storage()
  local act, tn = st.act, st.tn
  st.act, st.tn = nil, nil
  if not act then return retval end
  pcall(function()
    active_name    = tn
    active_addr    = try(function() return act:get_address() end)
    active_started = os.clock()
    boosting       = true
  end)
  return retval
end)

sdk.hook(m_exit, function(args)
  pcall(function()
    local act = sdk.to_managed_object(args[2])
    if not act then return end
    if try(function() return act:get_address() end) ~= active_addr then return end
    if cfg.measure and active_started and active_name then
      L(string.format("MEASURE %-22s x%-5s dur=%.4f",
        active_name:match("[^.]+$"),
        tostring(cfg.enabled and cfg[TARGET[active_name]] or "off"),
        os.clock() - active_started))
    end
    active_name, active_addr, active_started, boosting = nil, nil, nil, false
  end)
  return sdk.PreHookResult.CALL_ORIGINAL
end, nil)

re.on_application_entry("LockScene", function()

  if not (cfg.enabled and boosting and active_name) then return end

  local ok, err = pcall(function()
    local factor = cfg[TARGET[active_name]]
    if not factor or factor == 1.0 then boosting = false return end

    local motion = player_motion()
    if not motion then return end

    local norm = layer0_norm(motion)
    if norm == nil or norm < 0.0 or norm >= (cfg.window or 0.60) then boosting = false return end

    local base = try(function() return motion:call("get_PlaySpeed") end)
    if not base or base <= 0.0 then return end
    motion:call("set_PlaySpeed", base * factor)
  end)
  if not ok and not threw then threw = true L("!! boost threw:", tostring(err)) end
end)

local ticks = 0
re.on_frame(function()
  ticks = ticks + 1
  if ticks % 30 ~= 0 then return end
  if active_started and (os.clock() - active_started) > 5.0 then
    active_name, active_addr, active_started, boosting = nil, nil, nil, false
  end

  if dirty and (os.clock() - dirty_at) > 0.5 then
    save_cfg()
    dirty = false
    L("settings saved: enabled=" .. tostring(cfg.enabled),
      "light=" .. tostring(cfg.light), "heavy=" .. tostring(cfg.heavy),
      "window=" .. tostring(cfg.window))
  end

  if ticks % 60 == 0 and not dirty and load_cfg() then
    L("config reloaded: enabled=" .. tostring(cfg.enabled),
      "light=" .. tostring(cfg.light), "heavy=" .. tostring(cfg.heavy),
      "window=" .. tostring(cfg.window))
  end
end)

local ui_threw = false

local function draw_body()
  local changed, v

  changed, v = imgui.checkbox("Enabled", cfg.enabled)
  if changed then cfg.enabled = v dirty = true dirty_at = os.clock() end

  changed, v = imgui.slider_float("Light combo", cfg.light, 1.0, 3.0, "%.2f x")
  if changed then cfg.light = v dirty = true dirty_at = os.clock() end

  changed, v = imgui.slider_float("Heavy combo", cfg.heavy, 1.0, 3.0, "%.2f x")
  if changed then cfg.heavy = v dirty = true dirty_at = os.clock() end

  changed, v = imgui.slider_float("Swing window", cfg.window, 0.05, 1.0, "%.2f")
  if changed then cfg.window = v dirty = true dirty_at = os.clock() end

  changed, v = imgui.checkbox("Log attack durations", cfg.measure)
  if changed then cfg.measure = v dirty = true dirty_at = os.clock() end

  if imgui.button("Reset to defaults") then
    for k, dv in pairs(DEFAULTS) do cfg[k] = dv end
    dirty = true dirty_at = os.clock()
  end
end

re.on_draw_ui(function()
  if not imgui.tree_node(MOD .. " " .. VERSION) then return end
  local ok, err = pcall(draw_body)
  imgui.tree_pop()
  if not ok and not ui_threw then ui_threw = true L("!! ui threw:", tostring(err)) end
end)

re.on_script_reset(function()
  active_name, active_addr, active_started, boosting = nil, nil, nil, false
end)

re.on_config_save(function()
  save_cfg()
  dirty = false
end)
