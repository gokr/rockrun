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
  ## Camera smoothing rate for the exponentially damped follow.
  CameraLerpRate* = 7.0'f32
  ## Analog stick dead zone.
  Deadzone* = 0.28'f32
  ## Sound rate limits in seconds.
  ThudInterval* = 0.10'f32
  ClinkInterval* = 0.07'f32
  PushInterval* = 0.35'f32

type
  Phase* = enum
    phIntro
    phPlaying
    phPaused
    phDying
    phComplete
    phGameOver
    phAllComplete

  Game* = object
    phase*: Phase
    phaseTimer*: float32
    score*: int
    lives*: int
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
    deathReason*: string
    lastThud*: float32
    lastClink*: float32
    lastPush*: float32
    lastDig*: float32
    lastSink*: float32
    worldClockTime*: float32
    shake*: float32
    hudDirty*: bool
    levelCompleted*: bool ## set by a contact with an open exit

var gs*: Game

proc resetRun*() =
  ## Resets everything for a fresh run from the first level.
  gs.score = 0
  gs.levelIndex = 0
  gs.dirtDug = 0
  gs.deathReason = ""
  gs.shake = 0.0
  gs.levelCompleted = false
  gs.worldClockTime = 0.0

proc enterPhase*(phase: Phase) =
  ## Enters a phase and initializes its timer.
  gs.phase = phase
  case phase
  of phIntro: gs.phaseTimer = IntroTime
  of phDying: gs.phaseTimer = DyingTime
  of phComplete: gs.phaseTimer = CompleteTime
  else: gs.phaseTimer = 0.0
  gs.hudDirty = true

proc addScore*(points: int) =
  gs.score += points
  gs.hudDirty = true

proc gemsLeft*(): int =
  ## Diamonds still required before the exit opens.
  max(0, gs.needed - gs.collected)
