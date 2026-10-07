## Centimetre terrain heights, shared by simulation and the Polyworld layers.
import std/math
import maps
export maps
const TerraceHeight* = 250
when defined(pwTraining):
  var wideRamps* {.threadvar.}: bool
  var wilderness* {.threadvar.}: bool
  var deepWilderness* {.threadvar.}: bool
  var organicTerrain* {.threadvar.}: bool
  var islandTerrain* {.threadvar.}: bool
  var expandedIsland* {.threadvar.}: bool
  var riverTerrain* {.threadvar.}: bool
  var curvedRiver* {.threadvar.}: bool
  var fractalRiver* {.threadvar.}: bool
  var lakeTerrain* {.threadvar.}: bool
  var symmetricTerrain* {.threadvar.}: bool
else:
  var wideRamps* = false
  var wilderness* = false
  var deepWilderness* = false
  var organicTerrain* = false
  var islandTerrain* = false
  var expandedIsland* = false
  var riverTerrain* = false
  var curvedRiver* = false
  var fractalRiver* = false
  var lakeTerrain* = false
  var symmetricTerrain* = false ## rules 35: every wave is mirrored under the half turn

const
  RiverBedHeight* = -200
  RiverWaterHeight* = -162 # GOTA-style shallow water: 38 cm above the bed.
  RiverBankWidth* = 850
