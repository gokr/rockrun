## World management for Rockrun: level parsing, spawning, digging,
## collecting, and destruction of ORX objects with physics bodies.
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

var
  worldW*, worldH*: int
  worldMinX*, worldMaxX*, worldMinY*, worldMaxY*: float32
  cells*: seq[CellKind]
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
  when defined(debugLevels):
    echo "Level ", section, " rowCount=", level.rows.len,
         " first row=[", level.rows[0], "]"

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

proc destroyObject(gameObject: ptr orxOBJECT) =
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

proc cellIndex(x, y: int): int = y * worldW + x

proc destroyDirt*(dirt: ptr orxOBJECT; sound = true) =
  let position = dirt.getWorldPosition()
  spawnBurst("DustPuff", position, 2)
  if sound and player != nil and
      gs.worldClockTime - gs.lastDig >= 0.11'f32:
    gs.lastDig = gs.worldClockTime
    discard player.addSound("DigSound")
  destroyObject(dirt)
  gs.dirtDug += 1
  addScore(gs.digScore)

proc digAround*(origin: orxVECTOR; dirX, dirY: float32) =
  ## Digs dirt immediately ahead of the player's movement direction.
  ## The dynamic player body is a bit smaller than the grid, so the reach
  ## threshold of 31 units makes a push dig right before contact while the
  ## floor underneath (a full cell away, 32 units) stays in place until the
  ## player actively burrows down.
  for i in countdown(dirts.high, 0):
    let position = dirts[i].getWorldPosition()
    let dx = position.fX - origin.fX
    let dy = position.fY - origin.fY
    let horizontal = dirX != 0.0 and dx * dirX > 0.0 and
                     abs(dx) < 31.0 and abs(dy) < 22.0
    let vertical = dirY != 0.0 and dy * dirY > 0.0 and
                   abs(dx) < 22.0 and abs(dy) < 31.0
    if horizontal or vertical:
      destroyDirt(dirts[i])

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
  destroyObject(exitObject)
  exitObject = nil
  destroyObject(player)
  player = nil
  cells.setLen(0)

proc buildWorld(level: LevelDef): bool =
  ## Instantiates all level objects from a parsed definition.
  gs.gemTotal = 0
  worldH = level.rows.len
  worldW = level.rows[0].len
  worldMinX = -worldW.float32 * CellSize * 0.5'f32
  worldMaxX = -worldMinX
  worldMinY = -worldH.float32 * CellSize * 0.5'f32
  worldMaxY = -worldMinY
  cells = newSeq[CellKind](worldW * worldH)

  var playerCount, exitCount = 0
  for y, row in level.rows:
    for x, symbol in row:
      let position = cellWorld(x, y)
      case symbol
      of '#':
        cells[cellIndex(x, y)] = cWall
        let wall = objectCreateFromConfig("Wall")
        if wall == nil or wall.setPosition(position).isFailure:
          echo "Could not create a wall at ", x, ",", y
          return false
      of '.':
        cells[cellIndex(x, y)] = cDirt
        let dirt = objectCreateFromConfig("Dirt")
        if dirt == nil or dirt.setPosition(position).isFailure:
          echo "Could not create dirt at ", x, ",", y
          return false
        dirts.add(dirt)
      of 'O':
        cells[cellIndex(x, y)] = cBoulder
        let boulder = objectCreateFromConfig("Boulder")
        if boulder == nil or boulder.setPosition(position).isFailure:
          echo "Could not create a boulder at ", x, ",", y
          return false
        boulders.add(boulder)
      of 'D':
        cells[cellIndex(x, y)] = cGem
        let gem = objectCreateFromConfig("Diamond")
        if gem == nil or gem.setPosition(position).isFailure:
          echo "Could not create a diamond at ", x, ",", y
          return false
        discard gem.addFX("SparkleFX")
        gems.add(gem)
        inc gs.gemTotal
      of 'E':
        cells[cellIndex(x, y)] = cExit
        exitObject = objectCreateFromConfig("Exit")
        if exitObject == nil or exitObject.setPosition(position).isFailure:
          echo "Could not create the exit"
          return false
        inc exitCount
      of '@':
        cells[cellIndex(x, y)] = cEmpty
        playerSpawnX = x
        playerSpawnY = y
        inc playerCount
      of ' ':
        cells[cellIndex(x, y)] = cEmpty
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

  player = objectCreateFromConfig(
    (if defined(testBoulderPlayer): "Boulder" else: "Player"))
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
        of ' ', '#', '.', 'O': discard
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
