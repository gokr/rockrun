## HUD and on-screen messages for Rockrun. Rendered by the dedicated
## HudViewport (camera-space objects at z=-1.5), so text always draws on
## top of the world.
import strformat
import norx
import game
import world

var
  scoreObject: ptr orxOBJECT
  diamondsObject: ptr orxOBJECT
  timeObject: ptr orxOBJECT
  levelObject: ptr orxOBJECT
  playerObjects: array[4, ptr orxOBJECT]
  messageObject: ptr orxOBJECT
  subMessageObject: ptr orxOBJECT
  messageTimer, subMessageTimer: float32
  lastShownSeconds = -1

proc initUi*(): bool =
  ## Creates all HUD objects from config.
  scoreObject = objectCreateFromConfig("HudScore")
  diamondsObject = objectCreateFromConfig("HudDiamonds")
  timeObject = objectCreateFromConfig("HudTime")
  levelObject = objectCreateFromConfig("HudLevel")
  discard objectCreateFromConfig("HudHint")
  for i in 0 ..< playerObjects.len:
    playerObjects[i] = objectCreateFromConfig("HudPlayer" & $(i + 1))
    if playerObjects[i] == nil:
      echo "Could not create the player HUD line"
      return false
  messageObject = objectCreateFromConfig("LevelMessage")
  subMessageObject = objectCreateFromConfig("SubMessage")
  if scoreObject == nil or diamondsObject == nil or timeObject == nil or
      levelObject == nil or messageObject == nil or
      subMessageObject == nil:
    echo "Could not create the HUD"
    return false
  discard messageObject.enable(false)
  discard subMessageObject.enable(false)
  result = true

proc showMessage*(text: string; duration: float32) =
  ## Big centered headline, hidden after `duration` (<= 0 keeps it).
  discard messageObject.setTextString(text)
  discard messageObject.enable(true)
  messageTimer = duration

proc showSubMessage*(text: string; duration: float32) =
  ## Small centered sub headline.
  discard subMessageObject.setTextString(text)
  discard subMessageObject.enable(true)
  subMessageTimer = duration

proc hideMessages*() =
  discard messageObject.enable(false)
  discard subMessageObject.enable(false)
  messageTimer = 0.0
  subMessageTimer = 0.0

proc hudReady*(): bool =
  scoreObject != nil and messageObject != nil

proc updateUi*(deltaTime: float32) =
  ## Refreshes the HUD text when marked dirty and ages messages.
  if messageTimer > 0.0:
    messageTimer -= deltaTime
    if messageTimer <= 0.0:
      discard messageObject.enable(false)
  if subMessageTimer > 0.0:
    subMessageTimer -= deltaTime
    if subMessageTimer <= 0.0:
      discard subMessageObject.enable(false)

  let shownSeconds = int(gs.timeLeft + 0.9'f32)
  if not gs.hudDirty and shownSeconds == lastShownSeconds:
    return
  lastShownSeconds = shownSeconds
  gs.hudDirty = false

  discard scoreObject.setTextString(&"SCORE {gs.score}")
  discard diamondsObject.setTextString(
    &"GEMS {gs.collected}/{gs.needed}")
  discard timeObject.setTextString(&"TIME {shownSeconds}")
  discard levelObject.setTextString(
    &"CAVE {gs.levelIndex + 1}: {gs.levelName}")
  for i in 0 ..< playerObjects.len:
    let obj = playerObjects[i]
    if i < gs.playerCount and i < world.players.len:
      discard obj.enable(true)
      let hero = world.players[i]
      let status =
        if hero.down: "OUT"
        elif hero.respawnTimer > 0.0: "!"
        else: $hero.lives
      discard obj.setTextString(&"P{i + 1} {status}")
    else:
      discard obj.enable(false)
