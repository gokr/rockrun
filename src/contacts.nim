## Physics contact handling for Rockrun.
##
## ORX dispatches physics contact events while Box2D is stepping; bodies
## must not be destroyed from inside those callbacks, so contacts are only
## recorded here and drained later once per frame.
import strutils
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
    contact.position =
      cast[ptr orxPHYSICS_EVENT_PAYLOAD](event.pstPayload).vPosition
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

proc impactSpeed(gameObject: ptr orxOBJECT): float32 =
  let speed = gameObject.getSpeed()
  result = abs(speed.fX) + abs(speed.fY)

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
    let
      dirt = if firstKind == kDirt: contact.first else: contact.second
      digger = if firstKind == kPlayer: contact.first else: contact.second
    digSand(dirt, digger)

  elif pair == {kPlayer, kDiamond}:
    when defined(debugContacts):
      echo "PAIR player-diamond at ",
        (if firstKind == kDiamond: contact.first.getWorldPosition().fX
         else: contact.second.getWorldPosition().fX), ", ",
        (if firstKind == kDiamond: contact.first.getWorldPosition().fY
         else: contact.second.getWorldPosition().fY)
    let
      gem = if firstKind == kDiamond: contact.first else: contact.second
      collector = if firstKind == kPlayer: contact.first else: contact.second
    collectGem(gem, collector)

  elif pair == {kPlayer, kExit}:
    if gs.exitOpen:
      gs.levelCompleted = true
    else:
      ui.showSubMessage("Need " & $gemsLeft() & " more diamonds", 1.5)

  elif pair == {kBoulder, kPlayer}:
    let
      boulder = if firstKind == kBoulder: contact.first
                else: contact.second
      heroObj = if firstKind == kPlayer: contact.first
                else: contact.second
    if boulder.getSpeed().fY > CrushYSpeed:
      world.killPlayer(world.playerOf(heroObj), "Crushed by a boulder")
    elif impactSpeed(boulder) > ThudMinSpeed and
        gs.worldClockTime - gs.lastThud >= ThudInterval:
      gs.lastThud = gs.worldClockTime
      spawnBurst("DustPuff", contact.position, 2)
      discard boulder.addSound("LandSound")

  elif pair == {kPlayer, kCreature}:
    let
      creatureObj = if firstKind == kCreature: contact.first
                    else: contact.second
      heroObj = if firstKind == kPlayer: contact.first
                else: contact.second
    if not creatures.isDazed(creatureObj):
      # Dazed creatures (just dug out of their hiding wall) give the
      # player a reaction beat instead of killing instantly.
      world.killPlayer(world.playerOf(heroObj),
        (if objectKind(creatureObj) == "Firefly": "Devoured by a firefly"
         else: "Caught by a butterfly"))

  elif pair == {kCreature, kDirt}:
    # Pressed against sand: keeps the wake-up daze alive so digging the
    # wall away never grants an instant kill.
    creatures.markTouchingSand(
      if firstKind == kCreature: contact.first else: contact.second)

  elif pair == {kBoulder, kCreature}:
    let
      boulder = if firstKind == kBoulder: contact.first
                else: contact.second
      creatureObj = if firstKind == kCreature: contact.first
                    else: contact.second
    if boulder.getSpeed().fY > CrushYSpeed:
      creatures.explodeCreature(creatureObj)

  elif pair == {kBoulder, kDirt} or pair == {kBoulder, kWall} or
      pair == {kBoulder, kBoulder}:
    let boulder = if firstKind == kBoulder: contact.first
                  else: contact.second
    if impactSpeed(boulder) > ThudMinSpeed and
        gs.worldClockTime - gs.lastThud >= ThudInterval:
      gs.lastThud = gs.worldClockTime
      discard boulder.addSound("LandSound")
    # A resting boulder beds into loose (refined) sand: it slowly eats the
    # grain it rests on, dust and all. Coarse blocks never sink.
    let sand = if firstKind == kDirt: contact.first
               else: contact.second
    if objectKind(sand).startsWith("SandFine"):
      world.activateGrainColumn(sand)
      if gs.worldClockTime - gs.lastSink >= 0.35:
        gs.lastSink = gs.worldClockTime
        world.destroySmallSand(sand)

  elif pair == {kDiamond, kDirt} or pair == {kDiamond, kWall} or
      pair == {kDiamond, kBoulder} or pair == {kDiamond, kDiamond}:
    let gem = if firstKind == kDiamond: contact.first
              else: contact.second
    if impactSpeed(gem) > ClinkMinSpeed and
        gs.worldClockTime - gs.lastClink >= ClinkInterval:
      gs.lastClink = gs.worldClockTime
      discard gem.addSound("ClinkSound")

proc processContacts*() =
  ## Applies all queued contacts. Runs once per frame, after physics.
  for contact in pendingContacts:
    processContact(contact)
  pendingContacts.setLen(0)
