## Bounded, persistent BASIC players, with the same observations as WASM seats.
import polyworld/[basic, cli, controllers]
import sim
when defined(coworld): import polyworld/coworld

type HeardMessage* = object
  slot*: int
  pos*: Point
  text*: string
type Bot* = ref object
  runtime*: Runtime
  failed*: bool
  output*: PrintProc
  strings*: StringPool
var
  shouts*: array[Seats,seq[string]]
  heard*: array[Seats,seq[HeardMessage]]
  active*: World
  commands*: array[Seats, Command]
var visionCache: array[Seats, array[Seats, int8]]
proc visibleToBot(slot, other: int): bool =
  if other notin 0..<Seats: return false
  if visionCache[slot][other] == 0:
    visionCache[slot][other] = if active.visible(slot, other): 1 else: -1
  visionCache[slot][other] == 1
const DataNames = ["selfId","selfTeam","selfX","selfY","selfHp","carrying","homeX","homeY","heartX","heartY","worldTick","ownHeartX","ownHeartY","ownHeartStolen","hasGrenade","hasSpray","armorHp","livesLeft","grenadeCharge","trenchId"]
proc limits*(): Limits =
  result=defaultLimits()
  result.maxSourceBytes=64*1024; result.maxInstructions=20000
  result.maxMemoryBytes=2*1024*1024; result.maxWorkUnits=50000
  result.maxArrayElements=4096;result.maxGlobals=256;result.maxCallDepth=16
  result.maxPrintBytes=1024;result.maxPrintEvents=128
