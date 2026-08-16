## Fireflies and butterflies: classic Boulder Dash wall huggers.
##
## Fireflies keep the wall on their LEFT (prefer right turns, orbit
## clockwise); butterflies keep it on their RIGHT (left turns). They move
## smoothly between cell centers as small physics bodies and make their
## turning decision only when they reach a cell center - the deterministic
## grid behavior of the original, but physical on the way there.
##
## Crushing one with a falling boulder turns it into a burst of diamonds.
import math
import norx
import game
import world

type
  CreatureKind* = enum
    ckFirefly
    ckButterfly

  Creature* = object
    obj*: ptr orxOBJECT
    kind*: CreatureKind
    cellX*, cellY*: int
    dirX*, dirY*: int
    targetX*, targetY*: int
    speed*: float32
    stuckTime*: float32 ## accumulated stall time (see StuckLimit)
    legStartDist*: float32 ## distance to target at the start of the leg
    legTime*: float32 ## time since the leg baseline was taken
    wakeTimer*: float32 ## daze after the blocking sand is dug away
    wasTouchingSand*: bool ## pressed against sand (set by contacts)

var
  creatures*: seq[Creature]

const
  FireflySpeed* = 90.0'f32
  ButterflySpeed* = 115.0'f32
  ArrivalDistance = 6.0'f32
  ## How long a creature freed from sand (its blocking wall was dug
  ## away) stays dazed: classic BD's reaction window when digging into
  ## a hidden creature.
  WakeTime = 0.4'f32
  ## Stuck detection: the distance to the target cell must shrink by at
  ## least StuckMinProgress px per StuckWindow seconds. Windowed and
  ## time-based on purpose - per-frame thresholds break at high clock
  ## rates (the core clock runs at display frequency, e.g. 240Hz).
  StuckWindow = 0.35'f32
  StuckMinProgress = 4.0'f32
  StuckLimit = 0.5'f32

proc blockedAt*(cx, cy: int): bool =
  ## True when a cell stops a creature: outside, wall, or any sand.
  if cx < 0 or cx >= worldW or cy < 0 or cy >= worldH:
    return true
  if world.walls[cy * worldW + cx]:
    return true
  let cell = world.sandCells[cy * worldW + cx]
  if cell.refined:
    result = world.grainCounts[cy * worldW + cx] > 0
  else:
    result = cell.big != nil

proc turnLeft(dx, dy: int): tuple[x, y: int] = (dy, -dx)
proc turnRight(dx, dy: int): tuple[x, y: int] = (-dy, dx)

proc chooseDirection(creature: var Creature) =
  ## Classic Boulder Dash wall-hugging at a cell center: go STRAIGHT as
  ## long as the cell ahead is free; only when blocked, turn right
  ## (firefly, wall on the left, clockwise patrol) or left (butterfly,
  ## counter-clockwise); then the other turn; then reverse. The
  ## straight-first order is what makes creatures follow walls and
  ## patrol the perimeter of open areas - trying the turn first makes
  ## them zigzag across wide corridors and orbit in small squares.
  let (dx, dy) = (creature.dirX, creature.dirY)
  var options: array[4, tuple[x, y: int]]
  if creature.kind == ckFirefly:
    options = [(dx, dy), turnRight(dx, dy), turnLeft(dx, dy), (-dx, -dy)]
  else:
    options = [(dx, dy), turnLeft(dx, dy), turnRight(dx, dy), (-dx, -dy)]
  for option in options:
    let nx = creature.cellX + option.x
    let ny = creature.cellY + option.y
    if not blockedAt(nx, ny):
      creature.dirX = option.x
      creature.dirY = option.y
      creature.targetX = nx
      creature.targetY = ny
      return
  # Fully enclosed: stay put.
  creature.dirX = 0
  creature.dirY = 0
  creature.targetX = creature.cellX
  creature.targetY = creature.cellY

proc spawnCreature*(configName: string; cx, cy: int;
                    kind: CreatureKind): ptr orxOBJECT =
  ## Spawns a creature at a cell center; its initial direction is chosen
  ## against the occupancy map so it never starts pressing into a wall.
  result = objectCreateFromConfig(configName)
  if result != nil:
    let position = world.cellWorld(cx, cy)
    discard result.setPosition(
      newVector(position.fX, position.fY, world.CreatureZ))
    discard result.addFX("SparkleFX")
    creatures.add(Creature(obj: result, kind: kind, cellX: cx, cellY: cy,
                           dirX: 1, dirY: 0, targetX: cx + 1, targetY: cy,
                           speed: (if kind == ckFirefly: FireflySpeed
                                   else: ButterflySpeed)))
    chooseDirection(creatures[creatures.high])

