import
  vmath,
  polyworld/[chrome, gameuis]

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

echo "Testing shared game UI resolution breakpoints"
block:
  for (size, expected) in [
    (vec2(480, 270), 0.25'f),
    (vec2(960, 540), 0.5'f),
    (vec2(1024, 576), 0.5'f),
    (vec2(1280, 720), 0.5'f),
    (vec2(1920, 1080), 1.0'f),
    (vec2(2560, 1440), 1.0'f),
    (vec2(3840, 2160), 2.0'f),
    (vec2(7680, 4320), 4.0'f),
    (vec2(3440, 1440), 1.0'f),
    (vec2(1080, 1920), 0.5'f),
    (vec2(400, 300), 0.25'f),
    (vec2(0), 0.25'f)
  ]:
    doAssert gameUiScale(size) == expected, $size

  for (size, previous, current) in [
    (vec2(960, 540), 0.25'f, 0.5'f),
    (vec2(1920, 1080), 0.5'f, 1.0'f),
    (vec2(3840, 2160), 1.0'f, 2.0'f),
    (vec2(7680, 4320), 2.0'f, 4.0'f)
  ]:
    doAssert gameUiScale(size - vec2(1, 0)) == previous
    doAssert gameUiScale(size - vec2(0, 1)) == previous
    doAssert gameUiScale(size) == current
    doAssert gameUiScale(size + vec2(1)) == current

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
