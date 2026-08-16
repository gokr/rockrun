## Rockrun - a physics-based Boulder Dash successor built with Norx.
##
## Boulders, gems, dirt, walls and the player are all Box2D bodies driven
## by the ORX physics plugin. Digging, collecting, crushing, pushing and
## falling all emerge from the simulation; the game logic only listens to
## contact events and nudges the player.
##
## Controls (keyboard and any SDL-recognized game controller):
##   Move      - WASD / arrow keys / d-pad / left stick
##   Pause     - Space / Start
##   Retry     - R / Y
##   Quit      - Esc / Back
import os
import math
import strformat
import strutils
import options

import norx
import game
import world
import contacts
import creatures
import movement
import ui
import screenshots

const
  StartupTestFrameCount = 5

type
  TestActionKind* = enum
    taMove
    taSpawnBoulder
    taSpawnGem
    taSpawnCreature
    taExplodeCreature
    taFakeQuota
    taTeleport
    taScreenshot
    taFinish

  TestAction* = object
    ## One scripted scenario step, executed when test.time reaches `at`.
    at*: float32
    kind*: TestActionKind
    dx*, dy*: float32
    duration*: float32
    cx*, cy*: int
    config*: string

  TestScript = object
    ## Scripted in-engine verification used with --startup-test.
    active: bool
    time: float32
    boulder: ptr orxOBJECT
    boulderSpawnY: float32
    spawnedCreature: ptr orxOBJECT
    explodedGemCount: int
    collectedBeforeExit: int
    moveUntil: float32
    exitTeleported: bool
    completed: bool
    finished: bool
    failures: seq[string]

const
  ## The startup test scenario: gravity drop, scripted dig/collect run,
  ## creature explosion regression, exit completion into cave 2.
  Scenario: seq[TestAction] = @[
    TestAction(at: 1.0, kind: taSpawnBoulder, cx: 30, cy: 2),
    TestAction(at: 1.2, kind: taMove, dx: 1.0, dy: 0.0, duration: 6.3),
    TestAction(at: 2.5, kind: taSpawnGem, cx: 14, cy: 2),
    TestAction(at: 3.0, kind: taScreenshot),
    TestAction(at: 6.5, kind: taSpawnCreature, config: "Firefly",
               cx: 31, cy: 14),
    TestAction(at: 6.5, kind: taExplodeCreature),
    TestAction(at: 8.0, kind: taScreenshot),
    TestAction(at: 8.0, kind: taFakeQuota),
    TestAction(at: 8.0, kind: taTeleport, cx: 35, cy: 19),
    TestAction(at: 8.0, kind: taMove, dx: 1.0, dy: 0.0, duration: 4.0),
    TestAction(at: 14.0, kind: taFinish)
  ]

var
  scenarioIndex = 0

var
  mainViewport: ptr orxVIEWPORT
  mainCamera: ptr orxCAMERA
  cameraHalfW, cameraHalfH: float32
  coreClock: ptr orxCLOCK
  audioObject: ptr orxOBJECT
  dyingHandled = false
  startupFrames: int
  initializationSucceeded = false
  executionFailed = false
  test: TestScript

proc testCheck(condition: bool; message: string) =
  if not condition:
    test.failures.add(message)
    echo "Rockrun test failed: ", message

proc runFinalChecks() =
  testCheck(test.boulder != nil, "startup boulder was not spawned")
  if test.boulder != nil:
    let fellBy = test.boulder.getWorldPosition().fY - test.boulderSpawnY
    testCheck(fellBy > 100.0,
      fmt"startup boulder fell only {fellBy:.1} units")
  testCheck(gs.dirtDug >= 6,
    fmt"player dug only {gs.dirtDug} sand blocks")
  testCheck(test.collectedBeforeExit >= 1,
    "player did not collect the corridor diamond")
  testCheck(gs.score >= gs.diamondScore,
    fmt"score too low for a diamond pickup: {gs.score}")
  testCheck(movement.animSawDig,
    "the dig swing animation never triggered while digging")
  testCheck(test.explodedGemCount == world.SubGrid * world.SubGrid,
    fmt"creature explosion spawned {test.explodedGemCount} gems")
  testCheck(test.completed,
    "player could not complete the cave through the exit")
  testCheck(gs.levelIndex == 1,
    fmt"the second cave did not load (levelIndex={gs.levelIndex})")
  testCheck(gs.phase in {phIntro, phPlaying},
    fmt"unexpected phase after completing cave: {gs.phase}")
  var cameraPosition: orxVECTOR
  discard getPosition(mainCamera, addr cameraPosition)
  testCheck(abs(cameraPosition.fX) <= worldMaxX and
            abs(cameraPosition.fY) <= worldMaxY,
    "camera left the cave bounds")
  # Cave 2 is loaded and its creatures spawned: capture them.
  discard screenshots.takeScreenshot()
  if test.failures.len == 0:
    echo "Rockrun engine checks passed"
    echo "Rockrun completion checks passed"

