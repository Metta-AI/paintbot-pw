# Gods of the Arena — three-lane auto-battler example

## Context

Build a small three-lane auto-battler at `examples/gods_of_the_arena/gota.nim` (currently an empty file): two gods as forts at opposite corners of a generated 64×64 map, three lanes (top/mid/bottom), a diagonal river with a bridge, forests. Both forts continuously spawn animated footmen (`data/characters/footman.glb`) that march down their lanes, melee any enemy they see, and advance when the enemy dies. No heroes yet — spectator game with orbit camera and a silky UI panel.

The terrain and character systems must come from library modules under `src/polyworld/`. Key finding from exploration: `src/polyworld/quadterrain.nim` and `src/polyworld/characters.nim` **already exist but are byte-identical copies of the experiments** — they export nothing and run app code (atlas build, `newWindow`, GL init, main loop) at module scope. The real work is converting them into libraries. The experiment files stay untouched. Per user request mid-planning, the terrain library is further split into **`quadterrain.nim` + `pathing.nim`**.

Verified from gltf sources: **one loaded footman model can render N independently-animated instances.** `updateAnimation` is pure CPU node-tree posing, and every `pbrContext.draw` recomputes world transforms and re-uploads the 23 joint matrices (`gltf/backends/opengl/renderer.nim:1433`, `:1107`; no morph targets in footman.glb so geometry is never re-uploaded). Per instance per frame: set `activeClips`/`animTime`, `updateAnimation(0)`, set `transform`+`tint`, `draw`. One trap: `applyClipAt` wraps time with `mod`, so one-shot clips (Death) must be clamped to clip duration by the caller. `tint` is a per-draw uniform (keep `tint.a == 1.0` — alpha < 1 reroutes into the blended path). footman.glb clips: `Attack01, Attack02, Death, Defend, GetHit, Idle, Run, Victory, Walk`.

## Files

### 1. `src/polyworld/pathing.nim` (new — the logical grid, zero GL)

Why the split lands here: quadterrain's mesh emitter needs `edgeLink` for tile-border rendering and A* needs the same proc; Nim forbids import cycles, so the shared data model must live below the renderer. pathing.nim imports only `std/heapqueue`, `vmath`.

Move from the current quadterrain copy, adding `*` exports:
- Consts: `GridTiles` (64), `HalfGrid`, `HeightSteps`; flags `TileExists`, `TileConnectedEast`, `TileConnectedSouth`, `TileImpassable`; kinds `GrassTile`, `RoadTile`, `RockTile`, `MarshTile`, `StoneTile`, `TreeTile`.
- Types: `Tile` (tops/bottoms/flags/kind), `QuadLayer`, `var layers*: seq[QuadLayer]`; `pack`/`unpack`; accessors `exists`, `connectedEast`, `connectedSouth`, `impassable` + setters (add missing `connectedEast=`/`connectedSouth=` via `setFlag`).
- Walkability: `slopeLimit*`, `isSteep`, `computeWalkable`, `layerWalkable`, `edgeLink*`, `nodeKey`.
- Queries: `tileCenter*(layerIndex, x, z): Vec3`, new `worldToTile*(worldX, worldZ): (int, int)`, `isWalkable*(layerIndex, x, z): bool`.
- `findPath*(startLayer, startX, startZ, finishLayer, finishX, finishZ): seq[Vec3]` — same A* body (currently quadterrain L1471), reparameterized away from the demo's picker globals; returns world-space tile centers.
- New height samplers (units stand on these): `groundHeight*(worldX, worldZ): float32` — bilinear over `layers[0]` tops (extract the inline formula at quadterrain L723-724); `surfaceHeight*(worldX, worldZ): float32` — max over all non-water layers with an existing tile there (bridge deck wins over riverbed).

### 2. `src/polyworld/quadterrain.nim` (in-place library conversion; imports + `export`s pathing)

Minimal-change strategy — keep the proven internals (emitLayer, tree baking, shaders) byte-similar; delete app code; wrap GL-dependent init in a proc.

**Delete** (app-only): atlas build, window/silky/onRune, the demo `generateLayers`, the ~13 UI demo params (frequency/octaves/fortEnabled/treeCount/bridgeEnabled/…), solid-sphere/path-ribbon program + `rebuildPathMesh`/`recomputePath`, camera + `mouseOverUi` + `cameraMvp`, `pickTile`/`PlaceMode`, `updateCamera`, silky panel, screenshot harness, `onFrame`, main loop.

