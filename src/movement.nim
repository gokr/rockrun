## Player movement, digging and animation for Rockrun.
##
## The player is a dynamic physics body: movement is applied as an
## absolute velocity so the player can push boulders naturally through
## physics and climb through sand (by digging it away). Gravity is off
## (classic Boulder Dash movement), so vertical motion is pure input.
import options
import math
import norx
import game
import world

var
  movementOverride*: Option[tuple[x, y: float32]]
  ## When set (startup test), replaces live input.
  currentAnim = ""
  digAnimTimer: float32 = 0.0
  animSawDig* = false
  ## Set when the dig swing animation has been triggered at least once.

proc clampAxis(value: float32): float32 =
  ## Applies the dead zone to an analog stick axis.
  if abs(value) < Deadzone:
    0.0
  else:
    clamp(value, -1.0'f32, 1.0'f32)

proc inputDirection*(): tuple[x, y: float32] =
  ## Combined direction from d-pad/keys and the analog stick.
  if movementOverride.isSome:
    return movementOverride.get

  var
    dx, dy: float32
  if isActive("MoveLeft"): dx -= 1.0
  if isActive("MoveRight"): dx += 1.0
  if isActive("MoveUp"): dy -= 1.0
  if isActive("MoveDown"): dy += 1.0

  dx += clampAxis(getValue("MoveXAxis"))
  dy += clampAxis(getValue("MoveYAxis"))

  dx = clamp(dx, -1.0'f32, 1.0'f32)
  dy = clamp(dy, -1.0'f32, 1.0'f32)
  if dx != 0.0 and dy != 0.0:
    let inv = 1.0'f32 / hypot(dx, dy)
    dx *= inv
    dy *= inv
  (dx, dy)

proc boulderAhead(dx: float32): bool =
  ## Is there a boulder right where the player is pushing?
  let position = player.getWorldPosition()
  for boulder in world.boulders:
    let rockPosition = boulder.getWorldPosition()
    if abs(rockPosition.fY - position.fY) < 28.0 and
        (rockPosition.fX - position.fX) * dx > 12.0 and
        (rockPosition.fX - position.fX) * dx < 52.0:
      return true
  result = false

proc playAnim(animName: string) =
  if player != nil and currentAnim != animName:
    currentAnim = animName
    if animName == "Dig":
      animSawDig = true
    let status = player.setCurrentAnim(animName.cstring)
    when defined(debugAnim):
      echo "ANIM -> ", animName, " status=", status

proc updatePlayer*(deltaTime: float32) =
  ## Applies movement, digging, animation and push feedback.
  if player == nil or gs.phase != phPlaying:
    return

  let (dx, dy) = inputDirection()
  let previousSpeed = player.getSpeed()
  var speed = previousSpeed
  speed.fX = dx * PlayerSpeed
  # Anti-gravity player: vertical position changes only through input.
  speed.fY = dy * PlayerSpeed
  discard player.setSpeed(speed)
  when defined(testForceMove):
    var force = newVector(dx * 9000.0, 0.0, 0.0)
    discard player.applyForce(addr force, nil)
  world.dugThisFrame = 0
  digAround(player.getWorldPosition(), dx, dy)
  let dug = world.dugThisFrame > 0

  # Animation state machine: dig swing while digging, run while moving,
  # idle otherwise.
  if digAnimTimer > 0.0:
    digAnimTimer -= deltaTime
    if digAnimTimer <= 0.0 and dx == 0.0 and dy == 0.0:
      playAnim("Idle")
  if dug and digAnimTimer <= 0.0:
    # 3 frames at ~0.12s; retriggers every frame the player keeps
    # digging, so the swing loops for the whole dig.
    digAnimTimer = 0.36
    playAnim("Dig")
  elif digAnimTimer <= 0.0:
    if dx != 0.0 or dy != 0.0:
      playAnim("Run")
    else:
      playAnim("Idle")

  # Push feedback when squeezed against a boulder: we order the player to
  # move but physical velocity barely follows because a boulder is ahead.
  if dx != 0.0 and abs(previousSpeed.fX) < 60.0 and boulderAhead(dx) and
      gs.worldClockTime - gs.lastPush >= PushInterval:
    gs.lastPush = gs.worldClockTime
    discard player.addSound("PushSound")
