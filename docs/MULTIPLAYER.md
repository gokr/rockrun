# Rockrun Multiplayer Plan

Goal: local multiplayer for 1–4 players on one machine (keyboard + up to
four SDL controllers), with two modes:

- **Coop** — everyone shares one cave, one diamond quota, one team score.
  The exit opens when the *team* quota is met; any player can finish the
  cave for the team.
- **Race** (working title "Diamond Rush") — each player has their own
  diamond quota; the first player to collect theirs *and* reach the exit
  wins the cave.

Scope: **local only**. Networking (authoritative sim, rollback/GGPO) is a
separate project and explicitly out of scope for this branch.

---

## 1. Design decisions

### 1.1 Shared world, shared screen — not split-screen

Caves are small (up to 48×26 cells ≈ 1536×832 px against a 1280×720
viewport), and classic BD multiplayer is shared-screen. A single camera
that frames all alive players — centroid follow plus zoom-out via
`orxCamera_SetFrustum` (already exposed by the norx wrapper) — is cheap,
keeps the HUD in one place, and avoids rendering the world 2–4×.

Split-screen stays a documented stretch goal if framing gets cramped.

### 1.2 Per-player input via distinct action names

norx's input getters (`orxInput_IsActive`/`GetValue`) take only an action
name, no player ID. So each player gets its own action set in the ORX
input section:

```
MoveLeftP1 / MoveRightP1 / MoveUpP1 / MoveDownP1 / MoveXAxisP1 / MoveYAxisP1
MoveLeftP2 ... (arrows + JOY_*_2)
MoveLeftP3 ... (IJKL + JOY_*_3)
MoveLeftP4 ... (numpad 4/6/8/5 + JOY_*_4)
```

ORX supports joystick IDs 1–4 (`JOYSTICK_BUTTON_A_1`…`_4` in the wrapper
enum), so controllers map 1:1 to players. Pause/Restart/Quit stay global
(any player can pause).

Keyboard layout (defaults, config-driven): P1 = WASD, P2 = arrows,
P3 = IJKL, P4 = numpad (4/6/8/5). `checkInputBindings` in the startup
test is extended to verify all four sets.

### 1.3 Players do not collide with each other

`PlayerPart CheckMask` drops the `0x0001` player flag (`0xFFFE`), so two
dynamic bodies never wedge each other in a one-cell tunnel. Pushing
players around is fun but not worth the wedging risk; revisit later.

### 1.4 Death no longer reloads the cave

Today dying reloads the whole level — punishing for everyone in MP.
New rule (also an SP improvement):

- Each player has their own lives (per run, as today).
- Dying: lose a life, respawn at the player's spawn cell with a short
  invulnerability window (e.g. 2s, blink via FX), world stays intact.
- 0 lives = out of the run (spectate; in coop they watch the team).
- Cave/run restart only when *all* players are out of lives.

### 1.5 Coop rules

- Shared quota (`gs.needed`), shared `gs.collected`, shared score.
- Exit opens at team quota (existing `openExit` flow).
- Any player touching the open exit completes the cave.

### 1.6 Race rules

- Each player has their own quota: `RaceQuotaPercent` of the level quota
  (config, default e.g. 60%, min 1 diamond) so N players don't strip the
  cave bare. `genlevels.py` must guarantee enough diamonds for 4 players.
- Exit opens (visually) when the *first* player hits their quota.
- Touching the exit only lets a player through if they met *their* quota;
  otherwise the existing "Need N more diamonds" message shows their own
  remaining count.
- First quota-holder through the exit wins: cave ends, standings
  (diamonds collected, score) shown, next cave loads (or all-caves
  cleared screen).

### 1.7 Scores and lives

- Coop: one team score (`gs.score`), per-player lives.
- Race: per-player score (diamonds × DiamondScore + time bonus for the
  winner), per-player lives.

---

## 2. Architecture changes

Current coupling that has to break (verified by reading the code):

| Today | Problem for MP |
|---|---|
| `world.player: ptr orxOBJECT` single global | only one body, one spawn |
| `gs.collected/needed/score/lives/deathReason` global | no per-player bookkeeping |
| movement.nim global anim/dig state | per-player state needed |
| contacts.nim single `kPlayer` kind | no attribution of dig/collect/crush/exit |
| `phDying` → `reloadLevel()` | reload kills everyone's progress |
| camera follows `world.player` | must frame N players |
| level symbol `@` = exactly one spawn | need 1–4 spawns |
| ui.nim single HUD set | per-player HUD |