**Keep private**: `compileStage`/`compileProgram`, shady shader procs, `PropModel` machinery, `addTriangle`/`addWall`/normal procs, `emitLayer`/`emitWaterLayer`, tree baking.

**Export / new API**:
- `var amplitude*`, `borderWidth*` (used by baking + uniforms), `seed*` (tree-bake rng).
- `proc initTerrain*()` — requires a current GL context: compiles the terrain/tree/water programs (module-scope `let`s become private `var`s), creates VAO/VBOs, loads + scales the three prop packs from `data/terrain/*.glb`.
- `proc bakeTerrain*()` — old `rebuildTerrain` minus `generateLayers()`: computeWalkable → emit meshes → bake trees from `TreeTile` tiles → upload VBOs. Caller owns `layers`.
- `proc scatterGrass*(count, randomSeed: int)`, `proc scatterRocks*(count, randomSeed: int)` — extracted from the demo generator (rocks mark tiles impassable). Call before `bakeTerrain`.
- `proc drawTerrain*(viewProjection: Mat4, showEdges = false)` — disables cull-face first (gltf's `beginFrame` leaves culling on; terrain winding isn't consistent), enables depth test, draws terrain + trees.
- `proc drawWater*(viewProjection: Mat4, cameraEye: Vec3)` — blended pass, call after all opaque drawing.

### 3. `src/polyworld/characters.nim` (in-place rewrite — the experiment is ~all app code)

```nim
type
  CharacterModel* = ref object
    file*: GltfFile
    clips*: Table[string, int]
    baseTransform*: Mat4          # scale to targetHeight, feet at y 0

  CharacterScene* = ref object
    renderer*: Renderer
    context*: PbrContext

proc loadCharacterModel*(path: string, targetHeight: float32): CharacterModel
proc clipIndex*(model: CharacterModel, name: string): int
proc clipDuration*(model: CharacterModel, clip: int): float32
proc newCharacterScene*(window: Window): CharacterScene   # renderer + pbrContext + env map
proc beginCharacters*(scene: CharacterScene, window: Window,
    view, projection: Mat4, cameraEye: Vec3)
  # sets size/view/proj/cameraPosition + the experiment's light rig
  # (ambient/sun/rim, useShadows=false, drawSkybox=false, dvLit, useTrs),
  # then renderer.beginFrame. Never clears — terrain owns the frame's one clear.
proc drawCharacter*(scene: CharacterScene, model: CharacterModel,
    position: Vec3, facing: float32, clip: int, animTime: float32,
    tint = color(1, 1, 1, 1))
  # activeClips/animTime → updateAnimation(0) → transform/tint → draw
proc finishCharacters*(scene: CharacterScene)
```

### 4. `examples/gods_of_the_arena/gota.nim` (the game, ~600-700 lines)

Imports: `std/[strformat, times, random]`, `bumpy, vmath, chroma, noisy, silky`, `polyworld/[pathing, quadterrain, characters]`. Startup order: atlas build → `newWindow` + `makeContextCurrent` + `loadExtensions` → `newSilky` → `initTerrain()` → `generateBattleMap()` → `scatterGrass`/`scatterRocks` → `bakeTerrain()` → `loadCharacterModel` + `newCharacterScene` → lane paths → `onFrame`.

**Map generation** (`generateBattleMap`, builds `layers` directly): corner heights are a pure function of corner coordinate (same discipline as the demo). Base simplex noise (freq 0.09, octaves 3, amplitude 1.4, seed var). Forts at tile centers (10,10) red and (53,53) blue: r≤4 flattened RoadTile plateau marked impassable (fort is décor + HP target — avoids gate pathing), r==4 ring +2.0 StoneTile walls, keep +3.2. **River** along the anti-diagonal `cx + cz = 64` with sine wiggle, carved ~2.2 deep; **fords** where top/bottom lanes cross (≈(53,11) and (11,53)) carve only ~0.55 so tiles stay walkable, MarshTile band. **Bridge**: east-west slab layer at origin ≈(28,29), 8×4, arched (slabs are axis-aligned — the mid lane S-bends over it; that's the design, not a bug), squeezed ground tiles impassable. **Lanes** as width-2 RoadTile polylines with corner-height smoothing near the road (demo's trick) — top: (14,10)→(52,10)→(53,49); bottom: mirror; mid: (14,14)→(26,26)→bridge→(38,34)→(49,49). **Forests**: ~90 `TreeTile`+impassable on grass ≥2 tiles from roads, outside forts and river. **Water**: full-map water slab, tile exists where carved ground < −1.1.