let startupTest = "--startup-test" in commandLineParams()

proc setEnginePaused(paused: bool) =
  ## Zeroes dt for the whole core clock: physics and logic freeze while
  ## rendering and input polling keep working.
  discard setModifier(coreClock, CLOCK_MODIFIER_MULTIPLY,
                      (if paused: 0.0 else: 1.0).orxFLOAT)

proc startDying() =
  ## Applies the one-time effects of losing a life.
  dyingHandled = true
  dec gs.lives
  gs.shake = 9.0
  let hero = world.playerObj()
  if hero != nil:
    discard hero.addSound("LoseSound")
    discard hero.addFX("HitFlash")
  ui.showMessage(gs.deathReason.toUpperAscii(), 1.4)
  ui.showSubMessage(&"LIVES {gs.lives}", 1.4)
  gs.hudDirty = true

proc showLevelIntro() =
  ui.showMessage(&"CAVE {gs.levelIndex + 1} - {gs.levelName}", IntroTime)
  ui.showSubMessage(&"Collect {gs.needed} diamonds", IntroTime)
  enterPhase(phIntro)

proc reloadLevel() =
  if world.loadWorld(gs.levelIndex):
    creatures.clearCreatures()
    creatures.spawnPending()
    dyingHandled = false
    gs.shake = 0.0
    showLevelIntro()

proc restartRun() =
  resetRun()
  gs.lives = gs.livesStart
  reloadLevel()

proc completeLevel() =
  let bonus = int(gs.timeLeft) * gs.timeBonusPerSecond
  addScore(bonus)
  let hero = world.playerObj()
  if hero != nil:
    discard hero.addSound("WinSound")
  ui.showMessage("CAVE CLEARED!", CompleteTime)
  ui.showSubMessage(&"TIME BONUS +{bonus}", CompleteTime)
  enterPhase(phComplete)

