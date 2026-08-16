# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Cross-platform distribution scripts (adapted from Tankfeud): Linux
  AppImage (`makelinux.sh`), Windows zip via a Vagrant VM
  (`makewindows.sh` + `scripts/*.bat`), macOS app bundle + DMG
  (`makemac.sh`), and itch.io publishing (`publish.sh` via butler).
  `config.nims` is now platform-aware (Windows cross build links the
  bundled orx.dll explicitly).
- App icon generated into `assets/rockrun.png` and bundled into the
  Linux AppImage template.

## [1.1.0] - 2026-08-16

Local co-op multiplayer.

### Added

- Local co-op for 1-4 players: lobby join (movement keys or controller
  Start), per-player lives with respawn + invulnerability, shared diamond
  quota, group camera with zoom-out, `--startup-test-mp` scenario.

### Changed

- The single hero is now a `Player` record in `world.players` (physics
  object, spawn point, input set, animation state per player).
- Object destruction is deferred to end of frame (`flushDestroyed`) so
  newly created objects can never alias same-frame destroyed addresses;
  `destroyObject` validates ORX structure pointers and scrubs stale
  entries instead of crashing, the teardown pass is deduplicated, and
  fine sand grains are explicitly destroyed on level reload.
- Heroes collide with each other again; `Confirm` bound to KEY_ENTER (the
  ORX key name, KEY_RETURN was dead).
- HUD renders through a dedicated camera-space viewport (HudViewport) so
  text always draws on top; per-player lives lines replace the single
  LIVES counter; hero animation strips use one character consistently.
- Creatures pressed against sand are dazed: when the blocking sand is
  dug away they take a beat to wake up (no movement, no kills), so
  digging into a hidden firefly gives you a reaction window instead of
  an instant death - classic BD behavior.

### Changed

- Clearer death sequence: the viewport flashes red, a center message
  names the fallen player and cause ("P2 - CRUSHED BY A BOULDER") with
  their remaining lives, and the corpse blinks at ~10Hz until it
  respawns.
- Round-start countdown: after the cave intro, 3-2-1 beeps
  (synthesized WAVs) and a long final beep with GO! before play starts.
- Creature steering now matches the original Boulder Dash rule: go
  straight while the cell ahead is free, turn right (firefly, clockwise
  wall patrol) or left (butterfly) only when blocked. Previously the
  turn was preferred over straight, which made creatures zigzag across
  wide shafts and orbit in small squares in open halls instead of
  following the walls.
- Boulder crush is now momentum-based (mass x fall speed) instead of
  plain speed: a huge boulder crushes from a small drop, a pebble needs
  a long fall - size now matters for "brutal" rocks.
- Crush impact: signed approach momentum along the contact normal
  (normal re-oriented from the other body toward the boulder), so only
  a boulder genuinely moving toward you can crush - pushing or ramming
  from any side is always safe, even short head-drops kill, and
  creatures explode the same way (rolling boulders now pop them too).
- Boulder density 5 -> 12: the normal boulder outweighs the player
  (~1.9x), so pebbles stay pushable but medium rocks can't be lifted
  and big/huge ones are effectively immovable.
- Digging no longer awards score (diamonds and time bonus only).
- Respawn picks the nearest free cell: respawning on top of a teammate
  made the sprites overlap, which looked like the wrong player color.
- Players 2-4 now use their own colored sprite strips (green/blue/brown
  palette variants cut from the Kenney sheet) instead of a Color tint -
  each hero is visibly distinct without relying on ORX color
  multiplication.
- Countdown beats are all equal (0.5s); the first beat used to be 1.5s
  and the "3" text vanished mid-beat, leaving a blank pause.

## [1.0.0] - 2026-08-16

First stable release.

### Added

- Two new caves (Rumbling Depths 56x30, The Final Chamber 56x30) plus
  densified boulder fields in Rolling Fields and Deep Vault; First
  Descent stays a simple tutorial. Five caves in total.
