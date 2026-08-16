---
name: rockrun-dev
cluster: coding
description: "Rockrun development workflow: physics-driven Boulder Dash in Nim + Norx/ORX — build/test loop with the in-engine startup test, ORX config gotchas, level generation, and the local-multiplayer worktree workflow. Use whenever working in the rockrun repo (src/, data/config/, tools/genlevels.py)."
tags: ["nim", "orx", "rockrun", "game", "boulder-dash", "box2d", "norx"]
dependencies: []
composes: []
similar_to: ["coding-nim"]
called_by: []
authorization_required: false
scope: general
model_hint: claude-sonnet
embedding_hint: "rockrun nim orx norx box2d boulder dash levels.ini startup test multiplayer rockrun.ini"
---

# Rockrun Development

Physics-driven Boulder Dash successor: Nim 2.2+ on the Norx wrapper
(ORX 1.17 + Box2D/LiquidFun). Every boulder, gem, dirt block, wall and
hero is a Box2D body; game logic listens to contact events and nudges
heroes. Repos: `~/git/rockrun` (main) and `~/git/rockrun-mp`
(branch `multiplayer`, local-multiplayer work per `docs/MULTIPLAYER.md`).

## Standard loop (after EVERY change to src/, data/config/, tools/)

1. **Build**: `nim c -o:rockrun src/rockrun.nim` (debug → liborxd).
   `nimble release` for the release build (liborx).
2. **Test**: use the `rockrun_test` tool (build + run + verdicts + fresh
   screenshots in one call), or manually:
   `./rockrun -c test.ini --startup-test true`
   - **NEVER run the test without `-c test.ini`**: with VSync on,
     compositor throttling in automated environments can stall the
     renderer in `poll()` forever (observed on XWayland).
   - The test must print `Rockrun config checks passed`,
     `Rockrun engine checks passed`, `Rockrun completion checks passed`
     and exit 0. It plays the game (gravity drop, dig/collect run,
     creature explosion, exit completion into cave 2) and writes
     screenshots to `./screenshots/`.
3. **Review screenshots** after visual/engine changes.
4. **Regenerate levels** after changing `tools/genlevels.py`:
   `python3 tools/genlevels.py` (writes `data/config/levels.ini`).
5. Config edits: run `orx_ini_validate` — ORX fails silently on missing
   sections; the linter cross-checks Body/PartList/Graphic/AnimationSet/
   FX/Font/Camera references, sound/texture files, input bindings and
   level tables without launching the game.

## ORX config facts (hard-won)

- `#` is the LIST separator; `"..."` starts a BLOCK literal. Per-row
  level data uses one key per row (`Row0 = "..."`).
- Text objects need `Graphic = @` AND `Text = @` plus `Font = GameFont`;
  fonts live in data/font (added to the Texture storage group).
- The ini must be named after the executable: keep `rockrun.ini` in
  sync with `bin = "rockrun"` (config.nims / nimble), or tests built
  with a different `-o:` name fail to find config.
- Pure coordinates: 1 pixel = 1 world unit; physics
  `DimensionRatio 0.01`. Cell = 32 units.
- Static cells (dirt/wall) have full 32px bodies forming a lattice;
  dynamic entities are SMALLER than the cell (hero box 26px, boulder
  r=16, gem 22px) — full-size dynamic bodies wedge into the lattice.
- Sand is two-tier: 32px blocks silently refine into nine 10.7px
  blocks (`SubGrid`/`SubBlock` in world.nim) near heroes.
- The hero has `CustomGravity = (0, 0, 0)` (classic BD anti-gravity).
  Digging is proximity-based (`world.digAround`); floors need a
  downward input.
- ORX animations: OBJECT key is `AnimationSet`; the set lists
  `StartAnimList = Idle # Run # Dig` with per-anim sections carrying
  their own Texture/KeyDuration; hero strips are 24px frames at scale
  1.25 with an explicit physics part (~26px).
- Box2D bodies must never be deleted inside contact callbacks: ORX
  events arrive during physics steps; contacts are queued in
  contacts.nim and drained once per frame; `destroyedObjects`
  (world.nim) protects same-frame pairs.
- Core clock runs at ~display frequency (240Hz on the dev host) with a
  dt clamp; scripted tests use `TestClockMultiplier` instead of real
  seconds. The startup-test scenario is a declarative `TestAction`
  table in rockrun.nim.

## Multiplayer worktree (branch `multiplayer`)

- Work happens in `~/git/rockrun-mp` on branch `multiplayer`;
  `~/git/rockrun` stays on `main`.
- Plan: `docs/MULTIPLAYER.md` (local 1–4 players; coop + race modes).
- Architecture: heroes are `Player` records in `world.players`
  (world.nim); movement/contacts attribute dig/collect/death to the
  touching hero via `playerObj()`/`playerOf()`.
- Rule: the single-player startup test must stay green after every
  phase; a second scripted scenario (`--startup-test-mp`) covers
  multiplayer behavior.

## Conventions

- Nim 2.x, full-module imports; `##` doc comments under proc
  signatures; game state flows through `gs` (game.nim), ORX objects
  through world.nim, side effects belong to the module owning the
  cause; public APIs marked `*`; keep physics/config-driven settings
  in the ini, not hard-coded.
- `nimble test` and `python3 tools/genlevels.py` per AGENTS.md;
  the startup test is the primary regression suite.
