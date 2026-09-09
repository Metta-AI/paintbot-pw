## Light vs Dark executable entry point.

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
      outcome: "winner_" & $run.world.winner
    ))
else:
  import graphics
  runGraphics()