proc updateCamera(deltaTime: float32) =
  let hero = world.playerObj()
  if hero == nil or mainCamera == nil:
    return
  let target = hero.getWorldPosition()
  var cameraPosition: orxVECTOR
  discard getPosition(mainCamera, addr cameraPosition)

  let
    halfFreeX = max(0.0'f32, worldMaxX - cameraHalfW)
    halfFreeY = max(0.0'f32, worldMaxY - cameraHalfH)
    targetX = clamp(target.fX, -halfFreeX, halfFreeX)
    targetY = clamp(target.fY, -halfFreeY, halfFreeY)
    alpha = 1.0'f32 - exp(-CameraLerpRate * deltaTime)

  cameraPosition.fX += (targetX - cameraPosition.fX) * alpha
  cameraPosition.fY += (targetY - cameraPosition.fY) * alpha

  if gs.shake > 0.0:
    gs.shake = max(0.0'f32, gs.shake - deltaTime * 22.0'f32)
    let
      shakeX = gs.shake * (getRandomU32(0, 1000).float32 / 500.0'f32 - 1.0)
      shakeY = gs.shake * (getRandomU32(0, 1000).float32 / 500.0'f32 - 1.0)
    cameraPosition.fX += shakeX
    cameraPosition.fY += shakeY

  discard setPosition(mainCamera, addr cameraPosition)

const
  ## dt multiplier used only for the scripted test, to compensate for the
  ## clock clamp (~1/240s) making sim time much slower than wall time.
  TestClockMultiplier = (if defined(testSlow): 1.0 else: 3.0).float32

proc runTestScript(deltaTime: float32) =
  ## Executes the scripted scenario: an ordered action table whose steps
  ## fire when test.time reaches their timestamps.
  when defined(debugHeartbeat):
    let previousSecond = int(test.time)
    test.time += deltaTime
    if int(test.time) > previousSecond and test.time < 12.0 and
        world.playerObj() != nil:
      let hero = world.playerObj()
      let playerPosition = hero.getWorldPosition()
      let playerSpeed = hero.getSpeed()
      let (inputX, inputY) = movement.inputDirection(world.players[0])
      echo "TEST t=", test.time.int, " phase=", gs.phase,
           " pos=(", playerPosition.fX, ",", playerPosition.fY, ") v=(",
           playerSpeed.fX, ",", playerSpeed.fY, ") in=(",
           inputX, ",", inputY, ") dirts=", world.dirts.len
  else:
    test.time += deltaTime

  if scenarioIndex == 0:
    ## Triple sim speed while verifying; restored on completion.
    setEnginePaused(false)
    discard setModifier(coreClock, CLOCK_MODIFIER_MULTIPLY,
                        TestClockMultiplier)

  when defined(testNoScript):
    return

  ## Due actions
  while scenarioIndex < Scenario.len and
      test.time >= Scenario[scenarioIndex].at:
    let action = Scenario[scenarioIndex]
    inc scenarioIndex
    case action.kind
    of taMove:
      movement.movementOverride = some((action.dx, action.dy))
      test.moveUntil = test.time + action.duration
    of taSpawnBoulder:
      test.boulder = world.spawnBoulderAt(action.cx, action.cy)
      if test.boulder != nil:
        test.boulderSpawnY = test.boulder.getWorldPosition().fY
    of taSpawnGem:
      ## Drops a diamond right in front of the player, inside the corridor
      ## that has already been dug (spawning inside solid sand would eject
      ## the gem violently).
      let gem = objectCreateFromConfig("Diamond")
      if gem != nil:
        let playerPosition = world.playerObj().getWorldPosition()
        let (px, py) = world.cellOf(playerPosition)
        let position = world.cellWorld(px + 1, py)
        discard gem.setPosition(
          newVector(position.fX, position.fY, world.GemZ))
        discard gem.addFX("SparkleFX")
        world.gems.add(gem)
        when defined(debugContacts):
          echo "SPAWNED test gem at ", position.fX, ",", position.fY,
               " player at ", playerPosition.fX, ",", playerPosition.fY
    of taSpawnCreature:
      test.spawnedCreature = creatures.spawnCreature(
        action.config, action.cx, action.cy,
        (if action.config == "Firefly": ckFirefly else: ckButterfly))
    of taExplodeCreature:
      ## Regression: exploding a creature must leave no dangling record
      ## (a falling boulder once crashed updateCreatures this way).
      let gemCount = world.gems.len
      creatures.explodeCreature(test.spawnedCreature)
      test.explodedGemCount = world.gems.len - gemCount
      testCheck(creatures.creatures.len == 0,
        "creature record still tracked after explosion")
    of taFakeQuota:
      ## Capture the collected-gem count before the level resets: the
      ## final checks run after cave 2 has loaded.
      test.collectedBeforeExit = gs.collected
      gs.collected = gs.needed
    of taTeleport:
      test.exitTeleported = true
      discard world.playerObj().setWorldPosition(
        world.cellWorld(action.cx, action.cy))
    of taScreenshot:
      discard screenshots.takeScreenshot()
    of taFinish:
      runFinalChecks()
      test.finished = true
      setEnginePaused(false)
      discard eventSendShort(EVENT_TYPE_SYSTEM, SYSTEM_EVENT_CLOSE.orxU32)

  ## Movement override lifetime
  if movement.movementOverride.isSome and test.time >= test.moveUntil and
      not test.completed:
    movement.movementOverride = options.none(tuple[x, y: float32])

  ## Completion detection while walking into the exit
  if test.exitTeleported and not test.completed and
      (gs.levelCompleted or gs.phase == phComplete):
    test.completed = true
    movement.movementOverride = options.none(tuple[x, y: float32])

proc updateGame(clockInfo: ptr orxCLOCK_INFO; context: pointer) {.cdecl.} =
  if isActive("Quit"):
    setEnginePaused(false)
    discard eventSendShort(EVENT_TYPE_SYSTEM, SYSTEM_EVENT_CLOSE.orxU32)
    return

  let deltaTime = clockInfo.fDT.float32

  if hasBeenActivated("Pause") and
      gs.phase in {phPlaying, phPaused}:
    if gs.phase == phPlaying:
      setEnginePaused(true)
      enterPhase(phPaused)
      ui.showMessage("PAUSED", 0.0)
      ui.showSubMessage("Space / Start to resume", 0.0)
    else:
      setEnginePaused(false)
      enterPhase(phPlaying)
      ui.hideMessages()

  if hasBeenActivated("Restart"):
    if gs.phase in {phGameOver, phAllComplete}:
      restartRun()
    elif gs.phase in {phPlaying, phPaused}:
      setEnginePaused(false)
      reloadLevel()

  if hasBeenActivated("TakeScreenshot"):
    discard screenshots.takeScreenshot()

  world.clearDestroyed()
  contacts.processContacts()

  case gs.phase
  of phIntro:
    gs.phaseTimer -= deltaTime
    if gs.phaseTimer <= 0.0:
      enterPhase(phPlaying)
  of phPlaying:
    gs.timeLeft = max(0.0'f32, gs.timeLeft - deltaTime)
    if gs.timeLeft <= 0.0:
      gs.deathReason = "Out of time"
      enterPhase(phDying)
    for hero in world.players.mitems:
      movement.updatePlayer(hero, deltaTime)
    creatures.updateCreatures(deltaTime)
    if not gs.exitOpen and gs.collected >= gs.needed:
      world.openExit()
      ui.showSubMessage("EXIT OPEN!", 2.0)
  of phDying:
    if not dyingHandled:
      startDying()
    gs.phaseTimer -= deltaTime
    if gs.phaseTimer <= 0.0:
      if gs.lives > 0:
        reloadLevel()
      else:
        ui.showMessage("GAME OVER", 0.0)
        ui.showSubMessage(&"Final score: {gs.score} - press R / Y to retry", 0.0)
        enterPhase(phGameOver)
  of phComplete:
    gs.phaseTimer -= deltaTime
    if gs.phaseTimer <= 0.0:
      if gs.levelIndex + 1 >= gs.levelCount:
        ui.showMessage("ALL CAVES CLEARED!", 0.0)
        ui.showSubMessage(
          &"Final score: {gs.score} - press R / Y to play again", 0.0)
        enterPhase(phAllComplete)
      else:
        inc gs.levelIndex
        reloadLevel()
  else:
    discard

  if gs.phase == phPlaying and gs.levelCompleted:
    completeLevel()

  gs.worldClockTime += deltaTime
  updateCamera(deltaTime)
  ui.updateUi(deltaTime)
  when defined(debugHeartbeat):
    inc startupFrames
    if startupFrames mod 120 == 0:
      echo "HEARTBEAT frame=", startupFrames, " time=", gs.worldClockTime,
           " phase=", gs.phase

  if test.active:
    runTestScript(deltaTime)

proc checkInputBindings(): bool =
  ## Verifies both keyboard and controller bindings from config.
  type Expected = tuple[action: string; expectedType: orxINPUT_TYPE;
                        expectedId: orxENUM]
  const expectations = [
    (action: "Quit", expectedType: INPUT_TYPE_KEYBOARD_KEY,
     expectedId: ord(KEYBOARD_KEY_ESCAPE).orxENUM),
    (action: "Quit", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_BACK_1).orxENUM),
    (action: "Pause", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_START_1).orxENUM),
    (action: "Restart", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_Y_1).orxENUM),
    (action: "MoveLeft", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_LEFT_1).orxENUM),
    (action: "MoveXAxis", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LX_1).orxENUM),
    (action: "MoveYAxis", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LY_1).orxENUM)
  ]
  for expectation in expectations:
    var
      inputType: orxINPUT_TYPE
      inputId: orxENUM
      inputMode: orxINPUT_MODE
      found = false
    for slot in 0 ..< 4:
      if getBinding(expectation.action, slot.orxU32, addr inputType,
                    addr inputId, addr inputMode).isFailure:
        break
      if inputType == expectation.expectedType and
          inputId == expectation.expectedId:
        found = true
        break
    if not found:
      echo "Startup check failed: binding for ", expectation.action,
           " does not include ", expectation.expectedType, " #",
           expectation.expectedId.int
      return false
  result = true

