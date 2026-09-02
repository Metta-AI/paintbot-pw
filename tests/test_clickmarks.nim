## Click-mark expand timing without a GPU context.

import polyworld/clickmarks

echo "Testing click mark life"
doAssert clickMarkLife(0, ClickMarkDuration) == 0
doAssert clickMarkLife(ClickMarkDuration, ClickMarkDuration) == 1
doAssert clickMarkLife(ClickMarkDuration * 0.5'f32, ClickMarkDuration) > 0
doAssert clickMarkLife(ClickMarkDuration * 0.5'f32, ClickMarkDuration) < 1
doAssert clickMarkLife(1, 0) == 1

echo "Testing click mark scale"
doAssert clickMarkScale(0) == ClickMarkStartScale
doAssert clickMarkScale(1) == ClickMarkEndScale
doAssert clickMarkScale(0) < clickMarkScale(0.5'f32)
doAssert clickMarkScale(0.5'f32) < clickMarkScale(1)
