## Bounded, persistent BASIC players, with the same observations as WASM seats.
import polyworld/[basic, cli, controllers]
import sim
when defined(coworld): import polyworld/coworld

type Bot* = ref object
  runtime*: Runtime
  failed*: bool
  output*: PrintProc
  strings*: StringPool
var
  shouts*: array[Seats,seq[string]]
  active*: World
  commands*: array[Seats, Command]
const DataNames = ["selfId","selfTeam","selfX","selfY","selfHp","carrying","homeX","homeY","heartX","heartY","worldTick","ownHeartX","ownHeartY","ownHeartStolen"]
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
    shouts[slot].add strings.getString(a[0]);1,68)
  for name in DataNames:discard result.addData(name)
  discard result.addFunction("visible",1,proc(a:openArray[int32]):int32 = int32(active.visible(slot,a[0].int)),4)
  discard result.addFunction("playerX",1,proc(a:openArray[int32]):int32 =
    if active.visible(slot,a[0].int):active.cogs[a[0]].pos.x else: -1,4)
  discard result.addFunction("playerY",1,proc(a:openArray[int32]):int32 =
    if active.visible(slot,a[0].int):active.cogs[a[0]].pos.z else: -1,4)
  discard result.addFunction("playerHp",1,proc(a:openArray[int32]):int32 =
    if active.visible(slot,a[0].int):active.cogs[a[0]].hp else:0,4)
  discard result.addFunction("playerCarrying",1,proc(a:openArray[int32]):int32 =
    if active.visible(slot,a[0].int):active.cogs[a[0]].carrying.int32 else:0,4)
  discard result.addFunction("walkTo",2,proc(a:openArray[int32]):int32 =
    commands[slot].walk=true;commands[slot].goal=Point(x:a[0],z:a[1]);1,4)
  discard result.addFunction("shootAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].shoot=true;commands[slot].aim=Point(x:clamp(a[0],0,Width),z:clamp(a[1],0,Height));1,4)
proc loadBots*(groups:seq[BotGroup]):array[Seats,Bot] =
  let sources=groups.expandBotSources(controllerKinds(Seats,0))
  for slot in 0..<Seats:
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
  for slot in 0..<Seats:
    let b=bots[slot];let cog=w.cogs[slot];let home=home(team(slot));let enemyHeart=w.hearts[1-team(slot)];let own=w.hearts[team(slot)]
    let heart=if enemyHeart.carrier<0 or w.visible(slot,enemyHeart.carrier.int):enemyHeart.pos else:home(1-team(slot))
    let ownPos=if own.carrier<0 or w.visible(slot,own.carrier.int):own.pos else:home
    if b.isNil or b.failed or cog.hp<=0:continue
    let values=[slot.int32,team(slot).int32,cog.pos.x,cog.pos.z,cog.hp,cog.carrying.int32,home.x,home.z,heart.x,heart.z,w.tick,ownPos.x,ownPos.z,int32(own.carrier>=0)]
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
