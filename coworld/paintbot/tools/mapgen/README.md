# Paintbot map generator

`mapgen.py` builds seeded Paintbot maps in the engine's own units, using the rules-40 world
(`examples/paintbot/sim.nim`, `topography.nim`, `mechanics.nim`):

- **Terrain**: centimetre heights on a 50 cm grid over the rules-22 span `[-4800, 11200] x [-2800, 6800]`,
  plus an island-margin grid (a cog is off the island below `Radius div 3 + 40`). Water is height below
  `RiverWaterHeight` (-162, quarter speed). A wall is a rise of more than 25 cm per 20 cm, as in `traversable`.
- **Items**: the rules-40 set: 2 home and 8 neutral control hearts, 4 grenades, 2 sprays, 2 armors,
  4 medkits, 2 uniforms, and 6 trenches (280 x 280). All come in half-turn mirrored pairs, like rules 35.
- **Cover**: round cover (`h: 0`, `w` = diameter), tagged tree / house / prop / rock.

Where items go is decided by path distance from each home. `ratio = dA / (dA + dB)` measures how far
a spot is toward the enemy (wading counts 4x). Every item has to sit on flat, dry, inland ground that
both homes can reach, clear of cover.

| item | where |
|---|---|
| home hearts | the flattest dry spot near each end |
| centre / forward / flank / prize hearts | contested middle; a forward post; far flanks; high or remote ground |
| grenades | behind your own lines (ratio 0.1-0.34), near cover |
| spray | close quarters: the densest cover in midfield |
| armor | exposed high ground just short of the middle |
| medkits | one near the centre, one on a flank |
| uniform | midfield, in cover |
| trenches | open, flat ground on the approach, where there is no other cover |

```bash
python3 mapgen.py --out maps            # the ten catalogue maps (+ PNG previews, index.json)
python3 mapgen.py --out maps --only crater --seed 7
python3 -m unittest test_mapgen
```

Map format: `paintbot-map/1` JSON. Heights and margins are base64 int16le, row-major (z, then x).
The engine does not load these maps yet; that needs a config-gated loader in `topography.nim`/`sim.nim`
and in `viewer.js`'s `islandMargin`.
