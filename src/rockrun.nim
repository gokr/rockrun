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
import sequtils
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
    taBoulderFell
    taSpawnGem
    taSpawnCreature
    taExplodeCreature
    taFakeQuota
    taTeleport
    taKillPlayer
    taCheckRespawn
    taCaptureCollected
    taScreenshot
    taFinish

  TestAction* = object
    ## One scripted scenario step, executed when test.time reaches `at`.
    at*: float32
    kind*: TestActionKind
    player*: int ## player index for per-player actions (default 0)
    dx*, dy*: float32
    duration*: float32
    cx*, cy*: int
    config*: string

  TestScript = object
    ## Scripted in-engine verification used with --startup-test.
    active: bool
    mp: bool ## multiplayer variant (--startup-test-mp)
    time: float32
    boulder: ptr orxOBJECT
    boulderSpawnY: float32
    boulderFellBy: float32 ## captured while the boulder is still alive
    spawnedCreature: ptr orxOBJECT
    explodedGemCount: int
    collectedBeforeExit: int
    creatureSpawns: seq[orxVECTOR]
    moveUntil: array[4, float32]
    respawned: array[4, bool]
    collectedMid: int
    creaturePath: seq[float32]
    creatureLastPos: seq[orxVECTOR]
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
    TestAction(at: 3.0, kind: taBoulderFell),
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

const
  ## Multiplayer variant (--startup-test-mp): two heroes dig, P2 dies and
  ## respawns, P1 completes the cave (coop finish).
  ScenarioMp: seq[TestAction] = @[
    TestAction(at: 1.0, kind: taMove, player: 0, dx: 1.0, dy: 0.0,
               duration: 3.0),
    TestAction(at: 1.0, kind: taMove, player: 1, dx: 1.0, dy: 0.0,
               duration: 3.0),
    TestAction(at: 1.2, kind: taSpawnGem, player: 1),
    TestAction(at: 3.0, kind: taCaptureCollected),
    TestAction(at: 3.5, kind: taScreenshot),
    TestAction(at: 4.0, kind: taKillPlayer, player: 1),
    TestAction(at: 6.0, kind: taCheckRespawn, player: 1),
    TestAction(at: 6.0, kind: taScreenshot),
    TestAction(at: 6.5, kind: taFakeQuota),
    TestAction(at: 7.0, kind: taTeleport, player: 0, cx: 35, cy: 19),
    TestAction(at: 7.0, kind: taMove, player: 0, dx: 1.0, dy: 0.0,
               duration: 3.0),
    TestAction(at: 12.0, kind: taFinish)
  ]

var
  scenarioIndex = 0
  testScenario: seq[TestAction]

var
  mainViewport, hudViewport: ptr orxVIEWPORT
  mainCamera: ptr orxCAMERA
  cameraHalfW, cameraHalfH: float32
  cameraNear, cameraFar: float32
  coreClock: ptr orxCLOCK
  audioObject: ptr orxOBJECT
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
  testCheck(test.boulderFellBy > 100.0,
    fmt"startup boulder fell only {test.boulderFellBy:.1} units")
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
  var creaturesMoved = false
  for i, creature in creatures.creatures:
    if i < test.creatureSpawns.len and creature.obj != nil:
      let position = creature.obj.getWorldPosition()
      if hypot(position.fX - test.creatureSpawns[i].fX,
               position.fY - test.creatureSpawns[i].fY) > 10.0:
        creaturesMoved = true
  testCheck(creaturesMoved,
    "cave-2 creatures did not move (wall-hugging steering stuck?)")
  var creatureTravel = 0.0
  for length in test.creaturePath:
    creatureTravel += length
  testCheck(creatureTravel > 200.0,
    fmt"cave-2 creatures barely moved ({creatureTravel:.0f}px total)")
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

proc runFinalChecksMp() =
  ## Final checks for the multiplayer variant.
  testCheck(world.players.len == 2,
    fmt"expected 2 players, got {world.players.len}")
  testCheck(gs.dirtDug >= 8,
    fmt"both heroes dug only {gs.dirtDug} sand blocks")
  testCheck(test.collectedMid >= 1,
    "P2 never collected a gem (attribution broken?)")
  testCheck(world.players[1].lives == 2,
    "P2 did not lose a life to the test kill")
  testCheck(not world.players[1].down, "P2 is down after one kill")
  testCheck(world.players[1].obj != nil, "P2 object missing after respawn")
  testCheck(test.respawned[1], "P2 did not respawn at the spawn cell")
  testCheck(test.completed,
    "P1 could not complete the cave through the exit")
  testCheck(gs.levelIndex == 1,
    fmt"the second cave did not load (levelIndex={gs.levelIndex})")
  if test.failures.len == 0:
    echo "Rockrun multiplayer checks passed"

