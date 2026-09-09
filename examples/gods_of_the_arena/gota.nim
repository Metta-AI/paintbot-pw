## Gods of the Arena executable entry point.

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
      outcome: (if run.world.gameOver: $run.world.winner else: "time_limit")
    ))
else:
  import graphics
  runGraphics()