### 2.1 New `Player` record — world.nim

```nim
Player* = object
  obj*: ptr orxOBJECT
  index*: int              # 0..3
  inputSet*: string        # "P1".."P4" action prefix
  spawnX*, spawnY*: int
  lives*: int
  score*: int              # race mode
  collected*: int          # race mode
  needed*: int             # race mode
  deathReason*: string
  respawnTimer*: float32
  invulnTimer*: float32
  currentAnim*: string     # moved out of movement.nim globals
  digAnimTimer*: float32
```

`world.players: seq[Player]` replaces `world.player`; add
`playerOf(obj): int` for contact attribution and keep `players[0]` where
single-player semantics still apply (sounds tied to "the" player move to
the *attributed* player). The `Player` type lives in world.nim (it owns
ORX objects; game.nim stays ORX-free by design).

### 2.2 game.nim

- `GameMode* = enum gmSingle, gmCoop, gmRace` and `playerCount` on `gs`.
- New phase `phModeSelect` (title/lobby: pick mode, "press Start/A to
  join"), plus `phRoundOver` for race standings.
- Coop keeps the existing `collected/needed/score` fields as the team
  values; race uses per-player fields on `Player`.
- `lives`/`deathReason` become per-player; `gs.lives` stays as the coop
  "team" display alias if convenient.

### 2.3 world.nim

- Level symbols: `@` = P1, `2`/`3`/`4` = additional spawn points
  (spawn cells must be EMPTY, distinct, and not under a boulder).
- `buildWorld` spawns one `Player` object per spawn symbol (≤ 4); the
  old "exactly one player" validation becomes "1..4 spawns, one exit".
- `collectGem(gem, playerIndex)`: attribution for sound/flash/score and
  quota (coop: `gs.collected += 1`; race: `players[i].collected += 1`).
- `destroySmallSand`/dig sound attributed to the digging player.
- `clearWorld` destroys all player objects.
- `openExit` stays global; add `exitOpenFor(i)` for race gating.
- Spawn points get a no-boulder guarantee: `genlevels` validates nothing
  spawns above them (or spawn protection clears cells on respawn).

### 2.4 movement.nim

- `inputDirection(inputSet: string)` reads `MoveLeftP1`…`MoveDownP4` /
  `MoveXAxisP1`…, deadzone per call.
- `updatePlayer(player: var Player; deltaTime)`: velocity, digging
  (`digAround` already takes an origin — parameterize by player), anim
  state machine (state moved into `Player`).
- `movementOverride` becomes a per-player option (startup test).

### 2.5 contacts.nim

- `kindOf` keeps `kPlayer`; add `playerIndexOf(obj)` to resolve *which*
  player. All player pairs route through it:
  - `{kPlayer, kDirt}` → dig attributed to that player (dig sound).
  - `{kPlayer, kDiamond}` → `collectGem(gem, idx)`.
  - `{kPlayer, kExit}` → coop: complete cave; race: quota check + win
    or "Need N more".
  - `{kBoulder, kPlayer}` / `{kPlayer, kCreature}` → per-player death
    (reason on `players[idx]`, `enterPlayerDying(idx)`), no global phase
    change while other players live.
- `processContact` currently early-outs unless `gs.phase == phPlaying` —
  keep, but dying is now per-player.

### 2.6 rockrun.nim (phases, camera, test)

- `phDying` becomes per-player: `playerDying[i]` timers, respawn at spawn
  cell, invulnerability blink; cave reload only when all players dead
  (all out of lives → `phGameOver`; if some still have lives, the dead
  player's cave state persists — they respawn at the start with what the
  team has dug).
- Camera: follow the centroid of alive players, zoom (SetFrustum) to fit
  all of them with margin, clamp to world bounds, keep shake. Blended
  toward a target frustum width/height so zoom changes are smooth.
- `phModeSelect`: lobby screen before the run; P1 selects mode
  (keyboard), players join with Start/A (controller) or their key; then
  the run starts.
- Startup test: the SP scenario must stay green unchanged (P1 behaves
  exactly as today). Add a second scripted scenario behind its own flag
  (e.g. `--startup-test-mp`) covering: P2 spawn, per-player collect
  attribution, coop shared quota, race winner + standings + next cave.

### 2.7 ui.nim

- HUD becomes per-player: `HudScoreP1..P4`, `HudDiamondsP1..P4`,
  `HudLivesP1..P4` objects created in `initUi` (up to `MaxPlayers`),
  positioned along the top bar, tinted per player.
- Coop shows team quota/score on P1's line (or a shared line) plus each
  player's lives; race shows per-player quota and score.
- Center messages stay global (cave-wide events); per-player messages
  (death reason, "need N more") appear in that player's HUD strip.

### 2.8 data/config/rockrun.ini

- `[MainInput]`: add `MoveLeftP2`…`MoveDownP4`, `MoveXAxisP2..4`,
  `MoveYAxisP2..4` (keys + `JOY_*_2..4`).
- `[PlayerPart]`: `CheckMask = 0xFFFE` (no player-player collision).
- `[Player2]`…`[Player4]` object sections: same Graphic/Body/AnimationSet
  as `[Player]`, different `Color` tint (P1 default, P2 green, P3 blue,
  P4 yellow) — text and sprites both get per-player colors cheaply.
- HUD sections for players 2–4; `[Game]`: `MaxPlayers = 4`,
  `RaceQuotaPercent = 60`, race defaults.
- `[MainViewport]`/camera unchanged (single camera).

### 2.9 tools/genlevels.py

- New spawn symbols `2`,`3`,`4`; per-level `Players` count in the ini.
- Spawn placement: in the carved start area, on EMPTY cells, ≥2 cells
  apart, nothing above that can crush on spawn.
- Guarantee `gemCount >= Players * ceil(RaceQuotaPercent * needed)`.
- Deterministic seeded output preserved; levels regenerated with
  `python3 tools/genlevels.py` (AGENTS.md rule).
- `world.validateLevels` updated to match (1..4 spawns, one exit).

---

## 3. Implementation order

### Phase A — Foundation refactor (zero visible change, must stay green)
1. `Player` record + `world.players` + `playerOf`; `player` becomes
   `players[0]` alias during transition.
2. movement.nim parameterized by player (input prefix, anim state).
3. contacts.nim attribution plumbing; game.nim accessors.
4. Full startup test green; commit *"Refactor single player into Player
   records"*.

### Phase B — Multiplayer core (1–4 local players, coop)
1. Input bindings P1–P4 + `checkInputBindings` extension.
2. Level spawn symbols + `buildWorld` multi-spawn; genlevels.py update
   and regenerate; validation update.
3. Per-player death/respawn/invulnerability; all-out → game over.
4. Coop quota/exit/score; per-player HUD.
5. Camera framing (centroid + zoom clamp).
6. `phModeSelect` lobby (mode + join).
7. MP startup-test scenario (coop); commit.

### Phase C — Race mode
1. Per-player quota, exit gating, winner detection, `phRoundOver`
   standings, per-player score/time bonus.
2. Race HUD layout; winner/loser sounds.
3. genlevels diamond-density guarantee for N players.
4. Race startup-test scenario; commit.

### Phase D — Polish (stretch)
- Off-screen player arrows / name tags; spawn protection particles;
  per-player controller rumble; camera framing tuning.
- Optional: split-screen mode toggle.
- Out of scope: networking.

---

## 4. Test plan

- Existing SP startup test stays green after every phase (primary
  regression suite, per AGENTS.md).
- New `--startup-test-mp` scenario:
  - P2 spawns and moves; P1/P2 dig different tunnels simultaneously;
  - gem pickup attributes to the touching player;
  - coop: team quota opens exit, any player can finish;
  - race: P2 hits quota first and exits → winner is P2, standings show,
    cave 2 loads;
  - both players dead → game over path.
- Manual: keyboard P1 + one controller P2 simultaneously; two
  controllers; 4 players on keyboard; race with 4 players.
- `nimble test` + `python3 tools/genlevels.py` after generator changes.

## 5. Risks / notes

- **Camera zoom** can make the cave feel small at 4 players; cap zoom-out
  and prefer framing the group (BD-style bunched play) over showing
  everything. Split-screen remains the fallback.
- **Level fairness in race**: spawn order advantage — place spawns
  roughly equidistant from the exit/diamond fields; the generator's
  seeded layouts may need a fairness pass.
- **Per-player sounds**: ORX sound is positional; keep using the
  attributed player's object for dig/collect sounds (already the pattern).
- **HUD width**: 4 players × (score, quota, lives) needs a compact
  second row; keep P1's row layout and shrink per-player cells.
- **Performance**: more dynamic bodies (≤ 3 extra players, ~26px boxes)
  is negligible for Box2D; no physics subdivision changes needed.
- Preserve AGENTS.md conventions: config-driven settings in the ini,
  startup test as the regression suite, `nimble test` after changes.