proc explodeCreature*(gameObject: ptr orxOBJECT) =
  ## A falling boulder crushed the creature: burst into nine diamonds.
  ## The creature record is removed from tracking so later frames never
  ## dereference the destroyed object.
  if gameObject == nil or world.isDestroyed(gameObject):
    return
  for index in countdown(creatures.high, 0):
    if creatures[index].obj == gameObject:
      creatures.delete(index)
  let position = gameObject.getWorldPosition()
  world.spawnBurst("GemSparkle", position, 5)
  discard gameObject.addSound("ClinkSound")
  for offset in world.SubOffsets:
    let spot = newVector(position.fX + offset.x, position.fY + offset.y, 0.0)
    let (cx, cy) = world.cellOf(spot)
    var spawn = spot
    if blockedAt(cx, cy):
      # Never push gems inside static sand; pile them on the creature spot.
      spawn = position
    let gem = objectCreateFromConfig("Diamond")
    if gem != nil:
      discard gem.setPosition(spawn)
      discard gem.addFX("SparkleFX")
      world.gems.add(gem)
  world.destroyObject(gameObject)
  gs.hudDirty = true

proc spawnPending*() =
  ## Instantiates all creatures recorded by world level parsing.
  for pending in world.pendingCreatures:
    let kind = (if pending.config == "Firefly": ckFirefly else: ckButterfly)
    discard spawnCreature(pending.config, pending.x, pending.y, kind)

proc markTouchingSand*(gameObject: ptr orxOBJECT) =
  ## A physics contact pressed this creature against sand (set while the
  ## contact queue is drained; consumed by updateCreatures).
  for creature in creatures.mitems:
    if creature.obj == gameObject:
      creature.wasTouchingSand = true
      return

proc isDazed*(gameObject: ptr orxOBJECT): bool =
  ## True while the creature is in the wake-up daze (it can neither move
  ## nor kill).
  for creature in creatures:
    if creature.obj == gameObject:
      return creature.wakeTimer > 0.0
  false

proc updateCreatures*(deltaTime: float32) =
  ## Drives creature steering and smooth movement.
  for creature in creatures.mitems:
    if creature.obj == nil or world.isDestroyed(creature.obj):
      continue
    # Wake-up daze: pressed against sand keeps the daze alive; once the
    # sand is dug away the timer runs out and the creature resumes.
    if creature.wasTouchingSand:
      creature.wakeTimer = WakeTime
      creature.wasTouchingSand = false
    if creature.wakeTimer > 0.0:
      creature.wakeTimer = max(0.0'f32, creature.wakeTimer - deltaTime)
      discard creature.obj.setSpeed(newVector(0.0, 0.0, 0.0))
      continue
    # If the current target became blocked (e.g. sand refined or a wall
    # neighbour carved), re-steer instead of pressing against it.
    if blockedAt(creature.targetX, creature.targetY):
      chooseDirection(creature)
    let position = creature.obj.getWorldPosition()
    let target = world.cellWorld(creature.targetX, creature.targetY)
    let dx = target.fX - position.fX
    let dy = target.fY - position.fY
    let dist = abs(dx) + abs(dy)

    # Stuck detection over a time window: a healthy leg towards the target
    # cell shrinks the distance steadily; stalling against a boulder or a
    # wall edge does not. Frame-rate independent.
    creature.legTime += deltaTime
    if creature.legTime >= StuckWindow:
      creature.legTime = 0.0
      if dist >= creature.legStartDist - StuckMinProgress:
        creature.stuckTime += StuckWindow
      else:
        creature.stuckTime = 0.0
      creature.legStartDist = dist

    if dist <= ArrivalDistance:
      creature.cellX = creature.targetX
      creature.cellY = creature.targetY
      chooseDirection(creature)
      creature.stuckTime = 0.0
      let next = world.cellWorld(creature.targetX, creature.targetY)
      let ndx = next.fX - position.fX
      let ndy = next.fY - position.fY
      let length = max(1.0'f32, hypot(ndx, ndy))
      discard creature.obj.setSpeed(newVector(
        ndx / length * creature.speed, ndy / length * creature.speed, 0.0))
      # Baseline for the new leg: distance to the freshly chosen target.
      creature.legStartDist = abs(ndx) + abs(ndy)
      creature.legTime = 0.0
    else:
      if creature.stuckTime > StuckLimit:
        creature.stuckTime = 0.0
        chooseDirection(creature)
      # Aim at the (possibly re-steered) target.
      let aim = world.cellWorld(creature.targetX, creature.targetY)
      let adx = aim.fX - position.fX
      let ady = aim.fY - position.fY
      let length = max(1.0'f32, hypot(adx, ady))
      discard creature.obj.setSpeed(newVector(
        adx / length * creature.speed, ady / length * creature.speed, 0.0))

proc clearCreatures*() =
  ## Drops creature tracking before a world reload destroys the objects.
  creatures.setLen(0)