- New huge boulder size ('R', ~54px) that crushes harder and can jam
  tunnels; generator and parser support it.
- Loose sand: refined 8px grains are static by default, and a resting
  boulder now slowly beds into loose sand, eating the grain it rests on
  (dust + creak) - simulated, always on.
- `--sand` opt-in: boulder-pressed grains turn dynamic and give way in a
  wedge below plus the column above the contact, capped at 300 loose
  grains so collapse cascades stay bounded.
- Fullscreen toggle (F key).

### Changed

- Creature steering hardened: smaller physics body (11px), blocked-target
  re-steering and a stuck timer; the startup test asserts cave-2
  creatures travel >200px so steering stalls fail CI.
- Fine-sand bookkeeping reworked into a flat grain list with per-cell
  counts (no stale pointers); destruction guards against same-frame
  double frees.
- Press Start 2P font replaced with Bungee (SIL OFL), rasterized at 64px
  for thick strokes; HUD renders through its own viewport so text always
  sits on top of the world.
- HUD text scales, positions and colors tuned for readability.

### Fixed

- Wall objects leaked across level reloads (the "second brick rectangle"
  in cave 2, which also physically blocked the hall).
- Boulders scale jitter removed so adjacent rocks touch.
- Typefaces load through the Font resource group - the custom font had
  never actually loaded before.
- Dig dust bursts halved and the dig swing animation plays every other
  dig with a visible pickaxe.
- Creature explosion no longer leaves dangling tracking records.

## [0.3.2] - 2026-08-16

HUD rendering fix, finer sand and tighter hero.

### Fixed

- HUD now lives in the main viewport via `ParentCamera` objects; the
  second HUD viewport is gone. It caused the world to render twice
  (offset copy of the cave border visible in scrolling caves).
- Hero animation pivot: `Pivot = center` on the animation set keeps the
  sprite aligned with the physics body.
- Dig envelope tightened (30x34px) so tunnels match the figure size
  instead of digging a much wider/higher path than the player.

### Changed

- Fine sand is now 4x4 (8px blocks) with a pebble-richer texture; coarse
  blocks use Repeat (4,4) to stay seamless.
- Dig animation loops while digging and includes a procedurally drawn
  pickaxe swing (wound-up, overhead, swung-down).
- Fireflies/butterflies enlarged (scale 0.34, ~22px).
- Cave 2 start area: wide carved corridor into the left shaft and
  two-row-tall entrances into the central hall.

## [0.3.1] - 2026-08-16

Animation wiring, tunnel routing and text size fixes.

### Fixed

- Player animation actually plays: ORX attaches animations through the
  `AnimationSet` object property and an `AnimationList` of animation
  sections, not an `AnimSet` property. Each animation (Idle/Run/Dig) is
  now its own 24px strip with a Dig->Idle link.
- Player visual size: 24px animation frames are rendered at object scale
  1.25 (~30px hero); the physics box was re-derived to stay 26px.
- Cave 2 now has a clearly visible tunnel from the start pocket through
  the left shaft into the central hall.

### Changed

- HUD text enlarged (~40px glyphs) with re-tuned positions and a shorter
  hint line that fits 1280px.

## [0.3.0] - 2026-08-16

Creatures, readable retro font and an animated hero.

### Added

- Fireflies and butterflies: classic wall huggers that move smoothly
  between cell centers with deterministic turn decisions (firefly keeps
  the wall left, butterfly right), kill the player on touch, and burst
  into nine diamonds when crushed by a fast-falling boulder.
- Procedural firefly/butterfly sprites in `tools/genassets.py`.
- Press Start 2P pixel font (SIL OFL) for the whole HUD; much more
  readable than the built-in font at the same size.
- Animated adventurer hero (Kenney Pixel Platformer, CC0): 13-frame
  strip with idle/run/dig cycles, switched by `movement.updatePlayer`.

### Changed

