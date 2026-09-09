## Call to Adventure executable entry point.

when defined(headless):
  import game
  runHeadless()
  when defined(coworld):
    import polyworld/coworld
    import content, sim
    finishCoworld(CoworldResults(
      scores: run.world.scores(),
      ticks: run.world.tick,
      seed: options.seed,
      outcome:
        if run.world.phase == EscapedPhase: "escaped"
        elif run.world.phase == WipedPhase: "wiped"
        else: "time_limit",
      bankedGold: @(run.world.bankedGold),
      returned: @(run.world.returned)
    ))
else:
  import graphics
  runGraphics()
