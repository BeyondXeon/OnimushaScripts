// MoveSpeed v1.4 (C#) -- Onimusha: Way of the Sword, REFramework.NET source plugin.
// v1.4 MONITOR: v1.3 census showed the entity itself holds almost no
// numerics (24 fields, mostly flags) - the live state sits in supporter
// sub-objects. This build snapshots MoveSupporter, InputStateSupporter,
// MoveCancelChecker, TerrainSupporter and LockOnSupporter fields while
// moving. Still zero writes; Lua owns speed.
// v1.2: game log proved struct setters via IObject.Call silently no-op
// (fresh vec reads 0,0,0; clone write of 7.25 reads back 1) - so the v1.0
// pin is explained and direct vec construction is abandoned. Two struct-free
// paths instead: (1) set_OverrideMoveSpeed(float) - if the game honors it,
// it's the sanctioned, ramp-aware speed knob; (2) native op_Multiply on the
// game's OWN rate object for loop travel. Both verified by readback; layers
// carry on regardless. Boost stays off (needs arbitrary-vec construction).
// Standalone movement scaler. Ports the Lua MoveSpeed v1.0 logic:
// layer speed on every locomotion clip + root rate on Loop clips only,
// 45-frame hold latch, doEnter kick-start, Sprint keywords, attack-recovery
// gate, FasterInteractions exclusions. Travel assist is a CORRECTED
// displacement boost: it measures from the last-WRITTEN position, so the
// v2.4-style feedback runaway is impossible by construction.
// Preset buttons: x1 / x1.5 / x2 / x3.
//
// Deploy: copy to <game>/reframework/plugins/source/MoveSpeed.cs (hot-reload,
// no restart). Remove movement_speed_v1.0.lua from autorun while active.
// Config: reframework/data/movement_cs.json. Proof: mov_proof_cs.json.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using REFrameworkNET;
using REFrameworkNET.Attributes;
using REFrameworkNET.Callbacks;

public class MoveSpeed
{
    const string ModId = "MoveSpeed";
    const string Version = "1.4";
    // v1.3: monitor only - every write path below is gated on this.
    const bool MonitorOnly = true;
    static readonly float[] Presets = { 1f, 1.5f, 2f, 3f };

    const int HoldFrames = 45;
    const float MinSpeed = 0.3f;
    const float MaxStep = 0.5f;
    const float RecAt = 0.6f;
    const int MaxLayers = 64;

    static readonly string[] LocoClipKeys = { "Walk", "Run", "Dash", "Sprint", "Jog", "Strafe", "Turn", "Step", "Move" };
    static readonly string[] MotExclude = { "StepJump", "GenericFalling", "Falling", "NPC_", "Over_The_Fence", "Ladder", "Ledge", "Jump", "WallRun", "Guard", "Issen", "Bow", "QuickShot", "Tired" };
    static readonly string[] MoveEnums = {
        "app.plc_BaseMove_Mot.SetID", "app.plw_KatateMove_Mot.SetID",
        "app.plw_RyoteMove_Mot.SetID", "app.plw_tree_Mot.SetID", "app.plw_SubWeapon_Mot.SetID" };
    static readonly string[] ClimbKeys = { "Ladder", "Crawl", "GoThrough", "Climb", "Creep" };
    static readonly string[] HurtKeys = { "Damage", "Guard", "Stagger", "Knock", "Death", "Fall", "Hurt" };

    // ---- state ----
    static float _mov = 1.0f;
    static ManagedObject _playerGo, _chara, _entity, _motion;
    static ulong _playerGoAddr;
    static int _cooldown;
    static readonly Dictionary<ulong, float> _orig = new();
    static readonly Dictionary<ulong, float> _out = new();
    static ulong _catAddr; static string _cat;
    static readonly Dictionary<uint, Dictionary<uint, string>> _motNames = new();
    static double _lastX, _lastZ, _lastT; static bool _hasLast;
    static double _wroteX, _wroteZ; static bool _hasWrote;
    static int _hold;
    static uint _lastBank, _lastMot; static bool _hasClip;
    static bool _rateOn; static float _rateMult;
    static long _tick;
    static readonly List<string> _ring = new();
    static string _lastSource = "-", _lastClip = "?", _lastAct = "?";
    static string _blocked = "-";
    static float _layerSpeed, _movSpeed, _boosted;
    static string _cfgPath = "", _proofPath = "";
    static object _oneVec, _rateVec; static float _rateVecMult = float.NaN;
    // v1.1: vec3 construction is VERIFIED before any rate/boost write.
    // A silently-zero vector would pin root motion (frozen travel); writes
    // stay off until a round-trip readback proves the primitive works.
    static bool _vecOk = false, _vecTriedClone = false;
    static float _ovrSpeed = float.NaN, _moveVecRate = float.NaN;
    // v1.2 struct-free travel paths
    static bool _ovrActive = false, _ovrDirty = false;
    static float _ovrReadback = 0f;
    static string _rateMode = "layers"; // layers | override | opmul
    static bool _opTested = false;
    static Method _opMul;
    static float _rateRb = 0f;
    // v1.3 census: numeric entity/character fields while moving
    static readonly Dictionary<string, string> _probe = new();
    static int _errCount;
    static TypeDefinition _motionTd;

