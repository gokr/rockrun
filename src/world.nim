## World management for Rockrun: level parsing, spawning, digging,
## collecting, and destruction of ORX objects with physics bodies.
##
## Sand uses two-tier subdivision: caves start as 32px blocks textured
## identically to four 16px blocks (Repeat 2x2), and blocks near the
## player are swapped for four small blocks - invisible visually, but much
## cheaper than keeping the whole cave fine-grained.
import sets
import norx
import game

type
  CellKind* = enum
    cEmpty
    cDirt
    cWall
    cBoulder
    cGem
    cExit

  LevelDef* = object
    ## Parsed level data before instantiation.
    name*: string
    needed*: int
    timeLimit*: float32
    rows*: seq[string]

  SandCell* = object
    ## One 32px cave cell either holding a big block or sixteen refined
    ## 8px blocks (4x4 subdivision).
    big*: ptr orxOBJECT
    refined*: bool
    subs*: array[16, ptr orxOBJECT]
    center*: orxVECTOR

const
  ## Sub-grid size per cell (4x4) and block size in pixels.
  SubGrid* = 4
  SubBlock* = CellSize / SubGrid.float32

proc computeSubOffsets(): array[SubGrid * SubGrid, tuple[x, y: float32]]
    {.compileTime.} =
  ## Sub-block center offsets inside a 32px cell, row-major.
  for i in 0 ..< SubGrid * SubGrid:
    let col = i mod SubGrid
    let row = i div SubGrid
    result[i] = (
      x: (-SubBlock * (SubGrid.float32 - 1.0'f32) * 0.5'f32) +
         col.float32 * SubBlock,
      y: (-SubBlock * (SubGrid.float32 - 1.0'f32) * 0.5'f32) +
         row.float32 * SubBlock)

const SubOffsets* = computeSubOffsets()

var
  worldW*, worldH*: int
  worldMinX*, worldMaxX*, worldMinY*, worldMaxY*: float32
  sandCells*: seq[SandCell]
  walls*: seq[bool]
  pendingCreatures*: seq[tuple[config: string, x, y: int]]
  player*: ptr orxOBJECT
  exitObject*: ptr orxOBJECT
  boulders*: seq[ptr orxOBJECT]
  gems*: seq[ptr orxOBJECT]
  dirts*: seq[ptr orxOBJECT]
  playerSpawnX*, playerSpawnY*: int

var
  destroyedObjects: HashSet[pointer]

proc levelSection(index: int): string = "Level" & $(index + 1)

proc readLevel*(index: int; level: var LevelDef): bool =
  ## Reads a level definition from config without spawning anything.
  let section = levelSection(index)
  if not hasSection(section.cstring):
    echo "Missing config section [", section, "]"
    return false
  if pushSection(section).isFailure:
    return false
  defer:
    discard popSection()

  level = LevelDef()
  level.name = $getString("Name")
  level.needed = getS32("NeededDiamonds").int
  level.timeLimit = getFloat("TimeLimit")

  let rowCount = getS32("RowCount").int
  for rowIndex in 0 ..< rowCount:
    level.rows.add($getString("Row" & $rowIndex))
  if level.rows.len == 0:
    echo "Level ", section, " has no rows"
    return false

  let width = level.rows[0].len
  for i, row in level.rows:
    if row.len != width:
      echo "Level ", section, " row ", i, " has width ", row.len,
           " instead of ", width
      return false
  result = true

proc cellWorld*(x, y: int): orxVECTOR =
  ## World position of the center of a cell; the cave is centered at 0,0.
  newVector(worldMinX + (x.float32 + 0.5'f32) * CellSize,
            worldMinY + (y.float32 + 0.5'f32) * CellSize, 0.0)

proc cellOf*(position: orxVECTOR): tuple[x, y: int] =
  ## Cave cell coordinates containing a world position.
  result = (int((position.fX - worldMinX) / CellSize),
            int((position.fY - worldMinY) / CellSize))

proc cellIndex(x, y: int): int = y * worldW + x

proc objectKind*(gameObject: ptr orxOBJECT): string =
  ## Config section the object was created from.
  if gameObject == nil:
    return ""
  $getName(gameObject)

proc removeTracked(gameObject: ptr orxOBJECT) =
  for tracking in [addr world.boulders, addr world.gems, addr world.dirts]:
    let index = tracking[].find(gameObject)
    if index >= 0:
      tracking[].delete(index)

proc destroyObject*(gameObject: ptr orxOBJECT) =
  if gameObject == nil:
    return
  removeTracked(gameObject)
  destroyedObjects.incl(cast[pointer](gameObject))
  discard objectDelete(gameObject)

proc clearDestroyed*() =
  ## Starts a fresh destruction cycle; called once per frame before the
  ## contact queue is drained.
  destroyedObjects.clear()

proc isDestroyed*(gameObject: ptr orxOBJECT): bool =
  ## Has this object been destroyed during the current frame? Protects
  ## contact handling from dereferencing freed ORX objects.
  result = gameObject == nil or cast[pointer](gameObject) in destroyedObjects

proc spawnBurst*(configName: string; position: orxVECTOR; count = 3) =
  ## Spawns a few short-lived particles.
  for _ in 0 ..< count:
    let puff = objectCreateFromConfig(configName)
    if puff != nil:
      discard puff.setPosition(position)

proc destroySmallSand*(gameObject: ptr orxOBJECT) =
  ## Digs out a fine sand block: dust, sound and score.
  if gameObject == nil:
    return
  let position = gameObject.getWorldPosition()
  spawnBurst("DustPuff", position, 2)
  # Unlink from the owning cell so later passes never see a stale pointer.
  let (cx, cy) = cellOf(position)
  if cx >= 0 and cx < worldW and cy >= 0 and cy < worldH:
    var cell = addr sandCells[cellIndex(cx, cy)]
    for i in 0 ..< cell.subs.len:
      if cell.subs[i] == gameObject:
        cell.subs[i] = nil
  if player != nil and gs.worldClockTime - gs.lastDig >= 0.11'f32:
    gs.lastDig = gs.worldClockTime
    discard player.addSound("DigSound")
  destroyObject(gameObject)
  gs.dirtDug += 1
  addScore(gs.digScore)
  gs.hudDirty = true

proc refineSand*(gameObject: ptr orxOBJECT) =
  ## Replaces a 32px sand block by nine fine blocks at the same spot.
  if gameObject == nil:
    return
  let (cx, cy) = cellOf(gameObject.getWorldPosition())
  if cx < 0 or cx >= worldW or cy < 0 or cy >= worldH:
    return
  var cell = addr sandCells[cellIndex(cx, cy)]
  if cell.refined or cell.big != gameObject:
    return
  let center = cellWorld(cx, cy)
  destroyObject(cell.big)
  cell.big = nil
  for i, offset in SubOffsets:
    let sub = objectCreateFromConfig("SandFine")
    if sub != nil:
      discard sub.setPosition(
        newVector(center.fX + offset.x, center.fY + offset.y, 0.0))
      dirts.add(sub)
      cell.subs[i] = sub
  cell.refined = true

proc digSand*(gameObject: ptr orxOBJECT) =
  ## Contact-triggered digging: refine big blocks, destroy fine ones.
  case objectKind(gameObject)
  of "Sand32": refineSand(gameObject)
  of "SandFine": destroySmallSand(gameObject)
  else: discard

proc digAround*(origin: orxVECTOR; dirX, dirY: float32) =
  ## Digs/refines sand immediately ahead of the player's movement.
  ## Fine 10.67px blocks in the dig path are removed; 32px blocks swapped.
  ## Only the cells near the player are considered (windowed for speed);
  ## static cell centers are precomputed at build time.
  let (playerCellX, playerCellY) = cellOf(origin)
  for cy in max(0, playerCellY - 2) .. min(worldH - 1, playerCellY + 2):
    for cx in max(0, playerCellX - 2) .. min(worldW - 1, playerCellX + 2):
      var cell = addr sandCells[cellIndex(cx, cy)]
      if cell.refined:
        for i, sub in cell.subs:
          if sub == nil:
            continue
          let
            dx = cell.center.fX + SubOffsets[i].x - origin.fX
            dy = cell.center.fY + SubOffsets[i].y - origin.fY
          let horizontal = dirX != 0.0 and dx * dirX > 0.0 and
                           abs(dx) < 30.0 and abs(dy) < 17.0
          let vertical = dirY != 0.0 and dy * dirY > 0.0 and
                         abs(dx) < 17.0 and abs(dy) < 30.0
          if horizontal or vertical:
            destroySmallSand(sub)
      elif cell.big != nil:
        let dx = cell.center.fX - origin.fX
        let dy = cell.center.fY - origin.fY
        let near = (dirX != 0.0 and abs(dx) < 33.0 and abs(dy) < 24.0) or
                   (dirY != 0.0 and abs(dx) < 24.0 and abs(dy) < 33.0)
        if near:
          refineSand(cell.big)

proc collectGem*(gem: ptr orxOBJECT) =
  ## Picks up a diamond: score, sparkle, and exit bookkeeping.
  if world.gems.find(gem) < 0:
    return
  let position = gem.getWorldPosition()
  spawnBurst("GemSparkle", position, 3)
  if player != nil:
    discard player.addSound("CollectSound")
    discard player.addFX("CollectFlash")
  destroyObject(gem)
  gs.collected += 1
  addScore(gs.diamondScore)
  gs.hudDirty = true

proc openExit*() =
  if gs.exitOpen or exitObject == nil:
    return
  gs.exitOpen = true
  discard exitObject.addFX("ExitOpenFX")
  if player != nil:
    discard player.addSound("ExitOpenSound")

proc spawnBoulderAt*(cx, cy: int): ptr orxOBJECT =
  ## Spawns an extra boulder (also used by the startup test).
  result = objectCreateFromConfig("Boulder")
  if result != nil:
    discard result.setPosition(cellWorld(cx, cy))
    world.boulders.add(result)

proc clearWorld*() =
  ## Deletes every spawned object. The concatenated copy is needed because
  ## destruction removes objects from these very sequences.
  var pass = newSeqOfCap[ptr orxOBJECT](
    boulders.len + gems.len + dirts.len)
  pass.add(boulders)
  pass.add(gems)
  pass.add(dirts)
  for gameObject in pass:
    destroyObject(gameObject)
  boulders.setLen(0)
  gems.setLen(0)
  dirts.setLen(0)
  sandCells.setLen(0)
  walls.setLen(0)
  pendingCreatures.setLen(0)
  destroyObject(exitObject)
  exitObject = nil
  destroyObject(player)
  player = nil

proc buildWorld(level: LevelDef): bool =
  ## Instantiates all level objects from a parsed definition.
  gs.gemTotal = 0
  worldH = level.rows.len
  worldW = level.rows[0].len
  worldMinX = -worldW.float32 * CellSize * 0.5'f32
  worldMaxX = -worldMinX
  worldMinY = -worldH.float32 * CellSize * 0.5'f32
  worldMaxY = -worldMinY
  sandCells = newSeq[SandCell](worldW * worldH)
  walls = newSeq[bool](worldW * worldH)

  var playerCount, exitCount = 0
  for y, row in level.rows:
    for x, symbol in row:
      let position = cellWorld(x, y)
      case symbol
      of '#':
        walls[cellIndex(x, y)] = true
        let wall = objectCreateFromConfig("Wall")
        if wall == nil or wall.setPosition(position).isFailure:
          echo "Could not create a wall at ", x, ",", y
          return false
      of '.':
        let sand = objectCreateFromConfig("Sand32")
        if sand == nil or sand.setPosition(position).isFailure:
          echo "Could not create sand at ", x, ",", y
          return false
        dirts.add(sand)
        sandCells[cellIndex(x, y)].big = sand
        sandCells[cellIndex(x, y)].center = position
      of 'o', 'O', 'Q':
        let configName =
          (if symbol == 'o': "BoulderSmall"
           elif symbol == 'Q': "BoulderBig" else: "Boulder")
        let boulder = objectCreateFromConfig(configName)
        if boulder == nil or boulder.setPosition(position).isFailure:
          echo "Could not create a boulder at ", x, ",", y
          return false
        boulders.add(boulder)
      of 'D':
        let gem = objectCreateFromConfig("Diamond")
        if gem == nil or gem.setPosition(position).isFailure:
          echo "Could not create a diamond at ", x, ",", y
          return false
        discard gem.addFX("SparkleFX")
        gems.add(gem)
        inc gs.gemTotal
      of 'E':
        exitObject = objectCreateFromConfig("Exit")
        if exitObject == nil or exitObject.setPosition(position).isFailure:
          echo "Could not create the exit"
          return false
        inc exitCount
      of 'f', 'b':
        pendingCreatures.add((config: (if symbol == 'f': "Firefly"
                                       else: "Butterfly"), x: x, y: y))
      of '@':
        playerSpawnX = x
        playerSpawnY = y
        inc playerCount
      of ' ':
        discard
      else:
        echo "Unknown level symbol '", symbol, "' at ", x, ",", y
        return false

  if playerCount != 1 or exitCount != 1:
    echo "Levels need exactly one player and one exit, got ",
         playerCount, " and ", exitCount
    return false
  if gs.gemTotal < level.needed:
    echo "Level has not enough diamonds"
    return false

  player = objectCreateFromConfig("Player")
  if player == nil:
    echo "Could not create the player"
    return false
  result = player.setPosition(cellWorld(playerSpawnX, playerSpawnY)).isSuccess

proc loadWorld*(index: int): bool =
  ## Parses and instantiates a level, replacing the current world.
  clearWorld()
  var level: LevelDef
  if not readLevel(index, level):
    return false

  gs.levelName = level.name
  gs.needed = level.needed
  gs.collected = 0
  gs.levelTimeLimit = level.timeLimit
  gs.timeLeft = level.timeLimit
  gs.exitOpen = false
  gs.levelCompleted = false
  gs.hudDirty = true

  result = buildWorld(level)

proc validateLevels*(): bool =
  ## Config-only sanity check used by the startup test.
  for i in 0 ..< gs.levelCount:
    var level: LevelDef
    if not readLevel(i, level):
      echo "Startup check failed: reading level ", i + 1
      return false

    var players, exits, gemCount = 0
    for row in level.rows:
      for symbol in row:
        case symbol
        of '@': inc players
        of 'E': inc exits
        of 'D': inc gemCount
        of ' ', '#', '.', 'o', 'O', 'Q', 'f', 'b': discard
        else:
          echo "Startup check failed: unknown symbol '", symbol,
               "' in level ", i + 1
          return false
    if players != 1 or exits != 1 or gemCount < level.needed:
      echo "Startup check failed: invalid counts in level ", i + 1
      return false
  result = true

proc exitReachable*(): bool =
  exitObject != nil
