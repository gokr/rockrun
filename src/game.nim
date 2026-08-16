## Central game state for Rockrun: phases, score, lives, timers.
##
## The module deliberately knows nothing about ORX objects; world.nim owns
## scene objects and contacts.nim owns physics events.

const
  ## World units are screen pixels; one cell of level data is one block.
  CellSize* = 32'f32
  ## Player linear speed in units/second.
  PlayerSpeed* = 235'f32
  ## Impact speeds for environmental feedback.
  ThudMinSpeed* = 330'f32
  ClinkMinSpeed* = 230'f32
  ## A boulder moving downwards faster than this crushes the player.
  CrushYSpeed* = 240'f32
  ## Phase durations in seconds.
  IntroTime* = 1.7'f32
  DyingTime* = 1.6'f32
  CompleteTime* = 2.2'f32
  ## Respawn invulnerability window in seconds.
  InvulnTime* = 2.5'f32
  ## Red viewport flash duration after a death.
  DeathFlashTime* = 0.25'f32
  ## Round-start countdown: one beep per beat, then the long final one.
  CountdownBeat* = 0.5'f32
  ## Camera smoothing rate for the exponentially damped follow.
  CameraLerpRate* = 7.0'f32
  ## Slower damping for frustum zoom changes (calmer than the follow).
  CameraZoomLerpRate* = 3.5'f32
  ## Padding around the hero group the camera keeps on screen (px).
  CameraMargin* = 240.0'f32
  ## Maximum camera zoom-out factor (1.0 = base frustum).
  CameraMaxZoom* = 2.5'f32
  ## Analog stick dead zone.
  Deadzone* = 0.28'f32
  ## Sound rate limits in seconds.
  ThudInterval* = 0.10'f32
  ClinkInterval* = 0.07'f32
  PushInterval* = 0.35'f32

type
  Phase* = enum
    phModeSelect
    phIntro
    phCountdown
    phPlaying
    phPaused
    phComplete
    phGameOver
    phAllComplete

  Game* = object
    phase*: Phase
    phaseTimer*: float32
    playerCount*: int
    maxPlayers*: int
    score*: int
    livesStart*: int
    levelIndex*: int
    levelCount*: int
    diamondScore*: int
    digScore*: int
    timeBonusPerSecond*: int
    levelName*: string
    levelTimeLimit*: float32
    timeLeft*: float32
    needed*: int
    collected*: int
    gemTotal*: int
    exitOpen*: bool
    dirtDug*: int
    timeExpired*: bool ## clock hit zero; alive heroes die once
    runLives*: array[4, int] ## per-hero lives across the whole run
    runDown*: array[4, bool] ## per-hero out-of-lives state
    lastThud*: float32
    lastClink*: float32
    lastPush*: float32
    lastDig*: float32
    lastSink*: float32
    worldClockTime*: float32
    shake*: float32
    deathFlash*: float32 ## red viewport flash remaining after a death
    hudDirty*: bool
    levelCompleted*: bool ## set by a contact with an open exit

var gs*: Game

proc resetRun*() =
  ## Resets everything for a fresh run from the first level.
  gs.score = 0
  gs.levelIndex = 0
  gs.dirtDug = 0
  gs.shake = 0.0
  gs.levelCompleted = false
  gs.timeExpired = false
  gs.worldClockTime = 0.0
  for i in 0 ..< 4:
    gs.runLives[i] = gs.livesStart
    gs.runDown[i] = false

proc enterPhase*(phase: Phase) =
  ## Enters a phase and initializes its timer.
  gs.phase = phase
  case phase
  of phIntro: gs.phaseTimer = IntroTime
  of phCountdown: gs.phaseTimer = CountdownBeat * 3.0
  of phComplete: gs.phaseTimer = CompleteTime
  else: gs.phaseTimer = 0.0
  gs.hudDirty = true

proc addScore*(points: int) =
  gs.score += points
  gs.hudDirty = true

proc gemsLeft*(): int =
  ## Diamonds still required before the exit opens.
  max(0, gs.needed - gs.collected)
