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
    lastDist*: float32
    stuckTime*: float32

var
  creatures*: seq[Creature]

const
  FireflySpeed* = 90.0'f32
  ButterflySpeed* = 115.0'f32
  ArrivalDistance = 6.0'f32

proc blockedAt*(cx, cy: int): bool =
  ## True when a cell stops a creature: outside, wall, or any sand.
  if cx < 0 or cx >= worldW or cy < 0 or cy >= worldH:
    return true
  if world.walls[cy * worldW + cx]:
    return true
  let cell = world.sandCells[cy * worldW + cx]
  if cell.refined:
    for sub in cell.subs:
      if sub != nil:
        return true
    result = false
  else:
    result = cell.big != nil

proc turnLeft(dx, dy: int): tuple[x, y: int] = (dy, -dx)
proc turnRight(dx, dy: int): tuple[x, y: int] = (-dy, dx)

proc chooseDirection(creature: var Creature) =
  ## Classic wall-hugging preference order at a cell center.
  let (dx, dy) = (creature.dirX, creature.dirY)
  var options: array[4, tuple[x, y: int]]
  if creature.kind == ckFirefly:
    options = [turnRight(dx, dy), (dx, dy), turnLeft(dx, dy), (-dx, -dy)]
  else:
    options = [turnLeft(dx, dy), (dx, dy), turnRight(dx, dy), (-dx, -dy)]
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

proc updateCreatures*(deltaTime: float32) =
  ## Drives creature steering and smooth movement.
  for creature in creatures.mitems:
    if creature.obj == nil or world.isDestroyed(creature.obj):
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

    # Stuck detection: if we are not arriving and made no progress
    # towards the target for a while, the body is probably wedged or
    # sliding along a wall - pick a new direction.
    if dist > ArrivalDistance:
      if dist >= creature.lastDist - 1.0'f32:
        creature.stuckTime += deltaTime
      else:
        creature.stuckTime = 0.0
      if creature.stuckTime > 0.5:
        creature.stuckTime = 0.0
        chooseDirection(creature)
    creature.lastDist = dist

    if dist <= ArrivalDistance:
      creature.cellX = creature.targetX
      creature.cellY = creature.targetY
      chooseDirection(creature)
      let next = world.cellWorld(creature.targetX, creature.targetY)
      let ndx = next.fX - position.fX
      let ndy = next.fY - position.fY
      let length = max(1.0'f32, hypot(ndx, ndy))
      discard creature.obj.setSpeed(newVector(
        ndx / length * creature.speed, ndy / length * creature.speed, 0.0))
    else:
      let length = max(1.0'f32, hypot(dx, dy))
      discard creature.obj.setSpeed(newVector(
        dx / length * creature.speed, dy / length * creature.speed, 0.0))

proc clearCreatures*() =
  ## Drops creature tracking before a world reload destroys the objects.
  creatures.setLen(0)
