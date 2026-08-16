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
  LevelDef* = object
    ## Parsed level data before instantiation.
    name*: string
    needed*: int
    timeLimit*: float32
    rows*: seq[string]

  SandCell* = object
    ## One 32px cave cell either holding a big block or sixteen refined
    ## 8px grains (4x4 subdivision).
    big*: ptr orxOBJECT
    refined*: bool
    center*: orxVECTOR

  Player* = object
    ## One hero: physics object, spawn point and per-player state.
    ## Single-player runs use players[0]; the multiplayer fields
    ## (lives/down/respawn) are wired up by the game modes in later
    ## phases.
    obj*: ptr orxOBJECT
    index*: int
    inputSet*: string
    spawnX*, spawnY*: int
    lives*: int
    deathReason*: string
    respawnTimer*: float32
    invulnTimer*: float32
    currentAnim*: string
    digAnimTimer*: float32
    digFlip*: bool
    down*: bool ## out of lives for the run (spectating)

const
  ## Sub-grid size per cell (4x4) and block size in pixels.
  SubGrid* = 4
  SubBlock* = CellSize / SubGrid.float32
  ## Maximum grains that may become loose simultaneously (--sand option).
  MaxLooseGrains = 300

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
  fineGrains*: seq[ptr orxOBJECT]
  ## Every live 8px sand grain, in one flat list. Grains are dynamic only
  ## after a boulder activates them (see activateGrainColumn), so this is
  ## the single source of truth for digging - never stale pointers.
  grainCounts*: seq[int]
  ## Per-cell live grain counts (creature steering hint).
  walls*: seq[bool]
  wallObjects: seq[ptr orxOBJECT]
  pendingCreatures*: seq[tuple[config: string, x, y: int]]
  players*: seq[Player]
  exitObject*: ptr orxOBJECT
  boulders*: seq[ptr orxOBJECT]
  gems*: seq[ptr orxOBJECT]
  dirts*: seq[ptr orxOBJECT]
  playerSpawns*: seq[tuple[x, y: int]]

var
  destroyedObjects: HashSet[pointer]
  pendingDeletes: seq[ptr orxOBJECT]
  dugThisFrame*: int
  ## Number of fine sand blocks actually dug out during the current frame
  ## (reset by the caller; used to trigger the dig animation).
  digDustFlip = false
  ## Alternates so dust bursts appear on ~50% of dug blocks.
  looseSandEnabled* = false
  ## Opt-in experimental loose sand (--sand): boulders turn pressed sand
  ## grains dynamic so they give way.
  looseGrainCount = 0

proc playerObj*(): ptr orxOBJECT =
  ## The first hero's physics object (single-player semantics), nil when
  ## no hero exists.
  if players.len > 0:
    players[0].obj
  else:
    nil

proc playerOf*(gameObject: ptr orxOBJECT): int =
  ## Index of the player owning `gameObject`, -1 when it is no hero.
  result = -1
  for index, hero in players:
    if hero.obj == gameObject:
      return index

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

const
  ## Render Z for entities that must draw above the sand lattice (the big
  ## boulders spill into neighbor cells and would otherwise be covered).
  BoulderZ* = 0.5'f32
  GemZ* = 0.5'f32
  CreatureZ* = 0.5'f32
  ExitZ* = 0.4'f32
  PlayerZ* = 0.6'f32

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

proc structureValid(gameObject: ptr orxOBJECT): bool =
  ## Cheap validity check on an ORX object pointer: its structure GUID
  ## must still identify a live structure (freed memory gets reused with
  ## the deleted magic tag or another structure id).
  if gameObject == nil:
    return false
  let guid = cast[ptr orxSTRUCTURE](gameObject).u64GUID
  result = (guid and STRUCTURE_GUID_MASK_STRUCTURE_ID) <
      STRUCTURE_ID_NUMBER.uint64 and
      guid != STRUCTURE_GUID_MAGIC_TAG_DELETED

proc removeTracked(gameObject: ptr orxOBJECT) =
  for tracking in [addr world.boulders, addr world.gems, addr world.dirts]:
    let index = tracking[].find(gameObject)
    if index >= 0:
      tracking[].delete(index)