proc runConfigChecks(): bool =
  if not checkInputBindings():
    return false

  for section in ["Player", "BoulderSmall", "Boulder", "BoulderBig",
                  "Diamond", "Sand32", "SandFine", "Wall", "Exit",
                  "DustPuff", "GemSparkle", "AudioSource"]:
    let testObject = objectCreateFromConfig(section)
    if testObject == nil:
      echo "Startup check failed: could not create object ", section
      return false
    if section notin ["DustPuff", "GemSparkle", "AudioSource"] and
        testObject.getWorkingGraphic() == nil:
      echo "Startup check failed: object ", section, " lacks a graphic"
      discard objectDelete(testObject)
      return false
    discard objectDelete(testObject)

  when not defined(testNoSoundCheck):
    for section in ["DigSound", "PushSound", "LandSound", "ClinkSound",
                    "CollectSound", "WinSound", "LoseSound", "ExitOpenSound",
                    "GameMusic"]:
      let sound = soundCreateFromConfig(section)
      if sound == nil:
        echo "Startup check failed: sound ", section
        return false
      discard soundDelete(sound)

  if not world.validateLevels():
    return false

  echo "Rockrun config checks passed"
  result = true

proc init(): orxSTATUS {.cdecl.} =
  echo "Rockrun starting with ORX ", getVersionFullString()

  if pushSection("Game").isSuccess:
    gs.levelCount = getS32("LevelCount").int
    gs.livesStart = getS32("Lives").int
    gs.diamondScore = getS32("DiamondScore").int
    gs.digScore = getS32("DigScore").int
    gs.timeBonusPerSecond = getS32("TimeBonusPerSecond").int
    discard popSection()

  mainViewport = viewportCreateFromConfig("MainViewport")
  if mainViewport == nil:
    echo "Could not create the viewports"
    return STATUS_FAILURE
  mainCamera = getCamera(mainViewport)
  if mainCamera == nil:
    echo "Could not fetch the main camera"
    return STATUS_FAILURE
  if pushSection("MainCamera").isSuccess:
    cameraHalfW = getFloat("FrustumWidth") * 0.5'f32
    cameraHalfH = getFloat("FrustumHeight") * 0.5'f32
    discard popSection()
  if cameraHalfW == 0.0:
    cameraHalfW = 640.0
    cameraHalfH = 360.0

  if not ui.initUi():
    return STATUS_FAILURE
  when defined(debugHud):
    discard objectCreateFromConfig("DebugSquare")

  audioObject = objectCreateFromConfig("AudioSource")
  if audioObject == nil:
    echo "Could not create the audio source"
    return STATUS_FAILURE
  if audioObject.addSound("GameMusic").isFailure:
    echo "Could not start the background music"
    return STATUS_FAILURE

  resetRun()
  gs.lives = gs.livesStart
  if not world.loadWorld(0):
    echo "Could not load the first level"
    return STATUS_FAILURE
  creatures.spawnPending()
  showLevelIntro()

  if registerContactHandler().isFailure:
    echo "Could not register the physics handler"
    return STATUS_FAILURE

  if startupTest:
    test = TestScript(active: true)
    if not runConfigChecks():
      return STATUS_FAILURE

  coreClock = clockGet(CLOCK_KZ_CORE)
  if coreClock == nil:
    return STATUS_FAILURE
  result = clockRegister(coreClock, updateGame, nil, MODULE_ID_MAIN,
                         CLOCK_PRIORITY_NORMAL)
  initializationSucceeded = result.isSuccess

