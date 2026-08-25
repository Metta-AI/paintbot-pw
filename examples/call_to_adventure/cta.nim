## Call to Adventure executable entry point.

when defined(headless):
  import game
  runHeadless()
else:
  import graphics
  runGraphics()