proc destroyObject*(gameObject: ptr orxOBJECT) =
  ## Marks an object destroyed: untracked immediately, removed from the
  ## physics world at end of frame. The actual `objectDelete` is deferred
  ## so addresses of freshly created objects can never alias objects
  ## destroyed earlier in the same frame (pointer-reuse false positives
  ## on the tombstone set).
  if gameObject == nil:
    return
  if not structureValid(gameObject):
    # A stale pointer reached the teardown path. Log the offender and
    # scrub it from tracking lists instead of crashing ORX.
    var where = ""
    if world.boulders.find(gameObject) >= 0:
      where.add(" boulders")
    if world.gems.find(gameObject) >= 0:
      where.add(" gems")
    if world.dirts.find(gameObject) >= 0:
      where.add(" dirts")
    if wallObjects.find(gameObject) >= 0:
      where.add(" walls")
    echo "Stale ORX object ", cast[uint](gameObject), " in:", where
    removeTracked(gameObject)
    return
  if cast[pointer](gameObject) in destroyedObjects:
    return
  removeTracked(gameObject)
  destroyedObjects.incl(cast[pointer](gameObject))
  pendingDeletes.add(gameObject)

proc flushDestroyed*() =
  ## End-of-frame: deletes objects marked during the frame and clears the
  ## tombstone set. Called once per frame, after the contact queue has
  ## been drained and game logic has run.
  for gameObject in pendingDeletes:
    discard objectDelete(gameObject)
  pendingDeletes.setLen(0)
  destroyedObjects.clear()

proc isDestroyed*(gameObject: ptr orxOBJECT): bool =
  ## Has this object been destroyed during the current frame? Protects
  ## contact handling from dereferencing freed ORX objects. Also returns
  ## true for structurally invalid pointers (freed or reused memory).
  result = gameObject == nil or cast[pointer](gameObject) in destroyedObjects or
           not structureValid(gameObject)

proc spawnBurst*(configName: string; position: orxVECTOR; count = 3) =
  ## Spawns a few short-lived particles.
  for _ in 0 ..< count:
    let puff = objectCreateFromConfig(configName)
    if puff != nil:
      discard puff.setPosition(position)

proc killPlayer*(index: int; reason: string): bool =
  ## Applies a death to one hero: loses a life, respawns at the spawn
  ## cell after a short delay with invulnerability; at zero lives the
  ## hero is out of the run (spectating). Returns true when the death
  ## was actually applied (false while invulnerable or already dying).
  if index < 0 or index >= players.len:
    return false
  var hero = addr players[index]
  if hero.obj == nil or hero.down or hero.respawnTimer > 0.0 or
      hero.invulnTimer > 0.0:
    return false
  result = true
  dec hero.lives
  hero.deathReason = reason
  gs.runLives[index] = hero.lives
  gs.shake = 9.0
  gs.hudDirty = true
  if hero.lives > 0:
    hero.respawnTimer = DyingTime
    hero.invulnTimer = InvulnTime
    discard hero.obj.addSound("LoseSound")
  else:
    hero.down = true
    gs.runDown[index] = true
    discard hero.obj.addSound("LoseSound")
    destroyObject(hero.obj)
    hero.obj = nil

proc cellBlocked(x, y: int): bool =
  ## True when a cell can't be used for respawn: wall, big sand block,
  ## or live refined grains.
  if x < 0 or x >= worldW or y < 0 or y >= worldH:
    return true
  let index = cellIndex(x, y)
  walls[index] or sandCells[index].big != nil or grainCounts[index] > 0

proc freeRespawnSpot(index: int): orxVECTOR =
  ## The hero's spawn cell, or the nearest free cell around it when the
  ## spawn is blocked (sand) or occupied by another hero - respawning on
  ## top of a teammate makes the sprites overlap and looks like the
  ## wrong color.
  let hero = players[index]
  var spot = cellWorld(hero.spawnX, hero.spawnY)
  let occupied = proc(x, y: int): bool =
    result = false
    for other in players:
      if other.index == index or other.obj == nil or other.down:
        continue
      let position = other.obj.getWorldPosition()
      if abs(position.fX - cellWorld(x, y).fX) < 24.0 and
          abs(position.fY - cellWorld(x, y).fY) < 24.0:
        return true
  if not occupied(hero.spawnX, hero.spawnY):
    return spot
  # Search in expanding rings around the spawn cell.
  for ring in 1 .. 4:
    for dy in -ring .. ring:
      for dx in -ring .. ring:
        if max(abs(dx), abs(dy)) != ring:
          continue
        let (x, y) = (hero.spawnX + dx, hero.spawnY + dy)
        if cellBlocked(x, y) or occupied(x, y):
          continue
        return cellWorld(x, y)
  spot