proc landWave*(value,period,amplitude:int):int =
  let phase=((value mod period)+period) mod period
  let half=period div 2
  let t=phase mod half
  let magnitude=int(4'i64*t.int64*(half-t).int64*amplitude.int64 div (half*half).int64)
  if phase<half:magnitude else: -magnitude
proc riverCenter*(z: int): int =
  if fractalRiver:
    let t = min(z, 2600)
    3200 + landWave(t, 6800, 1300) + landWave(t+300, 2100, 180) + landWave(t-170, 700, 55)
  elif curvedRiver: 3200 + landWave(min(z, 2600), 6800, 1300)
  else: 3200 + landWave(z-2000, 6400, 420)

proc riverBlend*(x, z: int): int =
  ## GOTA's cubic bank profile, using centimetres and integer arithmetic.
  if activeMap() >= 0: return (if mapHeight(x, z) < -100: 1000 else: 0) # a map's wet ground
  if not riverTerrain: return 0
  if lakeTerrain:
    # A closed, irregular basin with a broad wading shore, entirely inland.
    var wx = landWave(z+300,1700,160)+landWave(x+z,650,45)
    var wz = landWave(x-200,2100,120)+landWave(x-z,900,40)
    if symmetricTerrain:
      # The basin's wobble is made odd under the half turn, so the mirror of every shore
      # point is a shore point; `div` truncates, which keeps (-a) div 2 == -(a div 2).
      let mx = 6400-x
      let mz = 4000-z
      wx = (wx-(landWave(mz+300,1700,160)+landWave(mx+mz,650,45))) div 2
      wz = (wz-(landWave(mx-200,2100,120)+landWave(mx-mz,900,40))) div 2
    let dx = (x-3200+wx)*1000 div 1700
    let dz = (z-2000+wz)*1000 div 1250
    let radius = int(sqrt((dx.int64*dx.int64+dz.int64*dz.int64).float64))
    let bank = clamp((radius-620)*1000 div 380, 0, 1000)
    return 1000-bank*bank div 1000
  if fractalRiver:
    let center = riverCenter(z)
    let mouth = clamp((-z-700)*1000 div 1800, 0, 1000)
    let dz = max(z-2600, 0)
    let bank = 700-mouth*350 div 1000 + landWave(z+400, 900, 45) + landWave(x-z, 330, 20)
    let dx = x-center
    var distance = min(int(sqrt((dx.int64*dx.int64+dz.int64*dz.int64).float64))*1000 div bank, 1000)
    if mouth > 0:
      # Two slender distributaries peel away from the main channel at the coast.
      let spread = mouth*mouth*1500 div 1000000
      for side in [-1, 1]:
        let branch = center + side*spread + landWave(z+side*900, 1100, 80)*mouth div 1000
        let width = 260-mouth*100 div 1000
        distance = min(distance, min(abs(x-branch)*1000 div width, 1000))
    return 1000-int(distance.int64*distance.int64*distance.int64 div 1000000)
  let dx = abs(x-riverCenter(z))
  let dz = if curvedRiver: max(z-2600, 0) else: 0
  # Rounded inland headwater; the opposite end opens onto the south coast.
  let distance = if curvedRiver: min(int(sqrt((dx.int64*dx.int64+dz.int64*dz.int64).float64)), RiverBankWidth)
    else: min(dx, RiverBankWidth)
  1000 - int(distance.int64*distance.int64*distance.int64*1000 div
    (RiverBankWidth.int64*RiverBankWidth.int64*RiverBankWidth.int64))

proc islandMarginDirect*(x,z:int):int =
  if activeMap() >= 0: return mapMargin(x, z)
  # Rounded headlands with asymmetric coves, in normalized coast units.
  let nx=abs(x-3200).int64*1000 div (if expandedIsland:7733 else:5800)
  let nz=abs(z-2000).int64*1000 div (if expandedIsland:4575 else:3050)
  let radius=int(sqrt(sqrt((nx*nx*nx*nx+nz*nz*nz*nz).float64)))
  var wobble=landWave(x+z,2600,28)+landWave(x-z+1100,3700,22)
  if symmetricTerrain:
    # Even under the half turn: mirrored coves.
    let mx=6400-x
    let mz=4000-z
    wobble=(wobble+landWave(mx+mz,2600,28)+landWave(mx-mz+1100,3700,22)) div 2
  980-radius+wobble
proc landShift(x,z:int):tuple[x,z:int] =
  (landWave(z+350,2900,360)+landWave(x+z,1700,70),
   landWave(x+600,3200,230)+landWave(z-x,1900,55))
proc landCoordinates*(x,z:int):tuple[x,z:int] =
  if not organicTerrain or activeMap() >= 0:return (x,z)
  let s=landShift(x,z)
  if symmetricTerrain:
    # Odd under the half turn, so mirrored points land on mirrored ground: the terraces,
    # lanes and hills below are themselves mirrored, and this keeps them that way.
    let m=landShift(6400-x,4000-z)
    return (x+(s.x-m.x) div 2, z+(s.z-m.z) div 2)
  (x+s.x, z+s.z)

proc terraceHeight*(x, z: int): int =
  if x >= 1000 and x <= 2200 and z >= 200 and z <= 1200:
    let dx = max(abs(x-1600)-450, 0)
    let dz = max(abs(z-700)-350, 0)
    if dx*dx+dz*dz <= 150*150: return TerraceHeight
  if z >= (if wideRamps: 500 else: 750) and z <= (if wideRamps: 1100 else: 950):
    if x >= 600 and x < 1000: return (x-600)*TerraceHeight div 400
    if x > 2200 and x <= 2800: return (2800-x)*TerraceHeight div 600
proc baseForestRouteDistance(x,z:int):int =
  # Four-metre woodland trails loop around the village with links at both ends.
  min(min(abs(x+1700),abs(x-8100)),min(abs(z+650),abs(z-4650)))
proc forestRouteDistance*(x,z:int):int =
  let p=landCoordinates(x,z)
  baseForestRouteDistance(p.x,p.z)
proc villageLaneDistance*(x,z:int):int =
  let p=landCoordinates(x,z)
  abs(p.z-2000-landWave(p.x,4400,210))
proc forestHeight*(x,z:int):int =
  var height=0
  for c in [(-1900,700,600,1100),(-1400,3100,480,1000),
      (800,-900,380,1000),(3600,-900,460,1100),(5700,-800,330,900)]:
    for mirrored in [false,true]:
      let cx=if mirrored:6400-c[0] else:c[0]
      let cz=if mirrored:4000-c[1] else:c[1]
      let d2=(x-cx)*(x-cx)+(z-cz)*(z-cz)
      if d2<c[3]*c[3]:
        height=max(height,c[2]*(c[3]*c[3]-d2) div (c[3]*c[3]))
  if expandedIsland:
    for c in [(-3900,300,520,1800),(-3600,3600,460,1700),(700,-1800,410,1800),(3600,-1900,500,1900)]:
      for mirrored in [false,true]:
        let cx=if mirrored:6400-c[0] else:c[0]
        let cz=if mirrored:4000-c[1] else:c[1]
        let d2=(x-cx)*(x-cx)+(z-cz)*(z-cz)
        if d2<c[3]*c[3]:height=max(height,c[2]*(c[3]*c[3]-d2) div (c[3]*c[3]))
  # Broad saddles lower the route while leaving climbable slopes on either side.
  height=height*(300+min(baseForestRouteDistance(x,z),500)) div 800
  let edge=max(max(0,max(-x,x-6400)),max(0,max(-z,z-4000)))
  height*min(edge,500) div 500
proc islandMargin*(x,z:int):int
proc forestLots*():seq[tuple[x,z,radius:int]] =
  if activeMap() >= 0: return # a map carries its own cover
  # Jittered groves, not a wall: trails and objective clearings stay open.
  for z in countup((if expandedIsland: -2700 else: -1000),(if expandedIsland:6700 else:4800),400):
    for x in countup((if expandedIsland: -4600 else: -2500),(if expandedIsland:11000 else:8900),400):
      if x>= -800 and x<=7200 and z>= -400 and z<=4400:continue
      # Rules 35: the grid is its own mirror (no row sits on z=2000), so the northern half is
      # placed as before and the southern half is its exact mirror.
      if symmetricTerrain and z>2000:continue
      let px=x+((x+3000)*17+(z+1400)*11) mod 161-80
      let pz=z+((x+3000)*7+(z+1400)*19) mod 181-90
      if islandTerrain and islandMargin(px,pz)<75:continue
      if riverBlend(px,pz)>0:continue
      if forestRouteDistance(px,pz)<220:continue
      if (if organicTerrain:villageLaneDistance(px,pz) else:abs(pz-2000))<240:continue
      if (x+z) mod 3==0:continue
      result.add (px,pz,55+(abs(x+z) mod 30))
      if symmetricTerrain:result.add (6400-px,4000-pz,55+(abs(x+z) mod 30))
proc wildernessHeight*(x,z:int):int =
  if not wilderness or (x>=0 and x<=6400 and z>=0 and z<=4000):return 0
  if deepWilderness:return forestHeight(x,z)
  # Smooth hills with wide low saddles; none of the perimeter routes is a cliff.
  for center in [(-500,900),(-500,3100),(6900,900),(6900,3100),(1700,-250),(4700,4250)]:
    let d=abs(x-center[0])+abs(z-center[1])
    result=max(result,max(0,180-d div 3))
  let edge=min(min(abs(x),abs(x-6400)),min(abs(z),abs(z-4000)))
  result=min(result,edge div 2)
proc baseRaisedHeight(x, z: int): int =
  max(terraceHeight(x, z), terraceHeight(6400-x, 4000-z))
proc baseTerrainHeight(x, z: int): int =
  if wilderness and (x<0 or x>6400 or z<0 or z>4000):return wildernessHeight(x,z)
  let raised = baseRaisedHeight(x, z)
  if raised > 0: return raised
  # Sunken lane with sloping entrances, crossed by a level central causeway.
  let along = clamp(min(x-1400, 5000-x), 0, 400)
  let across = clamp(500-abs(z-2000), 0, 250)
  let crossing = clamp(abs(x-3200)-160, 0, 240)
  int(-150'i64*along.int64*across.int64*crossing.int64 div (400*250*240))

proc raisedHeight*(x,z:int):int =
  if activeMap() >= 0: return 0 # a map's high ground is terrain, not terrace decks
  let p=landCoordinates(x,z)
  baseRaisedHeight(p.x,p.z)
proc terrainHeightDirect*(x,z:int):int =
  if activeMap() >= 0: return mapHeight(x, z)
  let p=landCoordinates(x,z)
  result=baseTerrainHeight(p.x,p.z)
  if riverTerrain:
    let amount = riverBlend(x,z)
    result -= (result-RiverBedHeight)*amount div 1000
  if islandTerrain:
    let coast=islandMarginDirect(x,z)
    result=min(result,(coast-35)*5)

# Rules-static terrain lookups. terrainHeight and islandMargin are pure functions of a
# point and the flags above, and the sampled visibility, walk and navigation rays call
# them millions of times per match. Training builds remember exact results per point
# in 64x64 blocks shared by every world and thread whose flags agree: a block is computed
# whole by the direct functions above the first time any of its points is asked for, and
# records its highest ground and lowest coast margin, so a ray can clear a stretch of samples
# against the block's bounds without reading its cells. A point outside the tabled span,
# and every point of a generated map, falls through to the direct code.
when defined(pwTraining):
  import std/[atomics, hashes, locks, memfiles, os, random, strutils, sysrand]
  const
    TerrainCacheMinX = -5120
    TerrainCacheMinZ = -3072
    TerrainCacheBlock* = 64
    TerrainCacheBlocksX = 264 # 16896 units, covers rules 22+ span [-4800, 11200] with margin
    TerrainCacheBlocksZ = 160 # 10240 units, covers [-2800, 6800] with margin
  type
    TerrainCell* = object
      height*, margin*: int16
    TerrainBlock* = object
      maxHeight*, minMargin*: int16 ## bounds over every cell of the block
      cells: array[TerrainCacheBlock*TerrainCacheBlock, TerrainCell]
    TerrainTable = object
      key: int
      blocks: array[TerrainCacheBlocksX*TerrainCacheBlocksZ, Atomic[ptr TerrainBlock]]
  # One per flag combination and map (the island's own terrain is map slot 0).
  var terrainTables: array[2048*(MapNames.len+1+MaxTrainingMaps), Atomic[ptr TerrainTable]]
  var terrainCurrent {.threadvar.}: ptr TerrainTable
  proc terrainFlagsKey(): int =
    for i, flag in [wideRamps, wilderness, deepWilderness, organicTerrain, islandTerrain,
        expandedIsland, riverTerrain, curvedRiver, fractalRiver, lakeTerrain, symmetricTerrain]:
      if flag: result = result or (1 shl i)
    result = result or ((activeMap()+1) shl 11)
  proc refreshTerrainTable*() =
    ## Binds this thread's lookups to the table for its current flags. configureRules
    ## calls it; a training build that sets terrain flags by hand must call it too,
    ## because the lookup itself reads one thread variable, never the eleven flags. The same
    ## holds for setActiveMap.
    let key = terrainFlagsKey()
    if terrainCurrent != nil and terrainCurrent.key == key: return
    var table = terrainTables[key].load(moAcquire)
    if table == nil:
      let fresh = cast[ptr TerrainTable](allocShared0(sizeof(TerrainTable)))
      fresh.key = key
      var expected: ptr TerrainTable = nil
      if terrainTables[key].compareExchange(expected, fresh, moAcquireRelease, moAcquire):
        table = fresh
      else:
        deallocShared(fresh)
        table = expected
    terrainCurrent = table
  proc terrainTable(): ptr TerrainTable {.inline.} =
    if terrainCurrent == nil: refreshTerrainTable()
    terrainCurrent
  proc directCell(x, z: int): TerrainCell =
    let height = terrainHeightDirect(x, z)
    let margin = islandMarginDirect(x, z)
    doAssert height >= low(int16) and height <= high(int16) and
      margin >= low(int16) and margin <= high(int16), "terrain outside int16"
    TerrainCell(height: int16(height), margin: int16(margin))
  proc newTerrainBlock(table: ptr TerrainTable, index: int): ptr TerrainBlock =
    ## Computes every cell and the block's bounds, then publishes it; the first publisher
    ## wins and a loser frees its identical copy.
    let entry = cast[ptr TerrainBlock](allocShared0(sizeof(TerrainBlock)))
    let x0 = TerrainCacheMinX+(index mod TerrainCacheBlocksX)*TerrainCacheBlock
    let z0 = TerrainCacheMinZ+(index div TerrainCacheBlocksX)*TerrainCacheBlock
    entry.maxHeight = low(int16)
    entry.minMargin = high(int16)
    for dz in 0..<TerrainCacheBlock:
      for dx in 0..<TerrainCacheBlock:
        let cell = directCell(x0+dx, z0+dz)
        entry.cells[dz*TerrainCacheBlock+dx] = cell
        entry.maxHeight = max(entry.maxHeight, cell.height)
        entry.minMargin = min(entry.minMargin, cell.margin)
    var expected: ptr TerrainBlock = nil
    if table.blocks[index].compareExchange(expected, entry, moAcquireRelease, moAcquire):
      return entry
    deallocShared(entry)
    expected
  proc terrainBlockAt*(x, z: int): ptr TerrainBlock {.inline.} =
    ## The computed block holding (x, z), or nil when the point is not tabled (outside the
    ## span, or a generated map: a map's terrain is already a table, maps.nim's grid, and
    ## tabling it too would pin about 0.6 GB of blocks per map for the life of the process).
    let cx = x-TerrainCacheMinX
    let cz = z-TerrainCacheMinZ
    if activeMap() >= 0 or cx < 0 or cz < 0 or cx >= TerrainCacheBlocksX*TerrainCacheBlock or
        cz >= TerrainCacheBlocksZ*TerrainCacheBlock:
      return nil
    let table = terrainTable()
    let index = (cz div TerrainCacheBlock)*TerrainCacheBlocksX+cx div TerrainCacheBlock
    result = table.blocks[index].load(moAcquire)
    if result == nil: result = newTerrainBlock(table, index)
  proc cellIn*(b: ptr TerrainBlock, x, z: int): TerrainCell {.inline.} =
    ## The cell of (x, z) in b, the block terrainBlockAt(x, z) returned.
    let cx = x-TerrainCacheMinX
    let cz = z-TerrainCacheMinZ
    b.cells[(cz mod TerrainCacheBlock)*TerrainCacheBlock+cx mod TerrainCacheBlock]
  proc terrainSample*(x,z:int):TerrainCell =
    ## Both values of one point; identical to terrainHeightDirect and islandMarginDirect.
    let b = terrainBlockAt(x, z)
    if b == nil: directCell(x, z) else: b.cellIn(x, z)
  proc terrainHeight*(x,z:int):int =
    let b = terrainBlockAt(x, z)
    if b == nil: terrainHeightDirect(x, z) else: int(b.cellIn(x, z).height)
  proc islandMargin*(x,z:int):int =
    let b = terrainBlockAt(x, z)
    if b == nil: islandMarginDirect(x, z) else: int(b.cellIn(x, z).margin)
  proc prewarmTerrain*(x0, z0, x1, z1: int): int =
    ## Computes now every block of the thread's table that overlaps [x0, x1] x [z0, z1]
    ## (clipped to the tabled span) and returns how many that is; 0 on a generated map,
    ## which is never tabled. Lookups then never pay for a first touch in that area.
    if activeMap() >= 0: return 0
    let table = terrainTable()
    let bx0 = clamp((x0-TerrainCacheMinX) div TerrainCacheBlock, 0, TerrainCacheBlocksX-1)
    let bx1 = clamp((x1-TerrainCacheMinX) div TerrainCacheBlock, 0, TerrainCacheBlocksX-1)
    let bz0 = clamp((z0-TerrainCacheMinZ) div TerrainCacheBlock, 0, TerrainCacheBlocksZ-1)
    let bz1 = clamp((z1-TerrainCacheMinZ) div TerrainCacheBlock, 0, TerrainCacheBlocksZ-1)
    for bz in bz0..bz1:
      for bx in bx0..bx1:
        let index = bz*TerrainCacheBlocksX+bx
        if table.blocks[index].load(moAcquire) == nil: discard newTerrainBlock(table, index)
        inc result
  # A computed table can be saved and later mapped read-only by other processes, which then
  # share one copy through the page cache instead of each computing ~0.6 GB. A file is taken
  # only when its header matches this build's terrain source and table layout and the
  # thread's flags, and sampled cells agree with the direct functions.
  const
    TerrainFileMagic = 0x3130524554525750'i64 # "PWTERR01"
    TerrainFingerprint = int64(hash(staticRead("topography.nim") & staticRead("maps.nim") &
      $TerrainCacheMinX & $TerrainCacheMinZ & $TerrainCacheBlock & $TerrainCacheBlocksX &
      $TerrainCacheBlocksZ & $sizeof(TerrainBlock)))
    TerrainFileHeader = 5 # int64 words: magic, fingerprint, key, block bytes, block count
  var terrainMappings: seq[MemFile] # kept open for the life of the process
  var terrainMappingsLock: Lock
  initLock(terrainMappingsLock)
  proc saveTerrain*(path: string): int =
    ## Writes the thread's table's computed blocks to path (via a temporary file renamed into
    ## place, so a reader never sees a partial file) and returns how many.
    if activeMap() >= 0: return 0
    let table = terrainTable()
    var indices: seq[int32]
    for i in 0..<table.blocks.len:
      if table.blocks[i].load(moAcquire) != nil: indices.add int32(i)
    if indices.len mod 2 == 1: indices.add -1'i32 # pad the index list to a whole int64
    let count = indices.len
    # Unique across processes and containers (which may share a pid), so concurrent savers
    # of one path never write the same temporary file.
    var nonce: array[8, byte]
    doAssert urandom(nonce)
    var tag = ""
    for b in nonce: tag.add toHex(b)
    let tmp = path & ".tmp-" & tag
    var f = syncio.open(tmp, fmWrite)
    try:
      var header = [TerrainFileMagic, TerrainFingerprint, int64(table.key), int64(sizeof(TerrainBlock)), int64(count)]
      doAssert f.writeBuffer(header[0].addr, sizeof(header)) == sizeof(header)
      doAssert f.writeBuffer(indices[0].addr, 4*count) == 4*count
      for index in indices:
        var b: TerrainBlock # the padding entry writes zeros
        if index >= 0: b = table.blocks[index].load(moAcquire)[]
        doAssert f.writeBuffer(b.addr, sizeof(b)) == sizeof(b)
    finally: f.close()
    moveFile(tmp, path)
    for index in indices:
      if index >= 0: inc result
  proc loadTerrain*(path: string): int =
    ## Maps a file saveTerrain wrote and installs its blocks into the thread's table where none
    ## is computed yet; returns how many it installed. Raises IOError when the file cannot be
    ## used (missing, another build's terrain, other flags, or cells that disagree).
    if activeMap() >= 0: return 0
    let table = terrainTable()
    var m: MemFile
    try: m = memfiles.open(path, mode = fmRead)
    except OSError as e: raise newException(IOError, "terrain cache " & path & ": " & e.msg)
    let words = cast[ptr UncheckedArray[int64]](m.mem)
    if m.size < 8*TerrainFileHeader or words[0] != TerrainFileMagic or words[1] != TerrainFingerprint or
        words[2] != int64(table.key) or words[3] != int64(sizeof(TerrainBlock)):
      m.close()
      raise newException(IOError, "terrain cache " & path & " is not for this build and terrain")
    let count = words[4].int
    let blocksAt = 8*TerrainFileHeader+4*count
    if count < 0 or m.size != blocksAt+count*sizeof(TerrainBlock):
      m.close()
      raise newException(IOError, "terrain cache " & path & " is truncated")
    let indices = cast[ptr UncheckedArray[int32]](cast[uint](m.mem)+uint(8*TerrainFileHeader))
    let blocks = cast[ptr UncheckedArray[TerrainBlock]](cast[uint](m.mem)+uint(blocksAt))
    var rng = initRand(count)
    for k in 0..<count:
      let index = indices[k].int
      if index < 0: continue
      if index >= table.blocks.len:
        m.close()
        raise newException(IOError, "terrain cache " & path & " has a block outside the table")
      if k mod 64 == 0:
        let x = TerrainCacheMinX+(index mod TerrainCacheBlocksX)*TerrainCacheBlock+rng.rand(TerrainCacheBlock-1)
        let z = TerrainCacheMinZ+(index div TerrainCacheBlocksX)*TerrainCacheBlock+rng.rand(TerrainCacheBlock-1)
        if blocks[k].addr.cellIn(x, z) != directCell(x, z):
          m.close()
          raise newException(IOError, "terrain cache " & path & " disagrees with this build's terrain")
    withLock terrainMappingsLock: terrainMappings.add m
    for k in 0..<count:
      let index = indices[k].int
      if index < 0: continue
      var expected: ptr TerrainBlock = nil
      if table.blocks[index].compareExchange(expected, blocks[k].addr, moAcquireRelease, moAcquire):
        inc result
  proc terrainCacheResidentBlocks*(): int =
    ## Computed blocks across every table; each holds 16 KiB of cells.
    for i in 0..<terrainTables.len:
      let table = terrainTables[i].load(moAcquire)
      if table == nil: continue
      for j in 0..<table.blocks.len:
        if table.blocks[j].load(moAcquire) != nil: inc result
else:
  proc refreshTerrainTable*() = discard
  proc terrainHeight*(x,z:int):int = terrainHeightDirect(x,z)
  proc islandMargin*(x,z:int):int = islandMarginDirect(x,z)