**Lane waypoints**: per lane per team, chain `findPath` between consecutive control tiles, concatenate centers; reverse for the other team. Assert every segment resolves (echo seed + segment on failure).

**Simulation** (O(n²) scan fine at ≤120 units):

```nim
type
  Team = enum RedTeam, BlueTeam
  FootmanState = enum Marching, Fighting, Dying
  Footman = ref object
    team; lane; position; facing; hp; state
    waypoints: seq[Vec3]; waypointIndex: int
    target: Footman
    swingClip; swingTime; damageDone   # attack cycle
    animClip; animTime
  Fort = object
    team; center; hp                   # 400
```

Tuning: hp 60, damage 12 landing at 45% of the swing clip, move 2.2, sight 5.0, melee range 0.9, wave = 2 per lane per team every 10 s, cap 120 (skip waves above), corpse linger 2.5 s.

Per frame: spawn timer → per footman: Dying advances clamped Death anim then despawns; else acquire nearest living enemy in sight (or enemy fort when in range / at path end); Fighting chases into melee range then runs the Attack01/Attack02 swing cycle (target dies → back to Marching at the current waypoint); Marching steers along waypoints. Then pairwise separation push (skip Dying), then `position.y = surfaceHeight(x, z)`. Fort hp ≤ 0 → freeze combat, winners loop Victory, silky banner "Red/Blue god has fallen". Anim map: Marching→Run, Fighting→Attack01/02 (Idle in gaps), Dying→Death clamped.

**Frame loop**: `updateCamera()` (orbit cam copied locally from the quadterrain experiment; shared camera module deferred) → `updateSimulation(dt)` → `sk.beginUi` → the frame's single `glClear` → `drawTerrain(viewProjection)` → `beginCharacters`/per-footman `drawCharacter` (team tints red `(1.0,0.55,0.55)` / blue `(0.55,0.65,1.0)`, alpha 1)/`finishCharacters` → `drawWater` → glDisable DEPTH_TEST/CULL_FACE/BLEND/MULTISAMPLE → silky panel (fort HP bars, unit counts, pause, spawn scrubber) → `sk.endUi` → `swapBuffers`. Footman targetHeight ≈ 1.15 world units (tile = 1).

**Screenshot harness** (same pattern as experiments): `-d:takeScreenshot`, env `CAM_YAW/CAM_PITCH/CAM_DIST` + `SIM_SECONDS` (fast-forward with fixed 1/60 steps), capture frame 30 → `gota_shot.png`, quit.

### 5. Config

- `config.nims`: add `--path:"src"` (relative paths resolve against the config's directory — proven by the working `../silky/src` entries).
- `.gitignore`: add `examples/gods_of_the_arena/gota` and `examples/gods_of_the_arena/gota_shot.png`.

## Implementation order

1. `config.nims` path; verify both experiments still compile (`nim c`).
2. `pathing.nim` (pure logic, compiles standalone).
3. `characters.nim` conversion (small).
4. `quadterrain.nim` conversion on top of pathing.
5. gota.nim: window + terrain + map gen + camera → screenshot of the empty map (check forts, river, bridge, fords, lanes, forests).
6. Spawning + marching (no combat) → three streams flow each way.
7. Combat, death, forts, win state, separation.
8. UI panel, tints, tuning, `.gitignore`, final screenshots.

## Verification

- Both experiments compile unchanged; `nim c examples/gods_of_the_arena/gota.nim` from repo root.
- `nim r -d:takeScreenshot examples/gods_of_the_arena/gota.nim` → map screenshot: two corner forts, diagonal river + bridge under mid lane, fords, three lanes, forests.
- `SIM_SECONDS=25 nim r -d:takeScreenshot ...` → red/blue columns clashing mid-lane, corpses on the ground.
- Startup asserts confirm every lane path segment resolved.
- Live run `nim r examples/gods_of_the_arena/gota.nim` for framerate sanity (≤120 animated units; per-instance cost is CPU posing + 23 mat4 uploads — trivial).

## Risks

- Seed could make a lane tile too steep → road-corridor smoothing, low amplitude, A* detours, startup asserts.
- GL state bleed (gltf enables cull-face; terrain isn't consistently wound) → `drawTerrain` disables culling itself; exactly one clear per frame; water strictly last before UI.
- Death clip loops if animTime clamp is forgotten (`applyClipAt` uses `mod`).
- A footman chased off-lane under the bridge would pop onto the deck (`surfaceHeight` returns topmost layer) — lanes never route under it; acceptable for now.