proc respawnPlayer*(index: int) =
  ## Teleports a hero back to its spawn cell (invulnerability was granted
  ## when the death happened) and re-applies its config color.
  if index < 0 or index >= players.len:
    return
  let hero = addr players[index]
  if hero.obj == nil or hero.down:
    return
  hero.respawnTimer = 0.0
  let position = freeRespawnSpot(index)
  discard hero.obj.setWorldPosition(
    newVector(position.fX, position.fY, PlayerZ))
  spawnBurst("GemSparkle", position, 3)

proc destroySmallSand*(gameObject: ptr orxOBJECT;
                       digger: ptr orxOBJECT = nil) =
  ## Digs out a fine sand grain: dust, sound and score. The dig sound is
  ## attributed to the digging hero.
  if gameObject == nil or isDestroyed(gameObject):
    return
  var digger = digger
  if digger == nil:
    digger = playerObj()
  let position = gameObject.getWorldPosition()
  # Every other dug grain kicks up dust, so digging isn't a dust storm.
  digDustFlip = not digDustFlip
  if digDustFlip:
    spawnBurst("DustPuff", position, 1)
  # Unlink from the flat list and the cell counter.
  let index = fineGrains.find(gameObject)
  if index >= 0:
    fineGrains.delete(index)
  let (cx, cy) = cellOf(position)
  if cx >= 0 and cx < worldW and cy >= 0 and cy < worldH:
    let countIndex = cellIndex(cx, cy)
    if grainCounts[countIndex] > 0:
      dec grainCounts[countIndex]
  if digger != nil and gs.worldClockTime - gs.lastDig >= 0.11'f32:
    gs.lastDig = gs.worldClockTime
    discard digger.addSound("DigSound")
  destroyObject(gameObject)
  gs.dirtDug += 1
  dugThisFrame += 1
  gs.hudDirty = true

proc refineSand*(gameObject: ptr orxOBJECT) =
  ## Replaces a 32px sand block by sixteen fine grains at the same spot.
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
  for offset in SubOffsets:
    let sub = objectCreateFromConfig("SandFine")
    if sub != nil:
      discard sub.setPosition(
        newVector(center.fX + offset.x, center.fY + offset.y, 0.0))
      fineGrains.add(sub)
      inc grainCounts[cellIndex(cx, cy)]
  cell.refined = true

proc activateGrainColumn*(grain: ptr orxOBJECT) =
  ## A boulder presses on this fine grain: the grains around the contact
  ## turn dynamic so they can give way - the column above the contact
  ## (the pile wedged by the boulder) plus a cone below (repose-angle
  ## failure). Only active with --sand; otherwise grains stay static.
  ## The number of loose grains is capped so collapses can't cascade into
  ## a physics meltdown.
  if not looseSandEnabled:
    return
  if looseGrainCount >= MaxLooseGrains:
    return
  if grain == nil or isDestroyed(grain):
    return
  let (cx, cy) = cellOf(grain.getWorldPosition())
  if cx < 0 or cx >= worldW or cy < 0 or cy >= worldH:
    return
  for candidate in fineGrains:
    if isDestroyed(candidate):
      continue
    let (gx, gy) = cellOf(candidate.getWorldPosition())
    let below = gy - cy
    if below < -3 or below > 3:
      continue
    # Widening cone below the contact, pure column above it.
    let maxSpread = (if below > 0: min(below, 2) else: 0)
    if abs(gx - cx) > maxSpread:
      continue
    let body = cast[ptr orxBODY](
      internal_orxObject_GetStructure(candidate, STRUCTURE_ID_BODY))
    if body != nil and isDynamic(body) == orxFALSE:
      discard setDynamic(body, orxTRUE)
      discard candidate.setSpeed(newVector(0.0, 2.0, 0.0))
      inc looseGrainCount
      if looseGrainCount >= MaxLooseGrains:
        return

proc digSand*(gameObject: ptr orxOBJECT; digger: ptr orxOBJECT = nil) =
  ## Contact-triggered digging: refine big blocks, destroy fine ones.
  case objectKind(gameObject)
  of "Sand32": refineSand(gameObject)
  of "SandFine": destroySmallSand(gameObject, digger)
  else: discard

