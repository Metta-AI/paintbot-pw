## Human villager commands for Heartleaf.
##
## Graphics queues intents. The decide tick applies them through the Game
## `apply*` wrappers that also record the tape.

import
  sim

type
  PlayerCommandKind = enum
    CommandMove
    CommandGather
    CommandInvite
    CommandAccept
    CommandDecline
    CommandEnterHouse
    CommandExitHouse
    CommandStop

  PlayerCommand = object
    kind: PlayerCommandKind
    player: int32
    first: int32
    second: int32

var pending: seq[PlayerCommand]

proc queueMove*(player, x, y: int32) =
  ## Queues a walk to a tile.
  pending.add PlayerCommand(
    kind: CommandMove, player: player, first: x, second: y)

proc queueGather*(player, garden: int32) =
  ## Queues a gather on one garden plot.
  pending.add PlayerCommand(
    kind: CommandGather, player: player, first: garden)

proc queueInvite*(player, target: int32) =
  ## Queues an invitation to another villager.
  pending.add PlayerCommand(
    kind: CommandInvite, player: player, first: target)

proc queueAccept*(player, host: int32) =
  ## Queues accepting a standing invitation.
  pending.add PlayerCommand(
    kind: CommandAccept, player: player, first: host)

proc queueDecline*(player, host: int32) =
  ## Queues declining a standing invitation.
  pending.add PlayerCommand(
    kind: CommandDecline, player: player, first: host)

proc queueEnterHouse*(player, house: int32) =
  ## Queues walking into a house.
  pending.add PlayerCommand(
    kind: CommandEnterHouse, player: player, first: house)

proc queueExitHouse*(player: int32) =
  ## Queues stepping back outside.
  pending.add PlayerCommand(kind: CommandExitHouse, player: player)

proc queueStop*(player: int32) =
  ## Queues dropping the current order.
  pending.add PlayerCommand(kind: CommandStop, player: player)

proc applyCommand(game: Game, command: PlayerCommand): bool =
  ## Applies one queued command through the recording wrappers.
  case command.kind
  of CommandMove:
    game.applyMove(command.player, command.first, command.second)
  of CommandGather:
    game.applyGather(command.player, command.first)
  of CommandInvite:
    game.applyInvite(command.player, command.first)
  of CommandAccept:
    game.applyAccept(command.player, command.first)
  of CommandDecline:
    game.applyDecline(command.player, command.first)
  of CommandEnterHouse:
    game.applyEnterHouse(command.player, command.first)
  of CommandExitHouse:
    game.applyExitHouse(command.player)
  of CommandStop:
    game.applyStop(command.player)

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on a decision tick.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    discard game.applyCommand(command)
