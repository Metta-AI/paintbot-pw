## Human hero commands for Gods of the Arena.
##
## Graphics queues intents. The decide tick applies them through the same
## `apply*` procs the BASIC bots use.

import
  sim,
  replays

type
  PlayerCommandKind = enum
    CommandWalk
    CommandAttack
    CommandAttackMove
    CommandBuy
    CommandUse

  PlayerCommand = object
    kind: PlayerCommandKind
    heroId: int32
    first: int32
    second: int32

var pending: seq[PlayerCommand]

proc queueWalkTo*(heroId, mapX, mapY: int32) =
  ## Queues one walk command for the human hero.
  pending.add PlayerCommand(
    kind: CommandWalk,
    heroId: heroId,
    first: mapX,
    second: mapY
  )

proc queueAttackMove*(heroId, mapX, mapY: int32) =
  ## Queues one attack-move command for the human hero.
  pending.add PlayerCommand(
    kind: CommandAttackMove,
    heroId: heroId,
    first: mapX,
    second: mapY
  )

proc queueAttackTarget*(heroId, targetId: int32) =
  ## Queues one attack command for the human hero.
  pending.add PlayerCommand(
    kind: CommandAttack,
    heroId: heroId,
    first: targetId
  )

proc queueBuyItem*(heroId, itemId: int32) =
  ## Queues one shop purchase for the human hero.
  pending.add PlayerCommand(
    kind: CommandBuy,
    heroId: heroId,
    first: itemId
  )

proc queueUseItem*(heroId, slot: int32) =
  ## Queues one inventory use for the human hero.
  pending.add PlayerCommand(
    kind: CommandUse,
    heroId: heroId,
    first: slot
  )

proc recordCommand(game: Game, command: PlayerCommand) =
  ## Writes one accepted human command onto the live tape.
  if game.recorder == nil:
    return
  let tick = uint32(game.world.tick)
  case command.kind
  of CommandWalk:
    game.recorder.recordWalkTo(
      tick, command.heroId, command.first, command.second
    )
  of CommandAttack:
    game.recorder.recordAttackTarget(tick, command.heroId, command.first)
  of CommandAttackMove:
    game.recorder.recordAttackMove(
      tick, command.heroId, command.first, command.second
    )
  of CommandBuy:
    game.recorder.recordBuyItem(tick, command.heroId, command.first)
  of CommandUse:
    game.recorder.recordUseItem(tick, command.heroId, command.first)

proc applyCommand(game: Game, command: PlayerCommand): bool =
  ## Applies one queued command through the bot validators.
  case command.kind
  of CommandWalk:
    applyWalkTo(
      game.world, command.heroId, command.first, command.second
    )
  of CommandAttack:
    applyAttackTarget(game.world, command.heroId, command.first)
  of CommandAttackMove:
    applyAttackMove(
      game.world, command.heroId, command.first, command.second
    )
  of CommandBuy:
    applyBuyItem(game.world, command.heroId, command.first)
  of CommandUse:
    applyUseItem(game.world, command.heroId, command.first)

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on a decision tick.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    game.recordCommand(command)
    discard game.applyCommand(command)
