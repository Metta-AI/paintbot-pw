import
  std/times,
  polyworld/player

echo "Testing play starts on and pauseOnStart is off by default"
block:
  var p = initPlayer(live = true, durationTicks = 100)
  doAssert p.playing
  doAssert p.speed == 1
  p = initPlayer(
    live = false,
    durationTicks = 100,
    playing = false,
    speed = 4
  )
  doAssert not p.playing
  doAssert p.speed == 4
  doAssert p.speedIndex == 2

echo "Testing live timeline uses duration until the match ends"
block:
  var p = initPlayer(live = true, durationTicks = 240)
  p.sync(10, 10, false)
  doAssert p.timelineEnd == 240
  doAssert not p.inHistory
  p.sync(10, 80, false)
  doAssert p.inHistory
  p.sync(80, 80, true)
  doAssert p.over
  doAssert p.timelineEnd == 80

echo "Testing seek backward restores and catch-up plays"
block:
  var p = initPlayer(live = true, durationTicks = 240)
  p.sync(50, 50, false)
  p.seekTo(20)
  doAssert p.restoreTick == 20
  doAssert p.targetTick == 20
  doAssert p.playing
  doAssert p.takeRestore() == 20
  doAssert p.restoreTick == -1
  p.sync(20, 50, false)
  p.seekTo(200)
  doAssert p.restoreTick == -1
  doAssert p.targetTick == 200

echo "Testing repeat rewinds at the end"
block:
  var p = initPlayer(live = false, durationTicks = 24)
  p.repeating = true
  p.sync(24, 24, true)
  p.startFrame(1.0, 24)
  doAssert not p.shouldTick(0)
  doAssert p.restoreTick == 0
  doAssert p.playing

echo "Testing realtime ticks keep an accumulator across frames"
block:
  var p = initPlayer(live = true, durationTicks = 100)
  p.sync(0, 0, false)
  p.startFrame(0.02, 24)
  doAssert p.takeRestore() == -1
  doAssert p.accumulator > 0
  doAssert not p.shouldTick(0)
  p.startFrame(0.03, 24)
  doAssert p.shouldTick(0)

echo "Testing play/pause stops catch-up"
block:
  var p = initPlayer(live = true, durationTicks = 240)
  p.sync(10, 80, false)
  p.skipToEnd()
  doAssert p.playing
  doAssert p.targetTick == p.timelineEnd
  p.togglePlay()
  doAssert not p.playing
  doAssert p.targetTick == -1
  p.seekTo(40)
  doAssert p.playing
  doAssert p.targetTick == 40
  p.togglePlay()
  doAssert not p.playing
  doAssert p.targetTick == -1

echo "Testing catch-up ignores realtime speed"
block:
  var p = initPlayer(live = true, durationTicks = 240, speed = 1)
  p.sync(10, 10, false)
  p.seekTo(200)
  doAssert p.targetTick == 200
  p.startFrame(0.001, 24)
  doAssert p.shouldTick(epochTime())

echo "Testing step back and forward move exactly one tick"
block:
  var p = initPlayer(live = true, durationTicks = 240)
  p.sync(50, 50, false)
  p.stepBack()
  doAssert not p.playing
  doAssert p.restoreTick == 49
  doAssert p.targetTick == 49
  doAssert p.accumulator == 0
  discard p.takeRestore()
  p.sync(24, 50, false)
  doAssert p.shouldTick(0)
  p.sync(48, 50, false)
  doAssert p.shouldTick(0)
  p.sync(49, 50, false)
  doAssert not p.shouldTick(0)
  p.stepForward()
  doAssert not p.playing
  doAssert p.restoreTick == -1
  doAssert p.targetTick == 50
  doAssert p.shouldTick(0)
  p.sync(50, 50, false)
  doAssert not p.shouldTick(0)

echo "Testing speed buttons clamp to 1, 2, 4, 16"
block:
  doAssert speedIndexOf(1) == 0
  doAssert speedIndexOf(2) == 1
  doAssert speedIndexOf(3) == 1
  doAssert speedIndexOf(8) == 2
  doAssert speedIndexOf(16) == 3
  doAssert speedIndexOf(64) == 3

echo "Player tests passed"
