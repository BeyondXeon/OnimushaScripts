# OnimushaScripts

REFramework Lua mods for **Onimusha: Way of the Sword** (Steam). Everything here is stable and consolidated at **v1.0**. Full history lives in the commit log.

## Requirements

- Onimusha: Way of the Sword (Steam version recommended)
- [REFramework](https://github.com/praydog/REFramework/releases) (`dinput8.dll` extracted into the game folder; menu opens with `Insert`)
- A text editor for configs (Notepad++, VS Code, or plain Notepad)

## Install

Copy the `.lua` files you want from `Onimusha_Test/reframework/autorun/` into the game's `reframework/autorun/` folder, then in-game open the REFramework menu (`Insert`) → **ScriptRunner** → **Reset Scripts**. Each mod appears as its own menu entry. No compilers, SDKs, or build steps — Lua scripts load as-is.

## Mods

| Mod (menu) | File | What it does | Config |
|---|---|---|---|
| DamageMult v1.0 | `damage_multiplier_v1.0.lua` | Outgoing player damage multiplier. Your own damage module passes through untouched; everything else scales. Preset buttons: x1 / x1.5 / x2 / x3 / x5 / x10 | `damage_multiplier.json` |
| AtkSpeed v1.0 | `attack_speed_v1.0.lua` | Attack swing animation speed via motion layers; restores cleanly on anything that isn't an attack. Preset buttons: x1 / x1.5 / x2 / x3 | `attack_speed.json` |
| MoveSpeed v1.0 | `movement_speed_v1.0.lua` | Locomotion speed: layer speed on every move clip plus root-motion rate on loop clips, with instant engage on action start. Slider x1.0–x3.0, live travel readout | `movement_speed.json` |
| Invincibility v1.0 | `invincibility_mod_v1.0.lua` | No-Hit + infinite HP with an independent poise/stagger bar. Off disables everything cleanly | `invincibility_mod.json` |
| ItemGiver v1.0 | `item_giver_v1.0.lua` | Give yourself items from a picker showing `Name [id] — Held X, Storehouse Y` | — |
| ItemCatalog v1.0 | `item_catalog_v1.0.lua` | Read-only item census the giver builds on | — |
| FOVSlider v1.0 | `fov_slider_v1.0.lua` | Field-of-view control | `fov_slider.json` |

Developer/diagnostic tools (not gameplay mods): `param_dump_v1.0.lua` (full parameter dump for research), `find_health_offset_v1.0.lua` (health offset scanner), `test_script.lua` (minimal load check: log line + UI text).

## Coexistence notes

- MoveSpeed and the standalone `run_speed` script both write motion layer speed — use one or the other, not both.
- MoveSpeed and AtkSpeed never touch each other's actions: attacks get ATK scaling only, movement gets MOV scaling only.
- Interaction actions (doors, chests, ladders, crawl, gaps) are left to FasterInteractions-style mods; this collection doesn't fight them.
- Turning any mod to x1/Off restores everything it changed (layers, rates, flags) and verifies a clean state.

## Known issues

- **Sprint ramp-up (MoveSpeed).** Sprint starts (`DashStart` transitions) are velocity-gated by the game: the state exits when your body is fast enough, and that ramp runs on physics time, so clip/rate scaling can't shorten it much. Sprint chained straight out of an attack feels it most (~0.5–1s). Walk/run engage at near-full speed immediately. No fix in-mod; sprint from neutral and hold it.
- **Two attack-speed mods installed.** The game folder currently contains both the third-party `AttackSpeed.lua` (PlaySpeed windows) and this collection's `attack_speed_v1.0.lua` (motion layers). Both speed up swings and can stack on the same attack. If swings feel double-timed, remove one.
- **Travel readout is a rolling average.** The menu's Travel m/s blends acceleration, turns, and stops. For the true multiplier, sprint straight for several seconds and read PEAK.
- **If Off ever feels slow (MoveSpeed).** The menu's `Off check` line reads back the real layer/rate values after restore (`layer=1 rate=1` is clean). Paste those two numbers plus `mov_proof.json` if vanilla feel doesn't return at x1.0.

## Repo layout

- `Onimusha_Test/reframework/autorun/` — the live, stable scripts (this README documents these)
- `Onimusha_Backup_Stable/` — backup mirror of an older stable set
- Commit history holds every retired version and experiment
