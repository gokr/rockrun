# AGENTS.md

## Project

Rockrun is a physics-driven Boulder Dash successor written in Nim 2.2+ on
the Norx wrapper (ORX 1.17 game engine, Box2D/LiquidFun physics). It is
played with keyboard or an SDL-compatible game controller, has OG-loop
music, SFX, particle/FX juice, a scroll-following camera and three caves.

## Layout

- `src/rockrun.nim` — main module: bootstrap, game loop, phase machine,
  camera, pause, startup test script. Everything wires through here.
- `src/game.nim` — run state singleton `gs` (score/lives/quota/timers/
  phases). No ORX object knowledge; freely importable.
- `src/world.nim` — owns ORX objects: level parsing, spawning/teardown
  (heroes as per-player `Player` records), digging, collecting, tombstone
  set for same-frame deletions.
- `src/contacts.nim` — PHYSICS contact event queue and rules. ORX events
  arrive during Box2D steps, so bodies are never mutated there; contacts are
  drained once per frame afterwards.
- `src/movement.nim` — per-player input (keyboard + d-pad + analog axes),
  velocity control and the idle/run/dig animation state machine living on
  each `Player` record; calls `world.digAround`.
- `src/creatures.nim` — fireflies/butterflies: wall-hugging steering
  decisions at cell centers against a static occupancy map (walls + live
  sand), explosion into diamonds when crushed.
- `src/ui.nim` — HUD text objects and transient centered messages.
- `src/screenshots.nim` — PNG capture helper.
- `tools/genlevels.py` — deterministic seeded cave generator; writes
  `data/config/levels.ini` (included by `rockrun.ini`).
- `data/config/` — all ORX config: physics bodies, FX, input, viewports,
  HUD, sounds/music, levels, plus `test.ini` overrides for automated runs.

## Build

Norx is expected at `~/tankfeud/norx` (override with `NORX_DIR`). ORX libs
must be built in `orx/code/lib/dynamic`.

```bash
nim c -o:rockrun src/rockrun.nim   # debug -> liborxd
nimble release                     # release -> liborx
```

`config.nims` asserts both locations exist at compile time.

## Verify

Always run the in-engine scripted test after changes (it plays the game and
writes screenshots to `./screenshots/`):

```bash
nimble test
# or: ./rockrun -c test.ini --startup-test true
# multiplayer variant: ./rockrun -c test.ini --startup-test-mp true
```

Never run the test WITHOUT `-c test.ini`: with VSync on, compositor throttling
in automated environments can starve present events and hang the renderer in
`poll()` forever (observed on XWayland host).

Also re-generate levels after changing `tools/genlevels.py`:
`python3 tools/genlevels.py`.

## Dev tooling (pi agent)

- `.pi/extensions/rockrun-test.ts` — pi tool `rockrun_test`: builds the
  game, runs the startup test and reports verdicts plus fresh screenshots.
- `.pi/skills/rockrun-dev/` — pi skill bundling this workflow (build/test
  loop, ORX config facts, multiplayer worktree conventions).
- A generic ORX config linter (`orx_ini_validate`) and an ORX/Norx
  documentation lookup (`orx_docs`, local source + wiki + doxygen)
  live globally in pi (`~/.pi/agent/extensions/`); both work on any
  ORX project.

## Conventions and hard-won facts

- ORX config: `#` is the LIST separator, `"..."` starts a BLOCK literal.
  Per-row level data therefore uses one key per row (`Row0 = "..."`).
- Text objects need BOTH `Graphic = @` and `Text = @` sections.
- Pure coordinates: 1 pixel = 1 world unit; physics `DimensionRatio 0.01`.
- Static cells (dirt/wall) have full 32px bodies forming a lattice; dynamic
  entities are SMALLER than the cell (player box 26px, boulder r=16, gem
  22px) — full-size dynamic bodies wedge into the lattice and freeze.
- Sand is two-tier: 32px blocks (Repeat 4x4 texture) silently refine into
  sixteen 8px grains (`SubGrid`/`SubBlock` in world.nim) near the player.
  Grains are tracked in a flat `fineGrains` seq (never stale) with per-cell
  `grainCounts` for creature steering; they stay static until a boulder
  touches them (`world.activateGrainColumn` makes the touched column
  dynamic so it gives way).
- The player has `CustomGravity = (0, 0, 0)` (classic BD anti-gravity). Dig
  happens by direction-aware proximity (`world.digAround`), floors require a
  downward input.
- Text objects need `Graphic = @` and `Text = @` plus `Font = GameFont`;
  fonts live in data/font (added to the Texture storage group).
- ORX animations: the OBJECT key is `AnimationSet`, the set lists
  `AnimationList = Idle # Run # Dig` with per-anim sections carrying their
  own Texture/KeyDuration, and the hero strips are 24px frames rendered at
  object scale 1.25 (physics box must stay ~26px via explicit part
  TopLeft/BottomRight).
- HUD lives in the main viewport as `ParentCamera` objects (camera-space
  positions); a second HUD viewport rendered the world twice (offset
  cave-border copy) and was removed.
- ORX needs the ini named after the executable: keep `rockrun.ini` in sync
  with `bin = "rockrun"`, or tests built with a different `-o:` name will
  fail to find config.
- Box2D bodies must never be deleted from inside contact callbacks; the
  `destroyedObjects` tombstone set in `world.nim` protects same-frame pairs.
- Core clock is tied to 60Hz via `[Clock] MainClockFrequency` so the sim
  advances in real time at normal frame rates; the display-refresh default
  made heavy caves run in slow motion below refresh-rate fps.

## Gameplay / multiplayer notes

- Lobby (`phModeSelect`) joins players by movement keys or controller
  Start (`JoinP2..4`); Enter starts with the joined count.
- Co-op: shared diamond quota, any player can finish the cave; per-player
  lives respawn at the spawn cell with invulnerability (no cave reload);
  run lives persist across caves (`gs.runLives`).
- Heroes are `Player` records: spawn cell, input set, animation state,
  lives, respawn/invulnerability timers. Players don't collide with each
  other (PlayerPart `CheckMask 0xFFFE`).
- Camera frames the active hero group: centroid follow with zoom-out
  (`orxCamera_SetFrustum`), never zooms in.

## Coding style

- Nim 2.x, full-module imports; `##` doc comments under proc signatures.
- Game state flows through `gs` (game.nim); ORX objects through world.nim;
  side effects (sound/fx/text) are the job of the module owning the cause.
- Public APIs marked `*`; keep physics/config-driven settings in the ini
  rather than hard-coded where feasible.
- Startup test must stay green and is the primary regression suite.
