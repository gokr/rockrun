# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/gokr/rockrun/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gokr/rockrun/releases/tag/v0.1.0
