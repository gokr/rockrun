## Player movement, digging and animation for Rockrun.
##
## Each hero is a dynamic physics body: movement is applied as an
## absolute velocity so the player can push boulders naturally through
## physics and climb through sand (by digging it away). Gravity is off
## (classic Boulder Dash movement), so vertical motion is pure input.
## All per-player state (animation, dig timers) lives on the `Player`
## record in world.nim; this module only applies inputs to heroes.
import options
import math
import norx
import game
import world

var
  movementOverride*: array[4, Option[(float32, float32)]]
  ## When set (startup test), replaces live input for that player.
  animSawDig* = false
  ## Set when the dig swing animation has been triggered at least once.

proc inputName(player: Player; base: string): string =
  ## ORX action name for one hero's input: P1 keeps the classic
  ## unsuffixed bindings (MoveLeft, ...), later players get a suffix
  ## (MoveLeftP2, ...) bound to their own keys/controller.
  if player.inputSet == "" or player.inputSet == "P1":
    base
  else:
    base & player.inputSet

proc clampAxis(value: float32): float32 =
  ## Applies the dead zone to an analog stick axis.
  if abs(value) < Deadzone:
    0.0
  else:
    clamp(value, -1.0'f32, 1.0'f32)

proc inputDirection*(player: Player): tuple[x, y: float32] =
  ## Combined direction from d-pad/keys and the analog stick for one hero.
  if player.index >= 0 and player.index < movementOverride.len and
      movementOverride[player.index].isSome:
    return movementOverride[player.index].get

  var
    dx, dy: float32
  if isActive(inputName(player, "MoveLeft")): dx -= 1.0
  if isActive(inputName(player, "MoveRight")): dx += 1.0
  if isActive(inputName(player, "MoveUp")): dy -= 1.0
  if isActive(inputName(player, "MoveDown")): dy += 1.0

  dx += clampAxis(getValue(inputName(player, "MoveXAxis")))
  dy += clampAxis(getValue(inputName(player, "MoveYAxis")))

  dx = clamp(dx, -1.0'f32, 1.0'f32)
  dy = clamp(dy, -1.0'f32, 1.0'f32)
  if dx != 0.0 and dy != 0.0:
    let inv = 1.0'f32 / hypot(dx, dy)
    dx *= inv
    dy *= inv
  (dx, dy)

proc boulderAhead(player: Player; dx: float32): bool =
  ## Is there a boulder right where the player is pushing?
  let position = player.obj.getWorldPosition()
  for boulder in world.boulders:
    let rockPosition = boulder.getWorldPosition()
    if abs(rockPosition.fY - position.fY) < 28.0 and
        (rockPosition.fX - position.fX) * dx > 12.0 and
        (rockPosition.fX - position.fX) * dx < 52.0:
      return true
  result = false

proc playAnim(player: var Player; animName: string) =
  if player.obj != nil and player.currentAnim != animName:
    player.currentAnim = animName
    if animName == "Dig":
      animSawDig = true
    let status = player.obj.setCurrentAnim(animName.cstring)
    when defined(debugAnim):
      echo "ANIM -> ", animName, " status=", status

proc updatePlayer*(player: var Player; deltaTime: float32) =
  ## Applies movement, digging, animation and push feedback for one hero.
  if player.obj == nil or gs.phase != phPlaying:
    return
  if player.respawnTimer > 0.0:
    # Corpse: waits out the respawn delay at the death spot.
    return

  let (dx, dy) = inputDirection(player)
  let previousSpeed = player.obj.getSpeed()
  var speed = previousSpeed
  speed.fX = dx * PlayerSpeed
  # Anti-gravity player: vertical position changes only through input.
  speed.fY = dy * PlayerSpeed
  discard player.obj.setSpeed(speed)
  when defined(testForceMove):
    var force = newVector(dx * 9000.0, 0.0, 0.0)
    discard player.obj.applyForce(addr force, nil)
  world.dugThisFrame = 0
  digAround(player.obj.getWorldPosition(), dx, dy, player.obj)
  let dug = world.dugThisFrame > 0

  # Animation state machine: dig swing while digging, run while moving,
  # idle otherwise.
  if player.digAnimTimer > 0.0:
    player.digAnimTimer -= deltaTime
    if player.digAnimTimer <= 0.0 and dx == 0.0 and dy == 0.0:
      playAnim(player, "Idle")
  if dug and player.digAnimTimer <= 0.0:
    # Every other dig triggers the swing animation, so repeated digging
    # doesn't look frantic.
    player.digFlip = not player.digFlip
    if player.digFlip:
      # 3 frames at ~0.12s; retriggers while the player keeps digging.
      player.digAnimTimer = 0.36
      playAnim(player, "Dig")
  elif player.digAnimTimer <= 0.0:
    if dx != 0.0 or dy != 0.0:
      playAnim(player, "Run")
    else:
      playAnim(player, "Idle")

  # Push feedback when squeezed against a boulder: we order the player to
  # move but physical velocity barely follows because a boulder is ahead.
  if dx != 0.0 and abs(previousSpeed.fX) < 60.0 and boulderAhead(player, dx) and
      gs.worldClockTime - gs.lastPush >= PushInterval:
    gs.lastPush = gs.worldClockTime
    discard player.obj.addSound("PushSound")