let startupTest = "--startup-test" in commandLineParams()
let startupTestMp = "--startup-test-mp" in commandLineParams()

proc setEnginePaused(paused: bool) =
  ## Zeroes dt for the whole core clock: physics and logic freeze while
  ## rendering and input polling keep working.
  discard setModifier(coreClock, CLOCK_MODIFIER_MULTIPLY,
                      (if paused: 0.0 else: 1.0).orxFLOAT)

proc showLevelIntro() =
  ui.showMessage(&"CAVE {gs.levelIndex + 1} - {gs.levelName}", IntroTime)
  ui.showSubMessage(&"Collect {gs.needed} diamonds", IntroTime)
  enterPhase(phIntro)

proc reloadLevel() =
  if world.loadWorld(gs.levelIndex):
    creatures.clearCreatures()
    creatures.spawnPending()
    if test.active and gs.levelIndex == 1:
      # Record cave-2 creature positions so the test can verify they
      # actually move (wall-hugging steering).
      test.creatureSpawns.setLen(0)
      for creature in creatures.creatures:
        test.creatureSpawns.add(creature.obj.getWorldPosition())
    gs.shake = 0.0
    showLevelIntro()

var
  joinedPlayers: array[4, bool]

proc joinActivated(index: int): bool =
  ## A controller Start press or any movement input of that player
  ## counts as a join request in the lobby.
  if hasBeenActivated("JoinP" & $(index + 1)):
    return true
  for base in ["MoveLeft", "MoveRight", "MoveUp", "MoveDown"]:
    if hasBeenActivated(base & "P" & $(index + 1)):
      return true
  false

proc startRun() =
  ## Begins the run with the joined players (P1 always in).
  gs.playerCount = max(1, joinedPlayers.count(true))
  resetRun()
  if not world.loadWorld(0):
    return
  creatures.spawnPending()
  showLevelIntro()

