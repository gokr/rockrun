# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