proc digAround*(origin: orxVECTOR; dirX, dirY: float32;
                digger: ptr orxOBJECT = nil) =
  ## Digs/refines sand immediately ahead of the player's movement.
  ## Fine grains in the dig path are removed (using their live position);
  ## 32px blocks are swapped for grains first. Only cells near the player
  ## are considered (windowed for speed).
  let (playerCellX, playerCellY) = cellOf(origin)
  # Fine grains near the player (snapshot: digging mutates fineGrains)
  var nearGrains: seq[ptr orxOBJECT]
  for grain in fineGrains:
    if grain == nil or isDestroyed(grain):
      continue
    let position = grain.getWorldPosition()
    if abs(position.fX - origin.fX) < 100.0 and
        abs(position.fY - origin.fY) < 100.0:
      nearGrains.add(grain)
  for grain in nearGrains:
    if isDestroyed(grain):
      continue
    let position = grain.getWorldPosition()
    let dx = position.fX - origin.fX
    let dy = position.fY - origin.fY
    let horizontal = dirX != 0.0 and dx * dirX > 0.0 and
                     abs(dx) < 33.0 and abs(dy) < 17.0
    let vertical = dirY != 0.0 and dy * dirY > 0.0 and
                   abs(dx) < 17.0 and abs(dy) < 33.0
    if horizontal or vertical:
      destroySmallSand(grain)

  for cy in max(0, playerCellY - 2) .. min(worldH - 1, playerCellY + 2):
    for cx in max(0, playerCellX - 2) .. min(worldW - 1, playerCellX + 2):
      var cell = addr sandCells[cellIndex(cx, cy)]
      if cell.big != nil:
        let dx = cell.center.fX - origin.fX
        let dy = cell.center.fY - origin.fY
        let near = (dirX != 0.0 and abs(dx) < 33.0 and abs(dy) < 24.0) or
                   (dirY != 0.0 and abs(dx) < 24.0 and abs(dy) < 33.0)
        if near:
          refineSand(cell.big)

proc collectGem*(gem: ptr orxOBJECT; collector: ptr orxOBJECT = nil) =
  ## Picks up a diamond: score, sparkle, and exit bookkeeping. The
  ## collect sound/flash are attributed to the touching hero.
  if world.gems.find(gem) < 0:
    when defined(debugContacts):
      echo "COLLECT skip: gem not tracked"
    return
  when defined(debugContacts):
    echo "COLLECT gem at ", gem.getWorldPosition().fX, ",",
         gem.getWorldPosition().fY
  let position = gem.getWorldPosition()
  spawnBurst("GemSparkle", position, 3)
  var collector = collector
  if collector == nil:
    collector = playerObj()
  if collector != nil:
    discard collector.addSound("CollectSound")
    discard collector.addFX("CollectFlash")
  destroyObject(gem)
  gs.collected += 1
  addScore(gs.diamondScore)
  gs.hudDirty = true

proc openExit*() =
  if gs.exitOpen or exitObject == nil:
    return
  gs.exitOpen = true
  discard exitObject.addFX("ExitOpenFX")
  let hero = playerObj()
  if hero != nil:
    discard hero.addSound("ExitOpenSound")

proc spawnBoulderAt*(cx, cy: int): ptr orxOBJECT =
  ## Spawns an extra boulder (also used by the startup test).
  result = objectCreateFromConfig("Boulder")
  if result != nil:
    discard result.setPosition(cellWorld(cx, cy))
    world.boulders.add(result)

proc clearWorld*() =
  ## Deletes every spawned object. The concatenated copy is deduplicated
  ## (a pointer could live in several tracking lists) because destruction
  ## removes objects from these very sequences.
  var pass = newSeqOfCap[ptr orxOBJECT](
    boulders.len + gems.len + dirts.len + wallObjects.len)
  var seen = initHashSet[pointer]()
  for batch in [boulders, gems, dirts, wallObjects]:
    for gameObject in batch:
      if cast[pointer](gameObject) in seen:
        continue
      seen.incl(cast[pointer](gameObject))
      pass.add(gameObject)
  for gameObject in pass:
    destroyObject(gameObject)
  # Fine grains aren't in the teardown lists - destroy them explicitly
  # so no bodies leak into the next cave.
  for grain in fineGrains:
    destroyObject(grain)
  boulders.setLen(0)
  gems.setLen(0)
  dirts.setLen(0)
  fineGrains.setLen(0)
  grainCounts.setLen(0)
  sandCells.setLen(0)
  walls.setLen(0)
  pendingCreatures.setLen(0)
  destroyObject(exitObject)
  exitObject = nil
  for hero in players:
    destroyObject(hero.obj)
  players.setLen(0)
  playerSpawns.setLen(0)

