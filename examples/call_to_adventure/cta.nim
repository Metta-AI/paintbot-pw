## Call to Adventure executable entry point.

when defined(headless):
  import game
  runHeadless()
  when defined(coworld):
    import polyworld/coworld
    import sim
    finishCoworld(CoworldResults(
      scores: run.world.scores(),
      ticks: run.world.tick,
      seed: options.seed,
      outcome: $run.world.outcome,
      bankedGold: @(run.world.bankedGold),
      returned: @(run.world.returned)
    ))
else:
  import graphics
  runGraphics()
