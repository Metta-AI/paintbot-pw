import std/os
import polyworld/tapes
import game, sim
let r=loadReplayFile(paramStr(1),"paintbot_pw",1,Recording)
var w=newWorld(r.seed)
var moves,shots:array[Seats,int]
for f in r.frames:
  for i,c in f.commands:
    if c.walk and c.goal!=w.cogs[i].pos:inc moves[i]
    if c.shoot:inc shots[i]
  w.step(f.commands)
echo "moves=",moves," shots=",shots
for i,c in w.cogs:echo i," ",c.pos," hp=",c.hp