proc restartRun() =
  startRun()

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
  if mainCamera == nil:
    return
  # Bounding box of all active heroes (down players don't count).
  var
    minX, maxX, minY, maxY: float32
    count = 0
  for hero in world.players:
    if hero.obj == nil or hero.down:
      continue
    let position = hero.obj.getWorldPosition()
    if count == 0:
      minX = position.fX
      maxX = position.fX
      minY = position.fY
      maxY = position.fY
    else:
      minX = min(minX, position.fX)
      maxX = max(maxX, position.fX)
      minY = min(minY, position.fY)
      maxY = max(maxY, position.fY)
    inc count
  if count == 0:
    return

  # Frustum zoom: zoom out (never in) so every hero fits with margin.
  let
    baseW = cameraHalfW * 2.0
    baseH = cameraHalfH * 2.0
    needW = maxX - minX + CameraMargin * 2.0
    needH = maxY - minY + CameraMargin * 2.0
    targetW = clamp(max(baseW, needW), baseW, baseW * CameraMaxZoom)
    targetH = clamp(max(baseH, needH), baseH, baseH * CameraMaxZoom)
    alpha = 1.0'f32 - exp(-CameraLerpRate * deltaTime)
  cameraHalfW += (targetW * 0.5 - cameraHalfW) * alpha
  cameraHalfH += (targetH * 0.5 - cameraHalfH) * alpha
  discard setFrustum(mainCamera, cameraHalfW * 2.0, cameraHalfH * 2.0,
                     cameraNear, cameraFar)

  let
    targetX = clamp((minX + maxX) * 0.5, -max(0.0'f32, worldMaxX - cameraHalfW),
                    max(0.0'f32, worldMaxX - cameraHalfW))
    targetY = clamp((minY + maxY) * 0.5, -max(0.0'f32, worldMaxY - cameraHalfH),
                    max(0.0'f32, worldMaxY - cameraHalfH))
  var cameraPosition: orxVECTOR
  discard getPosition(mainCamera, addr cameraPosition)
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
  while scenarioIndex < testScenario.len and
      test.time >= testScenario[scenarioIndex].at:
    let action = testScenario[scenarioIndex]
    inc scenarioIndex
    case action.kind
    of taMove:
      movement.movementOverride[action.player] = some((action.dx, action.dy))
      test.moveUntil[action.player] = test.time + action.duration
    of taSpawnBoulder:
      test.boulder = world.spawnBoulderAt(action.cx, action.cy)
      if test.boulder != nil:
        test.boulderSpawnY = test.boulder.getWorldPosition().fY
    of taBoulderFell:
      ## Captured while the boulder is still alive: reading the object
      ## after a level reload would dereference a stale pointer.
      if test.boulder != nil:
        test.boulderFellBy =
          test.boulder.getWorldPosition().fY - test.boulderSpawnY
    of taSpawnGem:
      ## Drops a diamond right in front of the player, inside the corridor
      ## that has already been dug (spawning inside solid sand would eject
      ## the gem violently).
      let gem = objectCreateFromConfig("Diamond")
      if gem != nil and action.player < world.players.len:
        let playerPosition = world.players[action.player].obj.getWorldPosition()
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
      if action.player < world.players.len:
        discard world.players[action.player].obj.setWorldPosition(
          world.cellWorld(action.cx, action.cy))
    of taKillPlayer:
      world.killPlayer(action.player, "Test crush")
    of taCheckRespawn:
      if action.player < world.players.len:
        let hero = world.players[action.player]
        if hero.obj != nil:
          let position = hero.obj.getWorldPosition()
          let spawnPosition = world.cellWorld(hero.spawnX, hero.spawnY)
          test.respawned[action.player] =
            hypot(position.fX - spawnPosition.fX,
                  position.fY - spawnPosition.fY) < 10.0
    of taCaptureCollected:
      test.collectedMid = gs.collected
    of taScreenshot:
      discard screenshots.takeScreenshot()
    of taFinish:
      if test.mp:
        runFinalChecksMp()
      else:
        runFinalChecks()
      test.finished = true
      setEnginePaused(false)
      discard eventSendShort(EVENT_TYPE_SYSTEM, SYSTEM_EVENT_CLOSE.orxU32)

  ## Movement override lifetime
  for playerIndex in 0 ..< 4:
    if movement.movementOverride[playerIndex].isSome and
        test.time >= test.moveUntil[playerIndex] and
        not test.completed:
      movement.movementOverride[playerIndex] =
        options.none((float32, float32))

  ## Completion detection while walking into the exit
  if test.exitTeleported and not test.completed and
      (gs.levelCompleted or gs.phase == phComplete):
    test.completed = true
    movement.movementOverride[0] = options.none((float32, float32))

  ## Track cave-2 creature travel so the test can assert they keep moving
  ## (wall-hugging steering must never stall them).
  if test.creatureSpawns.len > 0:
    if test.creaturePath.len != creatures.creatures.len:
      test.creaturePath.setLen(creatures.creatures.len)
      test.creatureLastPos.setLen(creatures.creatures.len)
    for i, creature in creatures.creatures:
      if creature.obj == nil:
        continue
      let position = creature.obj.getWorldPosition()
      if test.creaturePath[i] == 0.0 and
          test.creatureLastPos[i].fX == 0.0 and
          test.creatureLastPos[i].fY == 0.0:
        discard
      else:
        test.creaturePath[i] += hypot(
          position.fX - test.creatureLastPos[i].fX,
          position.fY - test.creatureLastPos[i].fY)
      test.creatureLastPos[i] = position

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

  contacts.processContacts()

  case gs.phase
  of phModeSelect:
    var joined = 1
    for i in 1 ..< gs.maxPlayers:
      if not joinedPlayers[i] and joinActivated(i):
        joinedPlayers[i] = true
        inc joined
        ui.showSubMessage(&"PLAYER {i + 1} JOINED ({joined})", 1.5)
    if hasBeenActivated("Confirm"):
      startRun()
  of phIntro:
    gs.phaseTimer -= deltaTime
    if gs.phaseTimer <= 0.0:
      enterPhase(phPlaying)
  of phPlaying:
    gs.timeLeft = max(0.0'f32, gs.timeLeft - deltaTime)
    if gs.timeLeft <= 0.0 and not gs.timeExpired:
      # The clock ran out: every alive hero dies once; respawns then
      # continue in the mined cave.
      gs.timeExpired = true
      for hero in world.players:
        world.killPlayer(hero.index, "Out of time")
    for hero in world.players.mitems:
      movement.updatePlayer(hero, deltaTime)
      if hero.respawnTimer > 0.0:
        hero.respawnTimer = max(0.0'f32, hero.respawnTimer - deltaTime)
        if hero.respawnTimer <= 0.0:
          world.respawnPlayer(hero.index)
      if hero.invulnTimer > 0.0:
        hero.invulnTimer = max(0.0'f32, hero.invulnTimer - deltaTime)
    if world.players.len > 0 and world.players.allIt(it.down):
      ui.showMessage("GAME OVER", 0.0)
      ui.showSubMessage(
        &"Final score: {gs.score} - press R / Y to retry", 0.0)
      enterPhase(phGameOver)
    creatures.updateCreatures(deltaTime)
    if not gs.exitOpen and gs.collected >= gs.needed:
      world.openExit()
      ui.showSubMessage("EXIT OPEN!", 2.0)
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

  ## End of frame: release objects destroyed during it (see
  ## world.destroyObject for why deletion is deferred).
  world.flushDestroyed()

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
    (action: "Confirm", expectedType: INPUT_TYPE_KEYBOARD_KEY,
     expectedId: ord(KEYBOARD_KEY_ENTER).orxENUM),
    (action: "Confirm", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_A_1).orxENUM),
    (action: "MoveLeft", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_LEFT_1).orxENUM),
    (action: "MoveXAxis", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LX_1).orxENUM),
    (action: "MoveYAxis", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LY_1).orxENUM),
    (action: "MoveLeftP2", expectedType: INPUT_TYPE_KEYBOARD_KEY,
     expectedId: ord(KEYBOARD_KEY_LEFT).orxENUM),
    (action: "MoveLeftP2", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_LEFT_2).orxENUM),
    (action: "MoveXAxisP2", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LX_2).orxENUM),
    (action: "JoinP2", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_START_2).orxENUM),
    (action: "MoveLeftP3", expectedType: INPUT_TYPE_KEYBOARD_KEY,
     expectedId: ord(KEYBOARD_KEY_J).orxENUM),
    (action: "MoveXAxisP3", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LX_3).orxENUM),
    (action: "JoinP3", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_START_3).orxENUM),
    (action: "MoveLeftP4", expectedType: INPUT_TYPE_KEYBOARD_KEY,
     expectedId: ord(KEYBOARD_KEY_NUMPAD_4).orxENUM),
    (action: "MoveXAxisP4", expectedType: INPUT_TYPE_JOYSTICK_AXIS,
     expectedId: ord(JOYSTICK_AXIS_LX_4).orxENUM),
    (action: "JoinP4", expectedType: INPUT_TYPE_JOYSTICK_BUTTON,
     expectedId: ord(JOYSTICK_BUTTON_START_4).orxENUM)
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

  for section in ["Player", "Player2", "Player3", "Player4",
                  "BoulderSmall", "Boulder", "BoulderBig",
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
    gs.maxPlayers = getS32("MaxPlayers").int
    gs.diamondScore = getS32("DiamondScore").int
    gs.digScore = getS32("DigScore").int
    gs.timeBonusPerSecond = getS32("TimeBonusPerSecond").int
    discard popSection()
  if gs.maxPlayers < 1 or gs.maxPlayers > 4:
    gs.maxPlayers = 4
  gs.playerCount = 1

  mainViewport = viewportCreateFromConfig("MainViewport")
  if mainViewport == nil:
    echo "Could not create the main viewport"
    return STATUS_FAILURE
  # Second viewport for the HUD: its camera never sees the world (z range),
  # so it only ever renders the HUD text on top of the game view.
  hudViewport = viewportCreateFromConfig("HudViewport")
  if hudViewport == nil:
    echo "Could not create the HUD viewport"
    return STATUS_FAILURE
  mainCamera = getCamera(mainViewport)
  if mainCamera == nil:
    echo "Could not fetch the main camera"
    return STATUS_FAILURE
  if pushSection("MainCamera").isSuccess:
    cameraHalfW = getFloat("FrustumWidth") * 0.5'f32
    cameraHalfH = getFloat("FrustumHeight") * 0.5'f32
    cameraNear = getFloat("FrustumNear")
    cameraFar = getFloat("FrustumFar")
    discard popSection()
  if cameraHalfW == 0.0:
    cameraHalfW = 640.0
    cameraHalfH = 360.0
  if cameraFar <= cameraNear:
    cameraNear = 0.0
    cameraFar = 4.0

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
  joinedPlayers[0] = true
  if startupTest or startupTestMp:
    gs.playerCount = (if startupTestMp: 2 else: 1)
    testScenario = (if startupTestMp: ScenarioMp else: Scenario)
    test = TestScript(active: true, mp: startupTestMp)
    if not runConfigChecks():
      return STATUS_FAILURE
  if not world.loadWorld(0):
    echo "Could not load the first level"
    return STATUS_FAILURE
  creatures.spawnPending()
  if startupTest or startupTestMp:
    showLevelIntro()
  else:
    enterPhase(phModeSelect)
    ui.showMessage("ROCKRUN - COOP MODE", 0.0)
    ui.showSubMessage(
      "1-4 players - move or press Start to join - Enter to play", 0.0)

  if registerContactHandler().isFailure:
    echo "Could not register the physics handler"
    return STATUS_FAILURE

  coreClock = clockGet(CLOCK_KZ_CORE)
  if coreClock == nil:
    return STATUS_FAILURE
  result = clockRegister(coreClock, updateGame, nil, MODULE_ID_MAIN,
                         CLOCK_PRIORITY_NORMAL)
  initializationSucceeded = result.isSuccess

proc run(): orxSTATUS {.cdecl.} =
  if startupTest or startupTestMp:
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
    # Typefaces are located through the "Font" resource group.
    discard addStorage("Font", basePath / "font", false)
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
      ((startupTest or startupTestMp) and test.failures.len > 0):
    quit(1)
  if startupTest and test.boulder == nil:
    quit(1)
