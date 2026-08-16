## Physics contact handling for Rockrun.
##
## ORX dispatches physics contact events while Box2D is stepping; bodies
## must not be destroyed from inside those callbacks, so contacts are only
## recorded here and drained later once per frame.
import strutils
import strformat
import norx
import game
import world
import creatures
import ui

type
  Contact = object
    first: ptr orxOBJECT
    second: ptr orxOBJECT
    position: orxVECTOR
    normal: orxVECTOR

  ObjKind = enum
    kOther
    kPlayer
    kBoulder
    kDiamond
    kDirt
    kWall
    kExit
    kCreature

var
  pendingContacts: seq[Contact]

proc physicsEventHandler(event: ptr orxEVENT): orxSTATUS {.cdecl.} =
  ## Queues contact events without touching any bodies.
  if event.eID != ord(PHYSICS_EVENT_CONTACT_ADD):
    return STATUS_SUCCESS
  when defined(debugContacts):
    if cast[ptr orxOBJECT](event.hRecipient) != nil and
        cast[ptr orxOBJECT](event.hSender) != nil:
      echo "CONTACT_ADD ", objectKind(cast[ptr orxOBJECT](event.hRecipient)),
           " vs ", objectKind(cast[ptr orxOBJECT](event.hSender))
  let
    recipient = cast[ptr orxOBJECT](event.hRecipient)
    sender = cast[ptr orxOBJECT](event.hSender)
  if recipient == nil or sender == nil:
    return STATUS_SUCCESS
  var contact = Contact(first: recipient, second: sender)
  if event.pstPayload != nil:
    let payload = cast[ptr orxPHYSICS_EVENT_PAYLOAD](event.pstPayload)
    contact.position = payload.vPosition
    contact.normal = payload.vNormal
  pendingContacts.add(contact)
  result = STATUS_SUCCESS

proc registerContactHandler*(): orxSTATUS =
  addHandler(EVENT_TYPE_PHYSICS, physicsEventHandler)

proc unregisterContactHandler*(): orxSTATUS =
  removeHandler(EVENT_TYPE_PHYSICS, physicsEventHandler)

proc kindOf(gameObject: ptr orxOBJECT): ObjKind =
  let name = objectKind(gameObject)
  if name.startsWith("Sand"): kDirt
  elif name.startsWith("Boulder"): kBoulder
  elif name == "Firefly" or name == "Butterfly": kCreature
  else:
    case name
    of "Player", "Player2", "Player3", "Player4": kPlayer
    of "Diamond": kDiamond
    of "Wall": kWall
    of "Exit": kExit
    else: kOther

proc pick(firstKind, secondKind: ObjKind; wanted: ObjKind;
          first, second: ptr orxOBJECT): ptr orxOBJECT =
  ## The object of the wanted kind, whichever side of the pair it is on.
  if firstKind == wanted: first else: second

proc impactSpeed(gameObject: ptr orxOBJECT): float32 =
  let speed = gameObject.getSpeed()
  result = abs(speed.fX) + abs(speed.fY)

proc killHero(heroObj: ptr orxOBJECT; reason: string) =
  ## Applies a death to the hero touching `heroObj` and plays the death
  ## feedback: red viewport flash, center message with the cause and the
  ## remaining lives.
  let index = world.playerOf(heroObj)
  if world.killPlayer(index, reason):
    gs.deathFlash = DeathFlashTime
    ui.showMessage((&"P{index + 1} {reason}").toUpperAscii(), 1.6)
    if index < world.players.len:
      let hero = world.players[index]
      ui.showSubMessage(
        (if hero.down: "OUT OF LIVES" else: &"LIVES {hero.lives}"), 1.6)

proc boulderApproach(boulder, other: ptr orxOBJECT;
                     normal: orxVECTOR): tuple[toward, closing: float32] =
  ## The boulder's motion relative to `other` along the contact normal
  ## (re-oriented from the other body toward the boulder): `toward` is
  ## the boulder's own velocity component toward the body (negative =
  ## approaching), `closing` the speed at which the gap shrinks.
  var n = normal
  let boulderPos = boulder.getWorldPosition()
  let otherPos = other.getWorldPosition()
  if n.fX * (boulderPos.fX - otherPos.fX) +
      n.fY * (boulderPos.fY - otherPos.fY) < 0.0:
    n.fX = -n.fX
    n.fY = -n.fY
  let bspeed = boulder.getSpeed()
  let ospeed = other.getSpeed()
  result.toward = bspeed.fX * n.fX + bspeed.fY * n.fY
  result.closing = (ospeed.fX - bspeed.fX) * n.fX +
                   (ospeed.fY - bspeed.fY) * n.fY

proc heroCrush(boulder, hero: ptr orxOBJECT; normal: orxVECTOR): bool =
  ## Crush decision for heroes. A boulder can be HELD: when it settles
  ## onto the hero slowly (closing below HoldCrushSpeed, e.g. dug out
  ## from underneath), the decision is by weight - pebbles and classic
  ## boulders are supported, big/huge crush. Fast arrivals are impacts
  ## and judged by momentum (mass x closing). Pushes and rams can never
  ## crush: the boulder's own velocity must point toward the hero and
  ## the hero must not be outrunning it.
  let motion = boulderApproach(boulder, hero, normal)
  if motion.toward >= 0.0 or motion.closing <= 0.0:
    return false
  let mass = boulder.getMass()
  if mass > HoldMass:
    return true
  result = motion.closing > HoldCrushSpeed and
           mass * motion.closing > CrushMomentum

