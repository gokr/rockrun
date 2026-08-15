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
- `src/world.nim` — owns ORX objects: level parsing, spawning/teardown,
  digging, collecting, tombstone set for same-frame deletions.
- `src/contacts.nim` — PHYSICS contact event queue and rules. ORX events
  arrive during Box2D steps, so bodies are never mutated there; contacts are
  drained once per frame afterwards.
- `src/movement.nim` — player input (keyboard + d-pad + analog axes) and
  velocity control; calls `world.digAround`.
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
```

Never run the test WITHOUT `-c test.ini`: with VSync on, compositor throttling
in automated environments can starve present events and hang the renderer in
`poll()` forever (observed on XWayland host).

Also re-generate levels after changing `tools/genlevels.py`:
`python3 tools/genlevels.py`.

## Conventions and hard-won facts

- ORX config: `#` is the LIST separator, `"..."` starts a BLOCK literal.
  Per-row level data therefore uses one key per row (`Row0 = "..."`).
- Text objects need BOTH `Graphic = @` and `Text = @` sections.
- Pure coordinates: 1 pixel = 1 world unit; physics `DimensionRatio 0.01`.
- Static cells (dirt/wall) have full 32px bodies forming a lattice; dynamic
  entities are SMALLER than the cell (player box 26px, boulder r=13.5, gem
  22px) — full-size dynamic bodies wedge into the lattice and freeze.
- The player has `CustomGravity = (0, 0, 0)` (classic BD anti-gravity). Dig
  happens by direction-aware proximity (`world.digAround`), floors require a
  downward input.
- HUD lives in a second viewport; ORX draws viewports first-created-first,
  and HUD objects are Z-separated so the main camera never renders them.
- ORX needs the ini named after the executable: keep `rockrun.ini` in sync
  with `bin = "rockrun"`, or tests built with a different `-o:` name will
  fail to find config.
- Box2D bodies must never be deleted from inside contact callbacks; the
  `destroyedObjects` tombstone set in `world.nim` protects same-frame pairs.
- Core clock runs at ~display frequency (240Hz on the dev host) with dt
  clamp — scripted tests use a dt multiplier (`TestClockMultiplier`) instead
  of waiting real seconds.

## Coding style

- Nim 2.x, full-module imports; `##` doc comments under proc signatures.
- Game state flows through `gs` (game.nim); ORX objects through world.nim;
  side effects (sound/fx/text) are the job of the module owning the cause.
- Public APIs marked `*`; keep physics/config-driven settings in the ini
  rather than hard-coded where feasible.
- Startup test must stay green and is the primary regression suite.
