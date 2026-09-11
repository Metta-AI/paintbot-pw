{.define: paintbotExpanded.}
when defined(headless):
  import game
  runHeadless()
else:
  import graphics
  runGraphics()