    // ---- helpers ----
    static void Log(string m) { try { API.LogInfo("[MoveSpeed] " + m); } catch { } }
    static void LogOnce(string m) { if (_errCount < 20) { _errCount++; Log(m); } }

    static ManagedObject Obj(object o) { return o as ManagedObject; }
    static object Call(ManagedObject o, string name, params object[] a)
    {
        try { return (o as IObject)?.Call(name, a); } catch { return null; }
    }
    static float ToF(object o, float dflt)
    {
        try { return o == null ? dflt : Convert.ToSingle(o); } catch { return dflt; }
    }
    static uint ToU(object o, uint dflt)
    {
        try { return o == null ? dflt : Convert.ToUInt32(o); } catch { return dflt; }
    }
    static int ToI(object o, int dflt)
    {
        try { return o == null ? dflt : Convert.ToInt32(o); } catch { return dflt; }
    }
    static ulong Addr(ManagedObject o)
    {
        try { return o == null ? 0 : o.GetAddress(); } catch { return 0; }
    }
    static void Ring(string ev)
    {
        try
        {
            _ring.Add(_tick + ":" + ev);
            while (_ring.Count > 20) _ring.RemoveAt(0);
        }
        catch { }
    }
    static string TypeName(ManagedObject o)
    {
        try
        {
            var td = o?.GetTypeDefinition();
            return td == null ? "?" : td.FullName;
        }
        catch { return "?"; }
    }
    static string ShortName(string full)
    {
        if (string.IsNullOrEmpty(full)) return "?";
        int i = full.LastIndexOf('.');
        return i < 0 ? full : full.Substring(i + 1);
    }
    static bool HasKey(string n, string[] keys)
    {
        if (string.IsNullOrEmpty(n)) return false;
        foreach (var k in keys) if (n.Contains(k)) return true;
        return false;
    }

    static string CfgDir()
    {
        try
        {
            var pluginPath = API.GetPluginDirectory(typeof(MoveSpeed).Assembly);
            var dir = new DirectoryInfo(pluginPath ?? Environment.CurrentDirectory);
            while (dir != null && !string.Equals(dir.Name, "reframework", StringComparison.OrdinalIgnoreCase))
                dir = dir.Parent;
            return dir != null ? Path.Combine(dir.FullName, "data")
                : Path.Combine(Environment.CurrentDirectory, "reframework", "data");
        }
        catch { return Environment.CurrentDirectory; }
    }