proc run(): orxSTATUS {.cdecl.} =
  if startupTest:
    inc startupFrames
    if startupFrames >= StartupTestFrameCount and not test.active:
      return STATUS_FAILURE
  result = STATUS_SUCCESS

proc exit() {.cdecl.} =
  if coreClock != nil:
    discard unregister(coreClock, updateGame, nil)
  discard unregisterContactHandler()
  echo "Rockrun stopped"

proc bootstrap(): orxSTATUS {.cdecl.} =
  ## Finds the data directory next to the executable, in the working
  ## directory, or in the source tree, and registers all storages.
  for basePath in [
    getAppDir() / "data",
    getCurrentDir() / "data",
    currentSourcePath().parentDir().parentDir() / "data"
  ]:
    if not fileExists(basePath / "config" / "rockrun.ini"):
      continue
    result = addStorage(CONFIG_KZ_RESOURCE_GROUP, basePath / "config", false)
    if result.isFailure:
      return
    discard addStorage(TEXTURE_KZ_RESOURCE_GROUP, basePath / "texture", false)
    discard addStorage(TEXTURE_KZ_RESOURCE_GROUP, basePath / "font", false)
    discard addStorage(SOUND_KZ_RESOURCE_GROUP, basePath / "sound", false)
    discard addStorage(SOUND_KZ_RESOURCE_GROUP, basePath / "music", false)
    return
  echo "Could not find Rockrun data directory"
  result = STATUS_FAILURE

when isMainModule:
  if setBootstrap(bootstrap).isFailure:
    quit("Could not register the bootstrap callback")
  execute(init, run, exit)
  if not initializationSucceeded or executionFailed or
      (startupTest and test.failures.len > 0):
    quit(1)
  if startupTest and test.boulder == nil:
    quit(1)
