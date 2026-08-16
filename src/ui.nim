## HUD and on-screen messages for Rockrun. Lives in the second viewport.
import strformat
import norx
import game

var
  scoreObject: ptr orxOBJECT
  diamondsObject: ptr orxOBJECT
  timeObject: ptr orxOBJECT
  livesObject: ptr orxOBJECT
  levelObject: ptr orxOBJECT
  messageObject: ptr orxOBJECT
  subMessageObject: ptr orxOBJECT
  messageTimer, subMessageTimer: float32
  lastShownSeconds = -1

  ## HUD objects positioned in screen space each frame (see
  ## positionHud): offsets are screen pixels from the top-left corner.
  hudItems: seq[tuple[obj: ptr orxOBJECT, x, y: float32]]

proc initUi*(): bool =
  ## Creates all HUD objects from config.
  scoreObject = objectCreateFromConfig("HudScore")
  diamondsObject = objectCreateFromConfig("HudDiamonds")
  timeObject = objectCreateFromConfig("HudTime")
  livesObject = objectCreateFromConfig("HudLives")
  levelObject = objectCreateFromConfig("HudLevel")
  discard objectCreateFromConfig("HudHint")
  messageObject = objectCreateFromConfig("LevelMessage")
  subMessageObject = objectCreateFromConfig("SubMessage")
  if scoreObject == nil or diamondsObject == nil or timeObject == nil or
      livesObject == nil or levelObject == nil or messageObject == nil or
      subMessageObject == nil:
    echo "Could not create the HUD"
    return false
  hudItems = @[
    (scoreObject, 20.0'f32, 18.0'f32),
    (diamondsObject, 420.0'f32, 18.0'f32),
    (timeObject, 760.0'f32, 18.0'f32),
    (livesObject, 1050.0'f32, 18.0'f32),
    (levelObject, 20.0'f32, 84.0'f32),
    (messageObject, 640.0'f32, 300.0'f32),
    (subMessageObject, 640.0'f32, 400.0'f32)
  ]
  discard messageObject.enable(false)
  discard subMessageObject.enable(false)
  result = true

proc positionHud*(cameraX, cameraY: float32) =
  ## Places every HUD object in screen space relative to the camera, on a
  ## world Z above everything else so it always renders in front.
  for item in hudItems:
    discard item.obj.setPosition(newVector(
      cameraX + item.x - 640.0, cameraY + item.y - 360.0, 2.0))

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
  discard livesObject.setTextString(&"LIVES {gs.lives}")
  discard levelObject.setTextString(
    &"CAVE {gs.levelIndex + 1}: {gs.levelName}")
