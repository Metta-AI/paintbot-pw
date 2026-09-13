## Post-game presentation clock. Never changes simulation state or replay ticks.
const VictorySeconds* = 30'f32

type Celebration* = object
  active*, paused*: bool
  elapsed*: float32

proc update*(c: var Celebration, atEnd: bool, dt: float32) =
  if not atEnd:
    c = Celebration()
  elif not c.active:
    c = Celebration(active: true)
  elif not c.paused:
    c.elapsed = min(VictorySeconds, c.elapsed + max(0'f32, dt))

proc finished*(c: Celebration): bool = c.active and c.elapsed >= VictorySeconds
proc removed*(c: Celebration, winner, side: int): bool =
  c.active and winner >= 0 and side != winner