proc host(slot:int, strings:StringPool): Host =
  result=initHost()
  result.addStringFunctions(strings)
  discard result.addFunction("shout",1,proc(a:openArray[int32]):int32 =
    if shouts[slot].len>=4:return 0
    shouts[slot].add strings.getString(a[0])[0..<min(256,strings.getString(a[0]).len)];1,68)
  discard result.addFunction("heardCount",0,proc(a:openArray[int32]):int32 = heard[slot].len.int32,4)
  discard result.addFunction("heardText",1,proc(a:openArray[int32]):int32 =
    let i=a[0].int
    if i<0 or i>=heard[slot].len:return strings.putString("")
    strings.putString(heard[slot][i].text),4)
  proc getHeard(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=heard[slot].len:return -1
      if field==0:heard[slot][i].slot.int32
      elif field==1:heard[slot][i].pos.x
      else:heard[slot][i].pos.z
  for axis in 0..2:
    discard result.addFunction(["heardSlot","heardX","heardY"][axis],1,getHeard(axis),4)
  discard result.addFunction("sneak",1,proc(a:openArray[int32]):int32 =
    commands[slot].sneak=a[0]!=0;1,4)
  discard result.addFunction("soundCount",0,proc(a:openArray[int32]):int32 =
    var count = 0
    for cue in active.sounds:
      if cue.listener==slot.int32 and active.tick-cue.tick<=SoundLifetime: inc count
    count.int32,4)
  proc getSound(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      var index=0
      for cue in active.sounds:
        if cue.listener!=slot.int32 or active.tick-cue.tick>SoundLifetime:continue
        if index==a[0]:
          return (case field
            of 0:cue.kind
            of 1:cue.direction
            of 2:cue.distance
            else:active.tick-cue.tick)
        inc index
      -1
  for field in 0..3:
    discard result.addFunction(["soundKind","soundDirection","soundDistance","soundAge"][field],1,getSound(field),4)
  for name in DataNames:discard result.addData(name)
  discard result.addFunction("visible",1,proc(a:openArray[int32]):int32 = int32(visibleToBot(slot,a[0].int)),4)
  discard result.addFunction("playerX",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[a[0]].pos.x else: -1,4)
  discard result.addFunction("playerY",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[a[0]].pos.z else: -1,4)
  discard result.addFunction("playerHp",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[a[0]].hp else:0,4)
  discard result.addFunction("playerCarrying",1,proc(a:openArray[int32]):int32 =
    if visibleToBot(slot,a[0].int):active.cogs[a[0]].carrying.int32 else:0,4)
  discard result.addFunction("chargeGrenade",1,proc(a:openArray[int32]):int32 =
    commands[slot].chargeGrenade=a[0]!=0;1,4)
  discard result.addFunction("pickupCount",0,proc(a:openArray[int32]):int32 = active.pickups.len.int32,4)
  discard result.addFunction("pickupVisible",1,proc(a:openArray[int32]):int32 =
    let i=a[0].int
    int32(i>=0 and i<active.pickups.len and active.pickups[i].readyAt<=active.tick and active.canSeePoint(slot,active.pickups[i].pos)),4)
  proc getPickup(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=active.pickups.len or active.pickups[i].readyAt>active.tick or not active.canSeePoint(slot,active.pickups[i].pos):return -1
      if field==0:active.pickups[i].pos.x
      elif field==1:active.pickups[i].pos.z
      else:active.pickups[i].kind.int32
  for axis in 0..2:
    discard result.addFunction(["pickupX","pickupY","pickupKind"][axis],1,getPickup(axis),4)
  discard result.addFunction("heartCount",0,proc(a:openArray[int32]):int32 = active.controlHearts.len.int32,4)
  proc getControl(field:int):HostProc =
    result = proc(a:openArray[int32]):int32 =
      let i=a[0].int
      if i<0 or i>=active.controlHearts.len:return -1
      if field==0:active.controlHearts[i].pos.x
      elif field==1:active.controlHearts[i].pos.z
      elif field==2:active.controlHearts[i].owner
      elif field==6:active.heartPoints(i)
      elif i>=active.heartCaptures.len:
        if field==3: -1'i32 else: 0'i32
      elif field==3:active.heartCaptures[i].team
      elif field==4:active.heartCaptures[i].ticks
      else:active.heartCaptures[i].contested.int32
  for axis in 0..6:
    discard result.addFunction(["controlX","controlY","controlOwner",
      "controlCaptureTeam","controlCaptureTicks","controlContested","controlPoints"][axis],1,getControl(axis),4)
  discard result.addFunction("mapMinX",0,proc(a:openArray[int32]):int32 = minX().int32,4)
  discard result.addFunction("mapMinY",0,proc(a:openArray[int32]):int32 = minZ().int32,4)
  discard result.addFunction("mapMaxX",0,proc(a:openArray[int32]):int32 = maxX().int32,4)
  discard result.addFunction("mapMaxY",0,proc(a:openArray[int32]):int32 = maxZ().int32,4)
  discard result.addFunction("terrainHeight",2,proc(a:openArray[int32]):int32 =
    if visionRulesVersion >= 9: terrainHeight(clamp(a[0].int,minX(),maxX()),clamp(a[1].int,minZ(),maxZ())).int32 else: 0'i32,4)
  discard result.addFunction("walkTo",2,proc(a:openArray[int32]):int32 =
    commands[slot].walk=true;commands[slot].goal=Point(x:a[0],z:a[1]);1,4)
  discard result.addFunction("lookAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
  discard result.addFunction("shootAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].shoot=true;commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
proc loadBots*(groups:seq[BotGroup], playerSlot = 0'i32):array[Seats,Bot] =
  let sources=groups.expandBotSources(controllerKinds(Seats,playerSlot))
  for slot in 0..<Seats:
    if isPlayerIndex(playerSlot, slot): continue
    let strings=initStringPool()
    let h=host(slot,strings)
    let p=when defined(coworld):compilePlayer(sources[slot],h,limits(),slot)
      else:compile(sources[slot],h,limits())
    strings.bindProgram(p)
    result[slot]=Bot(runtime:initRuntime(p,h,limits()),strings:strings)
    when defined(coworld):result[slot].output=playerPrinter(slot)
proc decide*(bots:array[Seats,Bot],w:World):array[Seats,Command] =
  shouts=default(array[Seats,seq[string]])
  active=w;commands=default(array[Seats,Command])
  visionCache=default(array[Seats,array[Seats,int8]])
  for slot in 0..<Seats:
    let b=bots[slot];let cog=w.cogs[slot];let home=home(team(slot));let enemyHeart=w.hearts[1-team(slot)];let own=w.hearts[team(slot)]
    let heart=if enemyHeart.carrier<0 or w.visible(slot,enemyHeart.carrier.int):enemyHeart.pos else:home(1-team(slot))
    let ownPos=if own.carrier<0 or w.visible(slot,own.carrier.int):own.pos else:home
    if b.isNil or b.failed or cog.hp<=0:continue
    let values=[slot.int32,team(slot).int32,cog.pos.x,cog.pos.z,cog.hp,cog.carrying.int32,home.x,home.z,heart.x,heart.z,w.tick,ownPos.x,ownPos.z,int32(own.carrier>=0),w.equipment[slot].grenade.int32,w.equipment[slot].sprayCan.int32,w.equipment[slot].armor,w.equipment[slot].lives,w.equipment[slot].charge,w.trenchAt(cog.pos).int32]
    b.runtime.restart()
    b.strings.reset()
    try:
      for j,name in DataNames:b.runtime.setData(name,values[j])
      discard b.runtime.run(b.output)
    except BasicError as e:
      b.failed=true;commands[slot]=Command()
      when defined(coworld):playerError(slot,e.msg)
      else:echo "seat ",slot," disabled: ",e.msg
  commands

proc deliverSpeech*(w: World) =
  ## Next-tick hearing matches CTF's 20%-of-map-width radius, regardless of vision.
  heard=default(array[Seats,seq[HeardMessage]])
  for sender in 0..<Seats:
    if w.cogs[sender].hp<=0:continue
    for receiver in 0..<Seats:
      if receiver==sender or w.cogs[receiver].hp<=0:continue
      if distance2(w.cogs[sender].pos,w.cogs[receiver].pos)>(Width div 5).int64*(Width div 5):continue
      for message in shouts[sender]:
        heard[receiver].add HeardMessage(slot:sender,pos:w.cogs[sender].pos,text:message)
