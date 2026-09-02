## Human overlord commands for Light vs Dark.
##
## Graphics queues intents. The decide tick applies them through the Game
## `apply*` wrappers that also record the tape.

import
  sim

type
  PlayerCommandKind = enum
    CommandMove
    CommandAttackMove
    CommandAttack
    CommandHarvest
    CommandBuild
    CommandTrain
    CommandRally
    CommandCancel

  PlayerCommand = object
    kind: PlayerCommandKind
    player: int32
    entityId: int32
    first: int32
    second: int32
    third: int32

var
  pending: seq[PlayerCommand]
  pendingBuild*: int32 = -1
    ## Building kind ordinal waiting for a map click, or -1.
  attackMoveArmed*: bool
    ## Next ground click is an attack-move.

proc queueMove*(player, unitId, x, y: int32) =
  ## Queues a move for one owned unit.
  pending.add PlayerCommand(
    kind: CommandMove,
    player: player,
    entityId: unitId,
    first: x,
    second: y
  )

proc queueAttackMove*(player, unitId, x, y: int32) =
  ## Queues an attack-move for one owned unit.
  pending.add PlayerCommand(
    kind: CommandAttackMove,
    player: player,
    entityId: unitId,
    first: x,
    second: y
  )

proc queueAttack*(player, unitId, targetId: int32) =
  ## Queues an attack on one enemy.
  pending.add PlayerCommand(
    kind: CommandAttack,
    player: player,
    entityId: unitId,
    first: targetId
  )

proc queueHarvest*(player, unitId, target, isTree: int32) =
  ## Queues a harvest on a mine or tree.
  pending.add PlayerCommand(
    kind: CommandHarvest,
    player: player,
    entityId: unitId,
    first: target,
    second: isTree
  )

proc queueBuild*(player, peonId, kindValue, x, y: int32) =
  ## Queues a building placement.
  pending.add PlayerCommand(
    kind: CommandBuild,
    player: player,
    entityId: peonId,
    first: kindValue,
    second: x,
    third: y
  )

proc queueTrain*(player, buildingId, kindValue: int32) =
  ## Queues one unit from a building.
  pending.add PlayerCommand(
    kind: CommandTrain,
    player: player,
    entityId: buildingId,
    first: kindValue
  )

proc queueSetRally*(player, buildingId, x, y: int32) =
  ## Queues a rally point.
  pending.add PlayerCommand(
    kind: CommandRally,
    player: player,
    entityId: buildingId,
    first: x,
    second: y
  )

proc queueCancel*(player, entityId: int32) =
  ## Queues a cancel on one owned entity.
  pending.add PlayerCommand(
    kind: CommandCancel,
    player: player,
    entityId: entityId
  )

proc applyCommand(game: Game, command: PlayerCommand): bool =
  ## Applies one queued command through the recording wrappers.
  case command.kind
  of CommandMove:
    game.applyMove(
      command.player, command.entityId, command.first, command.second
    )
  of CommandAttackMove:
    game.applyAttackMove(
      command.player, command.entityId, command.first, command.second
    )
  of CommandAttack:
    game.applyAttack(command.player, command.entityId, command.first)
  of CommandHarvest:
    game.applyHarvest(
      command.player,
      command.entityId,
      command.first,
      command.second
    )
  of CommandBuild:
    game.applyBuild(
      command.player,
      command.entityId,
      command.first,
      command.second,
      command.third
    )
  of CommandTrain:
    game.applyTrain(command.player, command.entityId, command.first)
  of CommandRally:
    game.applySetRally(
      command.player, command.entityId, command.first, command.second
    )
  of CommandCancel:
    game.applyCancel(command.player, command.entityId)

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on a decision tick.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    discard game.applyCommand(command)
