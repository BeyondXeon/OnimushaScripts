# OnimushaScripts

REFramework Lua mods for **Onimusha: Way of the Sword** (Steam). Everything here is stable and consolidated at **v1.0**. Full history lives in the commit log.

## Requirements

- Onimusha: Way of the Sword (Steam version recommended)
- [REFramework](https://github.com/praydog/REFramework/releases) (see setup below — includes an Onimusha-specific build on [Nexus Mods](https://www.nexusmods.com/onimushawayofthesword/mods/54))
- A text editor for configs (Notepad++, VS Code, or plain Notepad)

## Install

### 1. Install REFramework (once)

1. Download REFramework — either the [GitHub release](https://github.com/praydog/REFramework/releases) or the Onimusha build from [Nexus Mods](https://www.nexusmods.com/onimushawayofthesword/mods/54).
2. Extract `dinput8.dll` from the zip **into your Onimusha game install folder** (the one containing the game `.exe`).
3. Launch the game via Steam, then press `Insert` — the REFramework menu should appear. This also creates the `reframework/` folder (including `reframework/autorun/`) on first run.

### 2. Install these scripts

**Option A — release zip (easiest):**

1. Go to [Releases](https://github.com/BeyondXeon/OnimushaScripts/releases) and download `OnimushaScripts-v1.0.zip`.
2. Find your game folder: in Steam, right-click Onimusha → **Manage** → **Browse local files**.
3. Extract the zip **into the game folder** (the same folder holding the game `.exe` and `dinput8.dll`). The scripts land in `reframework/autorun/`. Your folder should now contain paths like `reframework/autorun/movement_speed_v1.0.lua`.
4. (Optional) If you added the files while the game was already running, open the REFramework menu (`Insert`), go to **ScriptRunner**, and click **Reset Scripts** to load them without restarting. Files placed before launch load automatically.
5. Each mod shows up as its own entry in the REFramework menu (DamageMult, AtkSpeed, MoveSpeed, Invincibility, ItemGiver, ItemCatalog, FOVSlider). Open one, set your options — a config `.json` is auto-created in `reframework/data/` so settings persist.

**Option B — pick individual scripts:**

Same as above, but instead of the zip, copy only the `.lua` files you want from `reframework/autorun/` in this repo into the game's `reframework/autorun/` folder, then Reset Scripts in-game.

**If something doesn't show up:**

- Menu entry missing → the file must end in `.lua` (not `.lua.txt` — turn on file extensions in Explorer) and sit directly in `reframework/autorun/`.
- REFramework menu itself won't open → `dinput8.dll` is in the wrong folder or was quarantined by antivirus; re-extract it next to the game `.exe`.
- Settings not saving → check the game folder is writable (not read-only, Steam has permission to write `reframework/data/`).

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

- `reframework/autorun/` — the live, stable scripts (this README documents these)
- `Backup/` — backup mirror of an older stable set
- Commit history holds every retired version and experiment