- Fine sand now splits into 3x3 blocks (10.7px) instead of 2x2 for a
  finer dig feel; seamless swap kept via `Repeat = (3, 3)` on the coarse
  block texture.
- Boulder scale jitter removed so adjacent rocks physically touch.
- Cave 2 redesign: tunnels into the central hall for clearer routing.
- Dig scanning is windowed around the player with cached static cell
  centers (per-frame ORX calls no longer scale with the whole cave).

### Fixed

- Creature steering uses a static occupancy map (walls + live sand)
  instead of physics queries.

## [0.2.0] - 2026-08-15

Bigger window, finer sand, three rock sizes and custom graphics.

### Added

- Two-tier sand subdivision: 32px sand blocks start coarse with a seamless
  2x2-tiled texture and silently split into four 16px blocks near the
  player. Cuts physics body count by ~4x versus a fully fine cave while
  digging stays granular.
- Boulders in three sizes (BoulderSmall/Boulder/BoulderBig, marked
  o/O/Q in level data) with auto-sized physics spheres matching visuals.
- Procedural textures via `tools/genassets.py` (CC0): rocky boulders in
  three seeds, faceted teal diamond, organic 16px-friendly sand.

### Changed

- Window now 1280x720 with proportionally larger HUD text and messages.
- Physics parts sized to match their graphics (boulder = auto sphere of
  object's size, player box 26px, gem solid 27px + 30px collection sensor).
- Player scale 0.5 with a 26px physics box; physics-design note retained:
  dynamic bodies stay slightly smaller than the 32px cell.

### Fixed

- Sand refinement could leave a stale sub-block pointer after contact
  destruction; now unlinked centrally in `destroySmallSand`.
- Contact-kind matching is prefix-based so Sand32/Sand16/BoulderSmall/
  BoulderBig classify correctly.

## [0.1.0] - 2026-08-15

First working release.

### Added

- Physics-first Boulderdash-like core on Norx/ORX: player, boulders, gems,
  dirt, walls and exit are all Box2D bodies. Digging removes solid dirt
  blocks, boulders roll and fall with sphere dynamics, gems tumble, and a
  fast downward-moving boulder crushes the player.
- Anti-gravity player controller with full analog support: left stick and
  d-pad on SDL gamepads, WASD/arrows on keyboard.
- Three validated caves (40×22 up to 48×26) produced by a deterministic
  level generator (`tools/genlevels.py`) with seeds, structural checks and
  guaranteed start/exit placement.
- Contact-event-driven game rules: dig-on-contact, gem collection through
  non-solid sensor parts, exit completion, crush detection, and rate-limited
  land/clink/push audio feedback.
- Smooth camera follow with bounds clamping and death shake.
- Lives system (3/run), per-cave timers, time bonus on completion,
  score persistence across caves, retry flow and game-over/game-clear states.
- Pause that freezes the physics simulation via a zero dt clock modifier.
- Background music (Kevin MacLeod's "8bit Dungeon Level", CC-BY 4.0),
  digging/land/clink/collect/push/win/lose sound effects (Kenney CC0).
- Grid-filling visuals: dirt/wall/boulder/gem/exit/player textures with
  subtle rotation, tint and scale jitter and loop-primed sparkle/glow FX.
- Dedicated screen-aligned HUD viewport (score, gems, time, lives, cave
  name), guaranteed drawn above the cave via creation order and Z separation.
- `H`/LThumb screenshots via orxScreenshot.
- Scripted in-engine startup test (`--startup-test`) covering config
  integrity (bindings incl. joystick, objects, sounds, music, levels),
  a boulder gravity drop, scripted digging/collection run, camera bounds,
  and a teleported exit-completion into the second cave, including PNG
  capture for visual review.
- Debug build linked against liborxd, release task linked against liborx.

[Unreleased]: https://github.com/gokr/rockrun/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/gokr/rockrun/releases/tag/v1.1.0
[1.0.0]: https://github.com/gokr/rockrun/releases/tag/v1.0.0
