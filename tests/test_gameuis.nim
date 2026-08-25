import
  vmath,
  polyworld/gameuis

echo "Testing the nine game UI regions"
let layout = initGameUiLayout(vec2(1000, 800), 80, 10)
doAssert layout.gameAreaSize == vec2(1000, 720)
doAssert layout.panel(
  GameUiRegion.TopLeft,
  vec2(100, 50)
).origin == vec2(10, 10)
doAssert layout.panel(
  GameUiRegion.TopCenter,
  vec2(100, 50)
).origin == vec2(450, 10)
doAssert layout.panel(
  GameUiRegion.TopRight,
  vec2(100, 50)
).origin == vec2(890, 10)
doAssert layout.panel(
  GameUiRegion.CenterLeft,
  vec2(100, 50)
).origin == vec2(10, 335)
doAssert layout.panel(
  GameUiRegion.Center,
  vec2(100, 50)
).origin == vec2(450, 335)
doAssert layout.panel(
  GameUiRegion.CenterRight,
  vec2(100, 50)
).origin == vec2(890, 335)
doAssert layout.panel(
  GameUiRegion.BottomLeft,
  vec2(100, 50)
).origin == vec2(10, 660)
doAssert layout.panel(
  GameUiRegion.BottomCenter,
  vec2(100, 50)
).origin == vec2(450, 660)
doAssert layout.panel(
  GameUiRegion.BottomRight,
  vec2(100, 50)
).origin == vec2(890, 660)

echo "Testing the transport pushes bottom regions upward"
let transportPanel = layout.transportPanel
doAssert transportPanel.origin == vec2(0, 720)
doAssert transportPanel.size == vec2(1000, 80)
doAssert transportPanel.contains(vec2(999, 799))
doAssert not transportPanel.contains(vec2(1000, 800))

echo "Testing panel overlap and layout clearance"
block:
  let
    left = GameUiPanel(origin: vec2(0, 0), size: vec2(100, 50))
    right = GameUiPanel(origin: vec2(108, 0), size: vec2(100, 50))
    flush = GameUiPanel(origin: vec2(99, 0), size: vec2(100, 50))
    touch = GameUiPanel(origin: vec2(100, 0), size: vec2(100, 50))
  doAssert not overlaps(left, right)
  doAssert not overlaps(left, touch)
  doAssert overlaps(left, flush)
  doAssert overlaps(left, right, 16)
  doAssert not overlaps(left, right, 8)
  doAssert left.inside(vec2(100, 50))
  doAssert not left.inside(vec2(99, 50))

echo "Testing replay transport state"
var transport = initReplayTransport(100)
doAssert not transport.playing
transport.play()
doAssert transport.playing
transport.sync(100)
doAssert not transport.playing
transport.play()
doAssert transport.playing and transport.tick == 0
transport.seek(50)
doAssert not transport.playing and transport.tick == 50
transport.stepBack()
doAssert transport.tick == 49
transport.stepForward()
doAssert transport.tick == 50
transport.rewind()
doAssert transport.tick == 0

echo "Game UI tests passed"
