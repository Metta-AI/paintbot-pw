## Per-team outcome statistics for one or more Paintbot PW replays.
##
##     curl -sS <replay_url> | gunzip -c > match.raw      # hosted replays are gzipped
##     nim r examples/paintbot/replay_stats.nim match.raw [more.raw ...]
##
## Re-simulates each replay and reports, for both teams, what actually decided the match:
## lives left, cogs standing, captures, heart-ticks held, ticks spent ahead on heart count, and
## each glory award by kind. Written because win rate alone hid the fact that league matches end
## by elimination at a quarter of the clock, with the heart meter never deciding anything.
##
## Teams are named by side (Ember = even slots, Azure = odd), never "us" and "them": a league
## round swaps which side a policy takes from episode to episode, so the caller must map sides
## from that episode's roster (`policy_version_ids`, zipped with slots) and not assume.
import std/[os, sets, strformat]
import game, sim

proc report(path: string) =
  let r = loadRecording(path)
  var w = newWorld(r.seed)
  var heartTicks, ahead, ffHits, ffGlory, quietHits, quietGlory: array[2, int]
  var seen: HashSet[string]
  var ticks = 0
  for f in r.frames:
    w.step(f.commands, replayRulesVersion)
    inc ticks
    var owned: array[2, int]
    for h in w.controlHearts:
      if h.owner >= 0: inc owned[h.owner]
    for s in 0..1: heartTicks[s] += owned[s]
    if owned[0] > owned[1]: inc ahead[0]
    elif owned[1] > owned[0]: inc ahead[1]
    # gloryEvents is a rolling window, so dedupe rather than sampling one tick.
    for e in w.gloryEvents:
      let key = &"{e.tick}:{e.team}:{e.kind}:{e.amount}"
      if key notin seen:
        seen.incl key
        if e.kind == gloryFriendlyFire: inc ffHits[e.team]; ffGlory[e.team] += e.amount
        else: inc quietHits[e.team]; quietGlory[e.team] += e.amount
  var lives, standing: array[2, int]
  for i, c in w.cogs:
    lives[i mod 2] += w.equipment[i].lives
    if c.hp > 0: inc standing[i mod 2]
  let winner = if w.glory[0] > w.glory[1]: 0 elif w.glory[1] > w.glory[0]: 1 else: -1
  echo &"{path.extractFilename}: {ticks} of {w.endTick} ticks " &
       &"({ticks * 100 div w.endTick}% of the limit), winner {(if winner < 0: \"draw\" else: (if winner == 0: \"Ember\" else: \"Azure\"))}"
  for s in 0..1:
    echo &"  {(if s == 0: \"Ember/even\" else: \"Azure/odd \")}  glory {w.glory[s]:4}  lives {lives[s]:3}  " &
         &"standing {standing[s]}  captures {w.captures[s]:2}  heart-ticks {heartTicks[s]:6}  " &
         &"ahead {ahead[s]:5}  friendly-fire {ffHits[s]:2} (+{ffGlory[s]})  quiet-supplies {quietHits[s]} (+{quietGlory[s]})"

when isMainModule:
  if paramCount() < 1: quit "usage: replay_stats <replay.raw> [...]"
  for i in 1..paramCount(): report(paramStr(i))