    static void LoadCfg()
    {
        try
        {
            if (File.Exists(_cfgPath))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(_cfgPath));
                if (doc.RootElement.TryGetProperty("mov", out var v) && v.ValueKind == JsonValueKind.Number)
                    _mov = Math.Max(1f, Math.Min(3f, (float)v.GetDouble()));
                return;
            }
            string old = Path.Combine(Path.GetDirectoryName(_cfgPath) ?? "", "damage_attack_speed.json");
            if (File.Exists(old))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(old));
                if (doc.RootElement.TryGetProperty("mov", out var v) && v.ValueKind == JsonValueKind.Number)
                    _mov = Math.Max(1f, Math.Min(3f, (float)v.GetDouble()));
            }
            SaveCfg();
        }
        catch (Exception ex) { LogOnce("cfg load: " + ex.Message); }
    }
    static void SaveCfg()
    {
        try { File.WriteAllText(_cfgPath, JsonSerializer.Serialize(new { mov = _mov })); }
        catch (Exception ex) { LogOnce("cfg save: " + ex.Message); }
    }
    static void WriteProof()
    {
        try
        {
            File.WriteAllText(_proofPath, JsonSerializer.Serialize(new
            {
                version = Version, tick = _tick, mov = _mov,
                entity = _entity != null, hold = _hold, latched = _hold > 0,
                blocked = _blocked, speed = _movSpeed, boosted = _boosted,
                last_source = _lastSource, last_clip = _lastClip, last_act = _lastAct,
                ring = _ring.ToArray(), layer_speed = _layerSpeed, vec_ok = _vecOk,
                // NaN is not valid JSON: sanitize (0 = not sampled yet)
                override_move = float.IsNaN(_ovrSpeed) ? 0f : _ovrSpeed,
                movevec_rate = float.IsNaN(_moveVecRate) ? 0f : _moveVecRate,
                ovr_readback = _ovrReadback, travel_mode = _rateMode, rate_readback = _rateRb,
                monitor = true, probe = _probe,
            }));
        }
        catch (Exception ex) { LogOnce("proof: " + ex.Message); }
    }

    // ---- resolve ----
    static bool ResolvePlayer()
    {
        try
        {
            if (_cooldown > 0) { _cooldown--; return _entity != null; }
            _cooldown = 60;
            var pm = API.GetManagedSingleton("app.PlayerManager");
            var mi = Obj(Call(pm, "getControllingPlayer"));
            var go = mi == null ? null : Obj(Call(mi, "get_Object"));
            if (go == null) return false;
            ulong a = Addr(go);
            if (_playerGo == null || a != _playerGoAddr)
            {
                _playerGo = go; _playerGoAddr = a;
                _chara = _entity = _motion = null;
                _out.Clear(); _catAddr = 0; _cat = null;
            }
            _chara = mi == null ? null : Obj(Call(mi, "get_Character"));
            _entity = mi == null ? null : Obj(Call(mi, "get_CharacterEntity"));
            return _entity != null;
        }
        catch { return _entity != null; }
    }

    static ManagedObject PlayerMotion()
    {
        try
        {
            if (_playerGo == null) return null;
            if (_motion != null && Addr(_motion) == 0) _motion = null;
            if (_motion == null)
            {
                if (_motionTd == null)
                {
                    try { _motionTd = API.GetTDB().FindType("via.motion.Motion"); }
                    catch (Exception ex) { LogOnce("motion type: " + ex.Message); return null; }
                    if (_motionTd == null) { LogOnce("via.motion.Motion not in TDB"); return null; }
                }
                var sysType = _motionTd.RuntimeType;
                _motion = Obj(Call(_playerGo, "getComponent", sysType));
            }
            return _motion;
        }
        catch { return null; }
    }

    static void BuildMotNames()
    {
        try
        {
            var tdb = API.GetTDB();
            int n = 0;
            foreach (var ename in MoveEnums)
            {
                TypeDefinition td;
                try { td = tdb.FindType(ename); } catch { continue; }
                if (td == null) continue;
                System.Collections.IEnumerable fields;
                try { fields = td.GetFields(); } catch { continue; }
                foreach (var f in fields)
                {
                    if (!(f is Field ff)) continue;
                    string fname;
                    try { fname = ff.Name; } catch { continue; }
                    if (fname == "value__") continue;
                    object v;
                    try { v = ff.GetDataBoxed(0, false); } catch { continue; }
                    if (!(v is uint) && !(v is int)) continue;
                    uint num = v is uint ? (uint)v : (uint)(int)v;
                    uint bank = num / 4096, id = num % 4096;
                    if (!_motNames.TryGetValue(bank, out var t2)) { t2 = new Dictionary<uint, string>(); _motNames[bank] = t2; }
                    // field name looks like "Dash_Start_Front_L_A" value label; store it
                    t2[id] = fname;
                    n++;
                }
            }
            Log("clip names loaded: " + n);
        }
        catch (Exception ex) { LogOnce("motnames: " + ex.Message); }
    }

    static string ClipName(uint bank, uint id)
    {
        try
        {
            if (_motNames.TryGetValue(bank, out var t) && t.TryGetValue(id, out var n)) return n;
        }
        catch { }
        return null;
    }
    static bool IsLocoClip(string name)
    {
        if (name == null || HasKey(name, MotExclude)) return false;
        return HasKey(name, LocoClipKeys);
    }

    // ---- layers ----
    static void ForEachLayer(Action<ManagedObject> fn)
    {
        var mo = PlayerMotion();
        if (mo == null) return;
        foreach (var pair in new[] { new[] { "getLayerCount", "getLayer" }, new[] { "getPrivateLayerCount", "getPrivateLayer" } })
        {
            int count = ToI(Call(mo, pair[0]), 0);
            if (count > MaxLayers) count = MaxLayers;
            for (int i = 0; i < count; i++)
            {
                var layer = Obj(Call(mo, pair[1], i));
                if (layer != null) { try { fn(layer); } catch { } }
            }
        }
    }
    static void ScaleLayers(float mult)
    {
        ForEachLayer(layer =>
        {
            ulong a = Addr(layer);
            if (!_orig.TryGetValue(a, out float o))
            {
                o = ToF(Call(layer, "get_Speed"), float.NaN);
                if (float.IsNaN(o)) return;
                _orig[a] = o;
            }
            if (o > 0 && (!_out.TryGetValue(a, out float w) || w != mult))
            {
                try { Call(layer, "set_Speed", o * mult); _out[a] = mult; } catch { }
            }
        });
    }
    static void RestoreLayers()
    {
        try
        {
            var mo = PlayerMotion();
            foreach (var kv in new Dictionary<ulong, float>(_orig))
            {
                ManagedObject found = null;
                if (mo != null)
                {
                    foreach (var pair in new[] { new[] { "getLayerCount", "getLayer" }, new[] { "getPrivateLayerCount", "getPrivateLayer" } })
                    {
                        int count = ToI(Call(mo, pair[0]), 0);
                        if (count > MaxLayers) count = MaxLayers;
                        for (int i = 0; i < count && found == null; i++)
                        {
                            var l = Obj(Call(mo, pair[1], i));
                            if (l != null && Addr(l) == kv.Key) found = l;
                        }
                        if (found != null) break;
                    }
                }
                if (found != null) { try { Call(found, "set_Speed", kv.Value); } catch { } }
                _orig.Remove(kv.Key); _out.Remove(kv.Key);
            }
        }
        catch (Exception ex) { LogOnce("restore: " + ex.Message); }
    }

    // ---- root rate ----
    // v1.1: gated on _vecOk (see SelfTest). Never returns an unverified vec.
    static object RateVec(float mult)
    {
        if (!_vecOk) return null;
        try
        {
            if (_rateVec == null || _rateVecMult != mult)
            {
                var vt = API.GetTDB().FindType("via.vec3").CreateValueType();
                (vt as IObject).Call("set_x", mult);
                (vt as IObject).Call("set_y", mult);
                (vt as IObject).Call("set_z", mult);
                _rateVec = vt; _rateVecMult = mult;
            }
            return _rateVec;
        }
        catch (Exception ex) { LogOnce("ratevec: " + ex.Message); return null; }
    }
    static object OneVec()
    {
        if (!_vecOk) return null;
        try
        {
            if (_oneVec == null)
            {
                var vt = API.GetTDB().FindType("via.vec3").CreateValueType();
                (vt as IObject).Call("set_x", 1f);
                (vt as IObject).Call("set_y", 1f);
                (vt as IObject).Call("set_z", 1f);
                _oneVec = vt;
            }
            return _oneVec;
        }
        catch (Exception ex) { LogOnce("onevec: " + ex.Message); return null; }
    }
    static void SyncRate(float mult, bool want)
    {
        try
        {
            if (_entity == null) return;
            if (want && mult > 1f)
            {
                // v1.2: native-multiply path first (game-owned object throughout)
                if (_rateMode == "opmul" && _opMul != null)
                {
                    OpApplyRate(mult);
                    _rateOn = true; _rateMult = mult;
                    return;
                }
                var v = RateVec(mult);
                if (v != null) Call(_entity, "set_ActionRootTransRate", v);
                _rateOn = true; _rateMult = mult;
            }
            else if (_rateOn)
            {
                // v1.2: opmul restores exactly (cur*1); fresh-vec path keeps
                // the readback-conditional restore (never writes blind).
                if (_rateMode == "opmul" && _opMul != null) OpApplyRate(1f);
                else
                {
                    var r = Call(_entity, "get_ActionRootTransRate");
                    float x = float.NaN;
                    try { x = Convert.ToSingle((r as IObject).GetField("x")); } catch { }
                    if (!float.IsNaN(x) && Math.Abs(x - _rateMult) < 0.001f)
                    {
                        var one = OneVec();
                        if (one != null) Call(_entity, "set_ActionRootTransRate", one);
                    }
                }
                _rateOn = false;
            }
        }
        catch (Exception ex) { LogOnce("rate: " + ex.Message); }
    }

    // ---- v1.1 vec verification ----
    // Build a vec3, read it back. Only exact round-trip enables writes.
    static bool SelfTestFresh()
    {
        try
        {
            var td = API.GetTDB().FindType("via.vec3");
            if (td == null) { Log("vec selftest: via.vec3 missing"); return false; }
            var vt = td.CreateValueType();
            var vi = vt as IObject;
            if (vi == null) { Log("vec selftest: no IObject on ValueType"); return false; }
            vi.Call("set_x", 2.5f); vi.Call("set_y", 3.5f); vi.Call("set_z", 4.5f);
            float x = Convert.ToSingle(vi.GetField("x"));
            float y = Convert.ToSingle(vi.GetField("y"));
            float z = Convert.ToSingle(vi.GetField("z"));
            Log($"vec selftest fresh: {x},{y},{z}");
            return Math.Abs(x - 2.5f) < 0.01 && Math.Abs(y - 3.5f) < 0.01 && Math.Abs(z - 4.5f) < 0.01;
        }
        catch (Exception ex) { Log("vec selftest fresh fail: " + ex.Message); return false; }
    }
    // ---- v1.3 field census ----
    // Enumerate plain-numeric fields of an object and snapshot values.
    // Hunting a float/int speed knob writable via SetDataBoxed (method
    // dispatch on structs is broken in this interop; raw field writes
    // may be the only C# travel path left).
    static void ProbeFloats(ManagedObject obj, string prefix)
    {
        try
        {
            if (obj == null) return;
            ulong addr = Addr(obj);
            if (addr == 0) return;
            TypeDefinition td;
            try { td = obj.GetTypeDefinition(); } catch { return; }
            if (td == null) return;
            System.Collections.IEnumerable fields;
            try { fields = td.GetFields(); } catch { return; }
            int n = 0;
            foreach (var f in fields)
            {
                if (n >= 60) break;
                if (!(f is Field ff)) continue;
                string fn, ft;
                try
                {
                    bool isStatic = false;
                    try { isStatic = ff.IsStatic(); } catch { }
                    if (isStatic) continue;
                    fn = ff.Name;
                    ft = ff.Type != null ? ff.Type.FullName : "?";
                }
                catch { continue; }
                if (ft != "System.Single" && ft != "System.Double" && ft != "System.Int32"
                    && ft != "System.UInt32" && ft != "System.Boolean") continue;
                object v;
                try { v = ff.GetDataBoxed(addr, false); } catch { continue; }
                if (v == null) continue;
                _probe[prefix + fn] = v.ToString();
                n++;
            }
            while (_probe.Count > 220)
            {
                string first = null;
                foreach (var k in _probe.Keys) { first = k; break; }
                if (first == null) break;
                _probe.Remove(first);
            }
        }
        catch (Exception ex) { LogOnce("probe: " + ex.Message); }
    }

    // v1.4: supporter objects off the entity (MoveSupporter et al).
    // Resolved by getter name; missing getters are skipped silently.
    static readonly string[] Supporters = { "MoveSupporter", "InputStateSupporter",
        "MoveCancelChecker", "TerrainSupporter", "LockOnSupporter" };
    static void ProbeSupporters()
    {
        try
        {
            if (_entity == null) return;
            foreach (var s in Supporters)
            {
                ManagedObject o = null;
                try { o = Obj(Call(_entity, "get_" + s)); } catch { continue; }
                if (o == null) continue;
                ProbeFloats(o, "s." + s + ".");
            }
        }
        catch (Exception ex) { LogOnce("supporters: " + ex.Message); }
    }

    // ---- v1.2 struct-free travel (dormant in monitor) ----
    // (1) Override knob: pure float, no vec3 involved. Written on engage,
    // restored on release. Readback decides whether the game honors it.
    static void ApplyOverride()
    {
        try
        {
            if (_entity == null) return;
            Call(_entity, "set_OverrideMoveSpeed", _mov);
            _ovrActive = true;
            float rb = ToF(Call(_entity, "get_OverrideMoveSpeed"), float.NaN);
            _ovrReadback = float.IsNaN(rb) ? 0f : rb;
            Log($"override: wrote {_mov} readback {_ovrReadback}");
            if (!float.IsNaN(rb) && Math.Abs(rb - _mov) < 0.01f && _rateMode == "layers")
            {
                _rateMode = "override";
                Log("override HONORED by game - travel via sanctioned knob");
            }
        }
        catch (Exception ex) { LogOnce("override apply: " + ex.Message); }
    }
    static void RestoreOverride()
    {
        try
        {
            if (!_ovrActive || _entity == null) { _ovrActive = false; return; }
            Call(_entity, "set_OverrideMoveSpeed", 1f);
            _ovrActive = false;
            if (_rateMode == "override") _rateMode = "layers";
        }
        catch (Exception ex) { LogOnce("override restore: " + ex.Message); }
    }
    // (2) Native op_Multiply on the game's OWN rate object: no construction,
    // no setters - the multiply happens natively. Verified by readback.
    static void OpTestRate()
    {
        _opTested = true;
        try
        {
            if (_entity == null) return;
            var vecTd = API.GetTDB().FindType("via.vec3");
            if (vecTd == null) { Log("opmul: via.vec3 missing"); return; }
            Method found = null;
            var methods = vecTd.GetMethods();
            foreach (var m in methods)
            {
                Method mm = m as Method;
                if (mm == null) continue;
                if (mm.Name != "op_Multiply") continue;
                uint n = 0;
                try { n = mm.GetNumParams(); } catch { continue; }
                if (n != 2) continue;
                found = mm;
                break;
            }
            if (found == null) { Log("opmul: op_Multiply(vec3,float) not found"); return; }
            var cur = Call(_entity, "get_ActionRootTransRate");
            if (cur == null) { Log("opmul: rate unreadable"); return; }
            Log("opmul: built candidate, testing write+readback");
            _opMul = found;
            OpApplyRate(2f);
            float rb = ReadRateX();
            Log($"opmul: wrote 2x readback {rb}");
            if (!float.IsNaN(rb) && Math.Abs(rb - 2f) < 0.05f)
            {
                _rateMode = "opmul";
                Log("opmul HONORED - loop travel via native multiply");
            }
            // leave the game at whatever it had: restore x1 best-effort
            OpApplyRate(1f);
        }
        catch (Exception ex) { Log("opmul test fail: " + ex.Message); }
    }
    static float ReadRateX()
    {
        try
        {
            var r = Call(_entity, "get_ActionRootTransRate");
            if (r == null) return float.NaN;
            return Convert.ToSingle((r as IObject).GetField("x"));
        }
        catch { return float.NaN; }
    }
    static void OpApplyRate(float mult)
    {
        try
        {
            if (_opMul == null || _entity == null) return;
            var cur = Call(_entity, "get_ActionRootTransRate");
            if (cur == null) return;
            object vecObj = _opMul.InvokeBoxed(typeof(object), null, new object[] { cur, mult });
            if (vecObj != null) Call(_entity, "set_ActionRootTransRate", vecObj);
        }
        catch (Exception ex) { LogOnce("opmul apply: " + ex.Message); }
    }
    static bool SelfTestClone()
    {
        try
        {
            if (_entity == null) return false;
            var r = Call(_entity, "get_ActionRootTransRate");
            var ri = r as IObject;
            if (ri == null) { Log("vec selftest: rate object not readable"); return false; }
            float ox = Convert.ToSingle(ri.GetField("x"));
            ri.Call("set_x", 7.25f);
            Call(_entity, "set_ActionRootTransRate", r);
            var back = Call(_entity, "get_ActionRootTransRate");
            float bx = Convert.ToSingle((back as IObject).GetField("x"));
            // restore whatever was there
            ri.Call("set_x", ox);
            Call(_entity, "set_ActionRootTransRate", r);
            Log($"vec selftest clone: wrote 7.25 read {bx}, restored {ox}");
            return Math.Abs(bx - 7.25f) < 0.01;
        }
        catch (Exception ex) { Log("vec selftest clone fail: " + ex.Message); return false; }
    }

    // ---- action classify ----
    static ManagedObject CurrentAction()
    {
        try { return _chara == null ? null : Obj(Call(_chara, "get_BaseCurrentAction")); }
        catch { return null; }
    }
    static string ActionCategory(ManagedObject act, out string shortName)
    {
        shortName = "?";
        try
        {
            if (act == null) return null;
            ulong a = Addr(act);
            if (a != 0 && a == _catAddr) { shortName = _lastActName; return _cat; }
            string full = TypeName(act);
            string n = ShortName(full);
            shortName = n;
            string c = null;
            if (n.Contains("Attack")) c = "attack";
            else if (HasKey(n, LocoClipKeys)) c = "move";
            else c = "other";
            if (a != 0) { _catAddr = a; _cat = c; _lastActName = n; }
            return c;
        }
        catch { return null; }
    }
    static string _lastActName = "?";
    static bool IsInteraction(ManagedObject act)
    {
        try
        {
            if (act == null) return false;
            var td = act.GetTypeDefinition();
            if (td == null) return false;
            if (td.IsDerivedFrom("app.PlayerCommonAction.cLadderActionBase")) return true;
            if (td.IsDerivedFrom("app.PlayerCommonAction.cCreepBase")) return true;
            if (td.IsDerivedFrom("app.PlayerCommonAction.cGoThroughBase")) return true;
            if (td.IsDerivedFrom("app.PlayerCommonAction.cInteractGimmickBase")) return true;
            string full = td.FullName;
            if (!string.IsNullOrEmpty(full) && full.Contains("DemonTendon")) return true;
            return false;
        }
        catch { return false; }
    }

    static double Now() { return Environment.TickCount64 / 1000.0; }

    // ---- per-frame ----
    static void TickPre()
    {
        try
        {
            _tick++;
            if (_tick % 600 == 0) WriteProof();
            if (_tick % 60 == 0 && _hold > 0)
            {
                try
                {
                    var mo = PlayerMotion();
                    var ly = mo == null ? null : Obj(Call(mo, "getLayer", 0));
                    if (ly != null) _layerSpeed = (float)Math.Round(ToF(Call(ly, "get_Speed"), 0f), 2);
                }
                catch { }
                // v1.1: sanctioned-knob diagnostics (reads only, never written here)
                // v1.3: + numeric field census while latched (the actual hunt)
                try
                {
                    if (_entity != null)
                    {
                        _ovrSpeed = ToF(Call(_entity, "get_OverrideMoveSpeed"), float.NaN);
                        _moveVecRate = ToF(Call(_entity, "get_MoveVectorInputRate"), float.NaN);
                        _rateRb = (float)Math.Round(ReadRateX(), 2);
                        if (float.IsNaN(_rateRb)) _rateRb = 0f;
                    }
                    if (_hold > 0)
                    {
                        ProbeFloats(_entity, "e.");
                        ProbeFloats(_chara, "c.");
                        ProbeSupporters(); // v1.4: one level deeper
                    }
                }
                catch { }
            }
            // v1.2: preset changed mid-latch -> re-apply override immediately
            // v1.3: monitor never writes; just consume the flag.
            if (_ovrDirty)
            {
                _ovrDirty = false;
                if (!MonitorOnly)
                {
                    if (_hold > 0) ApplyOverride();
                    else RestoreOverride();
                }
            }
            if (!(_mov > 1f))
            {
                if (!MonitorOnly && _orig.Count > 0) RestoreLayers(); // v1.3: Lua owns layers
                SyncRate(1f, false);
                RestoreOverride(); // v1.2
                _hasLast = false; _hasWrote = false; _hold = 0;
                return;
            }
            if (!ResolvePlayer()) { _hasLast = false; return; }
            if (_playerGo != null && Addr(_playerGo) != _playerGoAddr)
            {
                RestoreLayers();
                _motion = null;
                _hasLast = false; _hasWrote = false; _hold = 0;
                return;
            }
            var act = CurrentAction();
            string aname;
            string cat = ActionCategory(act, out aname);
            if (cat == "attack")
            {
                float rec = float.NaN;
                try
                {
                    var mo = PlayerMotion();
                    var ly = mo == null ? null : Obj(Call(mo, "getLayer", 0));
                    if (ly != null) rec = ToF(Call(ly, "get_NormalizeTime"), float.NaN);
                }
                catch { }
                if (float.IsNaN(rec) || rec < RecAt)
                {
                    _hasLast = false; _hasWrote = false; _hold = 0;
                    _blocked = "attack";
                    if (!MonitorOnly && _orig.Count > 0) RestoreLayers(); // v1.3: Lua owns layers
                    SyncRate(1f, false);
                    RestoreOverride(); // v1.2
                    return;
                }
                _blocked = "attack-rec";
            }
            if (act != null && IsInteraction(act))
            {
                _hasLast = false; _hasWrote = false; _hold = 0;
                _blocked = "interact";
                if (!MonitorOnly && _orig.Count > 0) RestoreLayers(); // v1.3: Lua owns layers
                SyncRate(1f, false);
                RestoreOverride(); // v1.2
                return;
            }
            if (_blocked != "attack-rec") _blocked = "-";

            // engage sources
            bool locoClip = false, loopClip = false;
            uint bank = 0, mot = 0;
            try
            {
                var mo = PlayerMotion();
                var ly = mo == null ? null : Obj(Call(mo, "getLayer", 0));
                if (ly != null)
                {
                    bank = ToU(Call(ly, "get_MotionBankID"), uint.MaxValue);
                    mot = ToU(Call(ly, "get_MotionID"), uint.MaxValue);
                    if (bank != uint.MaxValue && mot != uint.MaxValue)
                    {
                        if (!_hasClip || bank != _lastBank || mot != _lastMot)
                        {
                            _lastBank = bank; _lastMot = mot; _hasClip = true;
                            _out.Clear(); // force rewrite on clip change
                        }
                        string cn = ClipName(bank, mot);
                        locoClip = IsLocoClip(cn);
                        loopClip = cn != null && cn.Contains("Loop");
                    }
                }
            }
            catch (Exception ex) { LogOnce("clip: " + ex.Message); }
            bool moveAct = HasKey(aname, LocoClipKeys);
            bool climbing = HasKey(aname, ClimbKeys);
            bool moving = false, bok = false;
            double bdx = 0, bdz = 0;
            double now = Now();
            ManagedObject tf = null; object posObj = null;
            float px = 0, pz = 0;
            try
            {
                tf = _playerGo == null ? null : Obj(Call(_playerGo, "get_Transform"));
                posObj = tf == null ? null : Call(tf, "get_Position");
                var pv = posObj as IObject;
                if (pv != null)
                {
                    px = Convert.ToSingle(pv.GetField("x"));
                    pz = Convert.ToSingle(pv.GetField("z"));
                    if (_hasLast)
                    {
                        double dx = px - _lastX, dz = pz - _lastZ;
                        double dist = Math.Sqrt(dx * dx + dz * dz);
                        double dt = now - _lastT;
                        if (dt > 0 && dt < 1.0 && dist < MaxStep)
                        {
                            moving = dist / dt > MinSpeed;
                            bdx = dx; bdz = dz; bok = true;
                            _movSpeed = (float)Math.Round(dist / dt, 2);
                        }
                    }
                    _lastX = px; _lastZ = pz; _lastT = now; _hasLast = true;
                }
                else _hasLast = false;
            }
            catch (Exception ex) { LogOnce("travel: " + ex.Message); _hasLast = false; }

            if (climbing)
            {
                _hasLast = false; _hasWrote = false; _hold = 0;
            }
            else
            {
                if (locoClip || moveAct || moving)
                {
                    string src = locoClip ? "clip" : (moveAct ? "action" : "travel");
                    if (_hold <= 0)
                    {
                        Ring("engage:" + src);
                        _lastSource = src;
                        _lastClip = ClipName(bank, mot) ?? "?";
                        _lastAct = aname ?? "?";
                        if (!MonitorOnly) // v1.3: monitor never writes
                        {
                            ApplyOverride(); // sanctioned knob first
                            if (!_opTested) OpTestRate(); // native-multiply test
                        }
                    }
                    _hold = HoldFrames;
                }
                else if (_hold > 0)
                {
                    _hold--;
                    if (_hold == 0) Ring("release");
                }
                if (_hold > 0)
                {
                    // v1.3 monitor: trace only. Sources/ring/proof updated
                    // above; every write (layers, rate, boost, override)
                    // belongs to the Lua script while monitoring.
                    return;
                }
            }
            if (!MonitorOnly && _orig.Count > 0) RestoreLayers(); // v1.3: Lua owns layers
            SyncRate(1f, false);
            RestoreOverride(); // v1.2
        }
        catch (Exception ex) { LogOnce("tick: " + ex.Message); }
    }

    static void TickPost()
    {
        try
        {
            if (!_rateOn || _entity == null) return;
            if (!(_rateMult > 1f)) return;
            var v = RateVec(_rateMult);
            if (v != null) Call(_entity, "set_ActionRootTransRate", v);
        }
        catch { }
    }

    // ---- doEnter kick (dynamic hook; poll covers us if install fails) ----
    static void InstallKick()
    {
        try
        {
            var td = API.GetTDB().FindType("app.PlayerActionBase.cPlayerActionBase");
            if (td == null) { Log("doEnter type missing - kick disabled, poll only"); return; }
            var m = td.GetMethod("doEnter");
            if (m == null) { Log("doEnter missing - kick disabled, poll only"); return; }
            var hook = m.AddHook(false);
            hook.AddPre(args =>
            {
                try { OnActionEnter(args); } catch (Exception ex) { LogOnce("kick: " + ex.Message); }
                return PreHookResult.Continue;
            });
            Log("doEnter kick-start hooked");
        }
        catch (Exception ex) { Log("kick install failed (poll only): " + ex.Message); }
    }

    static void OnActionEnter(Span<ulong> args)
    {
        if (!(_mov > 1f)) return;
        if (args.Length < 2) return;
        var act = ManagedObject.ToManagedObject(args[1]);
        if (act == null) return;
        if (!ResolvePlayer() || _entity == null) return;
        ulong ae = 0, ee = 0;
        try
        {
            var aenty = Obj((act as IObject).Call("get_CharacterEntity"));
            if (aenty == null) return;
            ae = Addr(aenty); ee = Addr(_entity);
        }
        catch { return; }
        if (ae == 0 || ae != ee) return;
        string short_ = ShortName(TypeName(act));
        if (short_.Contains("Attack"))
        {
            _hasLast = false; _hasWrote = false; _hold = 0;
            Ring("act-enter:attack " + short_);
            return;
        }
        if (IsInteraction(act))
        {
            _hasLast = false; _hasWrote = false; _hold = 0;
            Ring("act-enter:interact " + short_);
            return;
        }
        if (HasKey(short_, LocoClipKeys))
        {
            _hold = HoldFrames;
            _hasLast = false;
            _out.Clear();
            if (!MonitorOnly) ScaleLayers(_mov); // v1.3: trace only
            _lastSource = "doenter"; _lastClip = "?"; _lastAct = short_;
            Ring("kick:" + short_);
        }
    }

    // ---- ui ----
    static string Fmt(float v) { return "x" + (v == Math.Floor(v) ? ((int)v).ToString() : v.ToString()); }
    static void DrawUI()
    {
        try
        {
            if (!Hexa.NET.ImGui.ImGui.TreeNode("MoveSpeed v" + Version + " (C#)##MoveSpeedCS")) return;
            try
            {
                Hexa.NET.ImGui.ImGui.TextUnformatted("MONITOR ONLY - speed by Lua script");
                Hexa.NET.ImGui.ImGui.TextUnformatted(_mov > 1f ? "watching MOV " + Fmt(_mov) + " [" + _rateMode + "]" : "OFF");
                for (int i = 0; i < Presets.Length; i++)
                {
                    if (i > 0) Hexa.NET.ImGui.ImGui.SameLine();
                    string label = (_mov == Presets[i] ? "[" + Fmt(Presets[i]) + "]##" : Fmt(Presets[i]) + "##") + "mv" + i;
                    if (Hexa.NET.ImGui.ImGui.Button(label)) { _mov = Presets[i]; SaveCfg(); _rateVecMult = float.NaN; _ovrDirty = true; }
                }
            }
            finally { Hexa.NET.ImGui.ImGui.TreePop(); }
        }
        catch (Exception ex) { LogOnce("ui: " + ex.Message); }
    }

    // ---- lifecycle ----
    [PluginEntryPoint]
    public static void Main()
    {
        try
        {
            string dir = CfgDir();
            try { Directory.CreateDirectory(dir); } catch { }
            _cfgPath = Path.Combine(dir, "movement_cs.json");
            _proofPath = Path.Combine(dir, "mov_proof_cs.json");
            LoadCfg();
            _vecOk = SelfTestFresh();
            Log("vec verdict at load: writes " + (_vecOk ? "ENABLED" : "DISABLED (clone retry on first latch)"));
            BuildMotNames();
            InstallKick();
            Log("loaded v" + Version + " mov=" + _mov);
        }
        catch (Exception ex) { Log("fatal: " + ex.Message); }
    }

    [PluginExitPoint]
    public static void OnUnload()
    {
        try
        {
            // v1.3 monitor: touch nothing on unload (Lua owns all state).
            if (!MonitorOnly)
            {
                try { RestoreLayers(); } catch { }
                try { SyncRate(1f, false); _rateOn = false; } catch { }
                try { RestoreOverride(); } catch { }
            }
            SaveCfg();
            try { WriteProof(); } catch { }
            _playerGo = _chara = _entity = _motion = null;
            _orig.Clear(); _out.Clear();
            Log("unloaded");
        }
        catch { }
    }

    [Callback(typeof(UpdateMotion), CallbackType.Pre)]
    public static void OnPreMotion() { TickPre(); }

    [Callback(typeof(UpdateMotion), CallbackType.Post)]
    public static void OnPostMotion() { TickPost(); }

    [Callback(typeof(ImGuiDrawUI), CallbackType.Post)]
    public static void OnDrawUI() { DrawUI(); }
}
