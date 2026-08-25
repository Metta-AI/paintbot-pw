import
  vmath,
  polyworld/[chrome, gameuis, player]

echo "Testing minimap map area insets"
block:
  let
    panel = GameUiPanel(origin: vec2(10, 20), size: vec2(230, 230))
    area = panel.mapArea(top = 28, margin = 12, verticalInset = 40)
  doAssert area.origin == vec2(22, 48)
  doAssert area.size == vec2(206, 190)

echo "Testing panel hit testing includes the transport"
block:
  let layout = initGameUiLayout(vec2(1000, 800), 80, 10)
  let score = layout.panel(GameUiRegion.TopLeft, vec2(100, 50))
  doAssert mouseOverPanels(vec2(15, 15), layout, [score])
  doAssert mouseOverPanels(vec2(10, 750), layout, [score])
  doAssert not mouseOverPanels(vec2(500, 400), layout, [score])

echo "Testing stepped UI scale"
block:
  doAssert fitUiScale(vec2(1920, 1080), vec2(1700, 600)) == 1.0'f32
  doAssert fitUiScale(vec2(1024, 576), vec2(1800, 630)) == 0.5'f32
  doAssert fitUiScale(vec2(3840, 2160), vec2(1800, 630)) == 2.0'f32
  doAssert fitUiScale(vec2(400, 300), vec2(1800, 630)) == 0.25'f32
  doAssert fitUiScale(vec2(5000, 3000), vec2(1800, 630)) == 2.5'f32

echo "Testing HUD scale waits for panel clearance"
block:
  const
    PanelScore = vec2(407, 159)
    PanelHeroes = vec2(1051, 145)
    PanelClock = vec2(242, 106)
    PanelMinimap = vec2(356, 373)
    PanelDetails = vec2(1028, 321)
    PanelInventory = vec2(379, 322)
    TransportH = TransportHeight
    Clearance = 48.0'f32
  proc gotaFits(layoutSize: Vec2): bool =
    let
      layout = initGameUiLayout(layoutSize, TransportH)
      plates = [
        layout.panel(GameUiRegion.TopLeft, PanelScore),
        layout.panel(GameUiRegion.TopCenter, PanelHeroes),
        layout.panel(GameUiRegion.TopRight, PanelClock),
        layout.panel(GameUiRegion.BottomLeft, PanelMinimap),
        layout.panel(GameUiRegion.BottomCenter, PanelDetails),
        layout.panel(GameUiRegion.BottomRight, PanelInventory)
      ]
    layoutFits(layout, plates, Clearance)
  doAssert fitUiScale(vec2(1024, 576), gotaFits, UiCrispSteps) ==
    0.5'f32
  doAssert fitUiScale(vec2(1920, 1080), gotaFits, UiCrispSteps) ==
    0.5'f32
  doAssert fitUiScale(vec2(2560, 1440), gotaFits, UiCrispSteps) ==
    1.0'f32
  doAssert fitUiScale(vec2(3840, 2160), gotaFits, UiCrispSteps) ==
    1.0'f32
  doAssert fitUiScale(vec2(4096, 2304), gotaFits, UiCrispSteps) ==
    2.0'f32
  doAssert fitUiScale(vec2(900, 2000), gotaFits, UiCrispSteps) ==
    0.25'f32
  doAssert fitUiScale(vec2(1920, 300), gotaFits, UiCrispSteps) ==
    0.25'f32
  doAssert fitUiScale(vec2(400, 300), gotaFits, UiCrispSteps) ==
    0.25'f32

echo "Testing CTA HUD scale waits for panel clearance"
block:
  const
    PanelParty = vec2(316, 434)
    PanelMinimap = vec2(334, 478)
    PanelChat = vec2(337, 177)
    PanelAbilities = vec2(947, 157)
    PanelMenu = vec2(407, 71)
    TransportH = TransportHeight
    Clearance = 48.0'f32
  proc ctaFits(layoutSize: Vec2): bool =
    let
      layout = initGameUiLayout(layoutSize, TransportH)
      plates = [
        layout.panel(GameUiRegion.TopLeft, PanelParty),
        layout.panel(GameUiRegion.TopRight, PanelMinimap),
        layout.panel(GameUiRegion.BottomLeft, PanelChat),
        layout.panel(GameUiRegion.BottomCenter, PanelAbilities),
        layout.panel(GameUiRegion.BottomRight, PanelMenu)
      ]
    layoutFits(layout, plates, Clearance)
  doAssert fitUiScale(vec2(1024, 576), ctaFits, UiCrispSteps) ==
    0.5'f32
  doAssert fitUiScale(vec2(1920, 1080), ctaFits, UiCrispSteps) ==
    1.0'f32

echo "Testing LVD HUD scale waits for panel clearance"
block:
  const
    PanelScore = vec2(353, 461)
    PanelMinimap = vec2(788, 432)
    PanelSelection = vec2(488, 250)
    PanelBuild = vec2(642, 283)
    TransportH = TransportHeight
    Clearance = 48.0'f32
  proc lvdFits(layoutSize: Vec2): bool =
    let
      layout = initGameUiLayout(layoutSize, TransportH)
      plates = [
        layout.panel(GameUiRegion.TopLeft, PanelScore),
        layout.panel(GameUiRegion.TopRight, PanelMinimap),
        layout.panel(GameUiRegion.BottomLeft, PanelSelection),
        layout.panel(GameUiRegion.BottomRight, PanelBuild)
      ]
    layoutFits(layout, plates, Clearance)
  doAssert fitUiScale(vec2(1024, 576), lvdFits, UiCrispSteps) ==
    0.5'f32
  doAssert fitUiScale(vec2(1920, 1080), lvdFits, UiCrispSteps) ==
    1.0'f32

echo "Testing spectator clock"
block:
  const Rate = 24'i32
  let
    start = hudClock(0, Rate)
    noon = hudClock(hudDayTicks(Rate) * 4 div 24, Rate)
    nextDawn = hudClock(hudDayTicks(Rate), Rate)
    matchEnd = hudClock(Rate * 60 * 20, Rate)
  doAssert hudDayTicks(Rate) == Rate * 300
  doAssert start.day == 1 and start.hour == 8 and start.minute == 0
  doAssert abs(clockHour(0, Rate) - 8.0'f32) < 0.001
  doAssert noon.day == 1 and noon.hour == 12
  doAssert nextDawn.day == 2 and nextDawn.hour == 8
  doAssert matchEnd.day == 5 and matchEnd.hour == 8

echo "Testing the smooth clock"
block:
  const Rate = 24'i32
  # The fractional-tick clock agrees with the stepped clock at whole ticks
  # (within the minute the integer clock floors away) and never steps: one
  # tick of a five-minute day advances it by exactly 24h / (300 * rate).
  let perTick = 24.0'f32 / float32(hudDayTicks(Rate))
  for tick in [0'i32, 7, 1000, hudDayTicks(Rate) - 1, hudDayTicks(Rate)]:
    doAssert abs(clockHour(float32(tick), Rate) - clockHour(tick, Rate)) <
      1.5'f32 / 60.0'f32
    let
      here = clockHour(float32(tick), Rate)
      half = clockHour(float32(tick) + 0.5'f32, Rate)
    var expected = here + perTick * 0.5'f32
    if expected >= 24: expected -= 24
    doAssert abs(half - expected) < 0.001

echo "UI tests passed"