proc spawnPlayers*(): bool =
  ## Instantiates one hero object per joined player (`gs.playerCount`)
  ## using the first spawn points of the level.
  if playerSpawns.len < gs.playerCount:
    echo "Level has ", playerSpawns.len, " spawns for ",
         gs.playerCount, " players"
    return false
  for index in 0 ..< gs.playerCount:
    let spawnPoint = playerSpawns[index]
    let configName =
      (if index == 0: "Player" else: "Player" & $(index + 1))
    let hero = objectCreateFromConfig(configName)
    if hero == nil:
      echo "Could not create the player"
      return false
    let position = cellWorld(spawnPoint.x, spawnPoint.y)
    if hero.setPosition(
        newVector(position.fX, position.fY, PlayerZ)).isFailure:
      return false
    players.add(Player(
      obj: hero,
      index: index,
      inputSet: (if index == 0: "P1" else: "P" & $(index + 1)),
      spawnX: spawnPoint.x,
      spawnY: spawnPoint.y,
      lives: gs.runLives[index],
      down: gs.runDown[index]))
  result = true

proc buildWorld(level: LevelDef): bool =
  ## Instantiates all level objects from a parsed definition.
  var gemCount = 0
  worldH = level.rows.len
  worldW = level.rows[0].len
  worldMinX = -worldW.float32 * CellSize * 0.5'f32
  worldMaxX = -worldMinX
  worldMinY = -worldH.float32 * CellSize * 0.5'f32
  worldMaxY = -worldMinY
  sandCells = newSeq[SandCell](worldW * worldH)
  grainCounts = newSeq[int](worldW * worldH)
  fineGrains.setLen(0)
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
        wallObjects.add(wall)
      of '.':
        let sand = objectCreateFromConfig("Sand32")
        if sand == nil or sand.setPosition(position).isFailure:
          echo "Could not create sand at ", x, ",", y
          return false
        dirts.add(sand)
        sandCells[cellIndex(x, y)].big = sand
        sandCells[cellIndex(x, y)].center = position
      of 'o', 'O', 'Q', 'R':
        let configName =
          (if symbol == 'o': "BoulderSmall"
           elif symbol == 'Q': "BoulderBig"
           elif symbol == 'R': "BoulderHuge"
           else: "Boulder")
        let boulder = objectCreateFromConfig(configName)
        if boulder == nil or
            boulder.setPosition(
              newVector(position.fX, position.fY, BoulderZ)).isFailure:
          echo "Could not create a boulder at ", x, ",", y
          return false
        boulders.add(boulder)
      of 'D':
        let gem = objectCreateFromConfig("Diamond")
        if gem == nil or
            gem.setPosition(
              newVector(position.fX, position.fY, GemZ)).isFailure:
          echo "Could not create a diamond at ", x, ",", y
          return false
        discard gem.addFX("SparkleFX")
        gems.add(gem)
        inc gemCount
      of 'E':
        exitObject = objectCreateFromConfig("Exit")
        if exitObject == nil or
            exitObject.setPosition(
              newVector(position.fX, position.fY, ExitZ)).isFailure:
          echo "Could not create the exit"
          return false
        inc exitCount
      of 'f', 'b':
        pendingCreatures.add((config: (if symbol == 'f': "Firefly"
                                       else: "Butterfly"), x: x, y: y))
      of '@', '2', '3', '4':
        playerSpawns.add((x: x, y: y))
        inc playerCount
      of ' ':
        discard
      else:
        echo "Unknown level symbol '", symbol, "' at ", x, ",", y
        return false

  if playerCount < 1 or playerCount > 4 or exitCount != 1:
    echo "Levels need 1-4 player spawns and one exit, got ",
         playerCount, " and ", exitCount
    return false
  if gemCount < level.needed:
    echo "Level has not enough diamonds"
    return false

  result = spawnPlayers()

proc loadWorld*(index: int): bool =
  ## Parses and instantiates a level, replacing the current world.
  clearWorld()
  var level: LevelDef
  if not readLevel(index, level):
    return false

  gs.levelName = level.name
  gs.needed = level.needed
  gs.collected = 0
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

    var spawnCount, exits, gemCount = 0
    for row in level.rows:
      for symbol in row:
        case symbol
        of '@', '2', '3', '4': inc spawnCount
        of 'E': inc exits
        of 'D': inc gemCount
        of ' ', '#', '.', 'o', 'O', 'Q', 'R', 'f', 'b': discard
        else:
          echo "Startup check failed: unknown symbol '", symbol,
               "' in level ", i + 1
          return false
    if spawnCount < 1 or spawnCount > 4 or exits != 1 or
        gemCount < level.needed:
      echo "Startup check failed: invalid counts in level ", i + 1
      return false
  result = true