proc creatureCrush(boulder, creature: ptr orxOBJECT;
                   normal: orxVECTOR): bool =
  ## Crush decision for creatures: no holding - any boulder genuinely
  ## moving onto one pops it into diamonds.
  let motion = boulderApproach(boulder, creature, normal)
  result = motion.toward < 0.0 and motion.closing > 0.0 and
           boulder.getMass() * motion.closing > CrushMomentum

proc processContact(contact: Contact) =
  if gs.phase != phPlaying:
    return
  if world.isDestroyed(contact.first) or world.isDestroyed(contact.second):
    # Either body has meanwhile been destroyed (e.g. by digging); touches
    # to it are stale and must be ignored.
    return
  let
    firstKind = kindOf(contact.first)
    secondKind = kindOf(contact.second)
    pair = {firstKind, secondKind}

  if pair == {kPlayer, kDirt}:
    digSand(pick(firstKind, secondKind, kDirt, contact.first, contact.second),
            pick(firstKind, secondKind, kPlayer, contact.first, contact.second))

  elif pair == {kPlayer, kDiamond}:
    when defined(debugContacts):
      let gem = pick(firstKind, secondKind, kDiamond,
                     contact.first, contact.second)
      echo "PAIR player-diamond at ",
        gem.getWorldPosition().fX, ", ", gem.getWorldPosition().fY
    collectGem(pick(firstKind, secondKind, kDiamond,
                    contact.first, contact.second),
               pick(firstKind, secondKind, kPlayer,
                    contact.first, contact.second))

  elif pair == {kPlayer, kExit}:
    if gs.exitOpen:
      gs.levelCompleted = true
    else:
      ui.showSubMessage("Need " & $gemsLeft() & " more diamonds", 1.5)

  elif pair == {kBoulder, kPlayer}:
    let
      boulder = pick(firstKind, secondKind, kBoulder,
                     contact.first, contact.second)
      heroObj = pick(firstKind, secondKind, kPlayer,
                     contact.first, contact.second)
    if heroCrush(boulder, heroObj, contact.normal):
      killHero(heroObj, "Crushed by a boulder")
    elif impactSpeed(boulder) > ThudMinSpeed and
        gs.worldClockTime - gs.lastThud >= ThudInterval:
      gs.lastThud = gs.worldClockTime
      spawnBurst("DustPuff", contact.position, 2)
      discard boulder.addSound("LandSound")

  elif pair == {kPlayer, kCreature}:
    let
      creatureObj = pick(firstKind, secondKind, kCreature,
                         contact.first, contact.second)
      heroObj = pick(firstKind, secondKind, kPlayer,
                     contact.first, contact.second)
    if not creatures.isDazed(creatureObj):
      # Dazed creatures (just dug out of their hiding wall) give the
      # player a reaction beat instead of killing instantly.
      killHero(heroObj,
        (if objectKind(creatureObj) == "Firefly": "Devoured by a firefly"
         else: "Caught by a butterfly"))

  elif pair == {kCreature, kDirt}:
    # Pressed against sand: keeps the wake-up daze alive so digging the
    # wall away never grants an instant kill.
    creatures.markTouchingSand(pick(firstKind, secondKind, kCreature,
                                    contact.first, contact.second))

  elif pair == {kBoulder, kCreature}:
    let
      boulder = pick(firstKind, secondKind, kBoulder,
                     contact.first, contact.second)
      creatureObj = pick(firstKind, secondKind, kCreature,
                         contact.first, contact.second)
    if creatureCrush(boulder, creatureObj, contact.normal):
      creatures.explodeCreature(creatureObj)

  elif pair == {kBoulder, kDirt} or pair == {kBoulder, kWall} or
      pair == {kBoulder, kBoulder}:
    let
      boulder = pick(firstKind, secondKind, kBoulder,
                     contact.first, contact.second)
      sand = pick(firstKind, secondKind, kDirt,
                  contact.first, contact.second)
    if impactSpeed(boulder) > ThudMinSpeed and
        gs.worldClockTime - gs.lastThud >= ThudInterval:
      gs.lastThud = gs.worldClockTime
      discard boulder.addSound("LandSound")
    # A resting boulder beds into loose (refined) sand: it slowly eats the
    # grain it rests on, dust and all. Coarse blocks never sink.
    if objectKind(sand).startsWith("SandFine"):
      world.activateGrainColumn(sand)
      if gs.worldClockTime - gs.lastSink >= 0.35:
        gs.lastSink = gs.worldClockTime
        world.destroySmallSand(sand)

  elif pair == {kDiamond, kDirt} or pair == {kDiamond, kWall} or
      pair == {kDiamond, kBoulder} or pair == {kDiamond, kDiamond}:
    let gem = pick(firstKind, secondKind, kDiamond,
                   contact.first, contact.second)
    if impactSpeed(gem) > ClinkMinSpeed and
        gs.worldClockTime - gs.lastClink >= ClinkInterval:
      gs.lastClink = gs.worldClockTime
      discard gem.addSound("ClinkSound")

proc processContacts*() =
  ## Applies all queued contacts. Runs once per frame, after physics.
  for contact in pendingContacts:
    processContact(contact)
  pendingContacts.setLen(0)
