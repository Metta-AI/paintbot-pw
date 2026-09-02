## Human hero commands for Call to Adventure.
##
## Graphics queues intents. The decide tick applies them through
## `applyHeroAction`, the same path BASIC bots use.

import
  sim,
  replays

type
  PlayerCommand = object
    slot: int32
    action: ReplayAction

var pending: seq[PlayerCommand]

proc queueHeroAction*(slot: int32, action: ReplayAction) =
  ## Queues one hero command for the human party slot.
  pending.add PlayerCommand(slot: slot, action: action)

proc queueWalkTo*(slot, level, x, z: int32) =
  ## Queues a walk onto one dungeon tile.
  queueHeroAction(slot, ReplayAction(
    kind: ActionWalkTo,
    heroId: 100 + slot,
    first: level,
    second: x,
    third: z
  ))

proc queueAttackTarget*(slot, targetId: int32) =
  ## Queues an attack on one monster.
  queueHeroAction(slot, ReplayAction(
    kind: ActionAttackTarget,
    heroId: 100 + slot,
    first: targetId
  ))

proc queuePickupTarget*(slot, itemId: int32) =
  ## Queues a loot pickup.
  queueHeroAction(slot, ReplayAction(
    kind: ActionPickupTarget,
    heroId: 100 + slot,
    first: itemId
  ))

proc queueHealTarget*(slot, targetId: int32) =
  ## Queues a heal on one ally.
  queueHeroAction(slot, ReplayAction(
    kind: ActionHealTarget,
    heroId: 100 + slot,
    first: targetId
  ))

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on that hero's decision turn.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    var action = command.action
    action.tick = uint32(game.world.tick)
    if game.recorder != nil:
      game.recorder.recordAction(
        action.tick,
        action.heroId,
        action.kind,
        action.first,
        action.second,
        action.third
      )
    discard game.applyHeroAction(command.slot, action)
