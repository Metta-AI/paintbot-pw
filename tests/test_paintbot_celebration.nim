import std/unittest
import ../examples/paintbot/celebration

suite "Post-game celebration":
  test "starts at the final frame and lasts thirty seconds":
    var c: Celebration
    c.update(false, 12)
    check not c.active
    c.update(true, 1)
    check c.active
    check c.elapsed == 0
    c.update(true, 29.9)
    check not c.finished
    c.update(true, 0.1)
    check c.finished
    c.update(true, 100)
    check c.elapsed == 30
  test "pause holds the presentation clock and seeking restores everyone":
    var c: Celebration
    c.update(true, 0)
    c.update(true, 5)
    c.paused = true
    c.update(true, 20)
    check c.elapsed == 5
    check c.removed(0, 1)
    check not c.removed(0, 0)
    check not c.removed(-2, 1)
    c.update(false, 0)
    check not c.active
    check not c.removed(0, 1)
    c.update(true, 0)
    check not c.paused
    check c.elapsed == 0
