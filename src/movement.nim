## Player movement and digging for Rockrun.
##
## The player is a dynamic physics body: movement is applied as an
## absolute velocity so the player can push boulders naturally through
## physics, climb through dirt (by digging it away), and fall with
## realistic gravity when nothing is held.
import options
import math
import norx
import game
import world

var
  movementOverride*: Option[tuple[x, y: float32]]
  ## When set (startup test), replaces live input.

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

proc updatePlayer*(deltaTime: float32) =
  ## Applies movement, digging and push feedback for the current frame.
  if player == nil or gs.phase != phPlaying:
    return

  let (dx, dy) = inputDirection()
  let previousSpeed = player.getSpeed()
  var speed = previousSpeed
  speed.fX = dx * PlayerSpeed
  # The player is anti-gravity (classic Boulder Dash movement): vertical
  # position only changes through intentional input.
  speed.fY = dy * PlayerSpeed
  discard player.setSpeed(speed)
  when defined(testForceMove):
    var force = newVector(dx * 9000.0, 0.0, 0.0)
    discard player.applyForce(addr force, nil)

  digAround(player.getWorldPosition(), dx, dy)

  # Push feedback when squeezed against a boulder: we order the player to
  # move but physical velocity barely follows because a boulder is ahead.
  if dx != 0.0 and abs(previousSpeed.fX) < 60.0 and boulderAhead(dx) and
      gs.worldClockTime - gs.lastPush >= PushInterval:
    gs.lastPush = gs.worldClockTime
    discard player.addSound("PushSound")
