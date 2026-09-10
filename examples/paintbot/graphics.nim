## Procedural Polyworld 3D replay arena; all simulation remains integer-only.
import std/[math,times]
import windy, opengl, vmath, chroma
import polyworld/shapes
import game, sim
when defined(emscripten):{.emit:"#include <emscripten.h>".}
else:{.emit:"#define EMSCRIPTEN_KEEPALIVE".}
var paused=false
var speed=1
var seek= -1
proc setPlaying(value:cint) {.exportc:"pw_play",cdecl,codegenDecl:"EMSCRIPTEN_KEEPALIVE $# $#$#".} = paused=value==0
proc setSpeed(value:cint) {.exportc:"pw_speed",cdecl,codegenDecl:"EMSCRIPTEN_KEEPALIVE $# $#$#".} = speed=clamp(value.int,1,32)
proc setTick(value:cint) {.exportc:"pw_seek",cdecl,codegenDecl:"EMSCRIPTEN_KEEPALIVE $# $#$#".} = seek=max(0,value.int)
const teamColors=[rgbx(245,89,96,255),rgbx(66,187,246,255)]
proc box(r:var ShapeRenderer,x,y,z,dx,dy,dz:float32,c:ColorRGBX) =
  let a=vec3(x-dx,y,z-dz);let b=vec3(x+dx,y,z-dz)
  let d=vec3(x-dx,y,z+dz);let e=vec3(x+dx,y,z+dz)
  let up=vec3(0,dy,0)
  r.addQuad(a,b,e,d,c)
  r.addQuad(a+up,d+up,e+up,b+up,c)
  r.addQuad(a,a+up,b+up,b,c)
  r.addQuad(b,b+up,e+up,e,c)
  r.addQuad(e,e+up,d+up,d,c)
  r.addQuad(d,d+up,a+up,a,c)
proc gem(r:var ShapeRenderer,p:Vec3,s:float32,c:ColorRGBX) =
  let top=p+vec3(0,s,0);let bottom=p-vec3(0,s,0)
  let ring=[p+vec3(s,0,0),p+vec3(0,0,s),p+vec3(-s,0,0),p+vec3(0,0,-s)]
  for i in 0..3:
    r.addTriangle(top,ring[i],ring[(i+1)mod 4],c)
    r.addTriangle(bottom,ring[(i+1)mod 4],ring[i],c)
proc runGraphics*() =
  setup()
  let window=newWindow("Paintbot PW",ivec2(1280,800))
  makeContextCurrent(window);loadExtensions()
  var shapes=initShapeRenderer()
  var last=epochTime();var accumulator=0.0
  window.onFrame=proc() =
    let now=epochTime();let dt=min(now-last,0.1);last=now
    if replayMode and seek>=0:
      let target=min(seek,recording.frames.len)
      if target<world.tick:world=newWorld(recording.seed)
      while world.tick<target:advance()
      seek= -1
    if not paused:
      accumulator+=dt*TickRate.float*speed.float
      var steps=0
      while accumulator>=1 and steps<96:
        if replayMode and world.tick>=recording.frames.len:
          paused=true;break
        if world.winner>=0 or (not replayMode and world.tick>=options.maximumTicks):paused=true;break
        advance();accumulator-=1;inc steps
    glViewport(0,0,window.size.x.GLsizei,window.size.y.GLsizei)
    glClearColor(0.025,0.045,0.075,1)
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
    glDisable(GL_CULL_FACE)
    let vp=perspective(42'f32,window.size.x.float32/max(1,window.size.y).float32,0.1'f32,250'f32)*lookAt(vec3(32,62,65),vec3(32,0,20),vec3(0,1,0))
    shapes.clear()
    shapes.box(32,-0.5,20,33,0.5,21,rgbx(24,44,53,255))
    for x in 0..<32:
      for z in 0..<20:
        let color=if (x+z)mod 2==0:rgbx(44,72,76,255) else:rgbx(41,67,71,255)
        shapes.addQuad(vec3(x.float32*2,0,z.float32*2),vec3(x.float32*2+2,0,z.float32*2),vec3(x.float32*2+2,0,z.float32*2+2),vec3(x.float32*2,0,z.float32*2+2),color)
    for c in world.cover:
      shapes.box((c.x+c.w div 2).float32/100,0,(c.z+c.h div 2).float32/100,c.w.float32/200,1.7,c.h.float32/200,rgbx(108,130,128,255))
      shapes.box((c.x+c.w div 2).float32/100,1.7,(c.z+c.h div 2).float32/100,c.w.float32/200,0.13,c.h.float32/200,rgbx(166,191,172,255))
    for side in 0..1:
      let h=home(side)
      shapes.addCircle(vec3(h.x.float32/100,0.03,h.z.float32/100),2.2,teamColors[side])
      let flag=world.hearts[side]
      shapes.gem(vec3(flag.pos.x.float32/100,if flag.carrier<0:1.5 else:3.4,flag.pos.z.float32/100),0.65,teamColors[side])
    for i,c in world.cogs:
      if c.hp<=0:continue
      let x=c.pos.x.float32/100;let z=c.pos.z.float32/100;let color=teamColors[team(i)]
      shapes.box(x,0,z,0.36,1.05,0.36,color)
      shapes.box(x,1.05,z,0.43,0.55,0.43,color)
      shapes.box(x,1.23,z+0.42,0.31,0.18,0.07,rgbx(15,27,41,255))
      let d=direction(c.pos,c.aim,80)
      shapes.box(x+d.x.float32/100,0.65,z+d.z.float32/100,0.16,0.2,0.35,rgbx(220,225,216,255))
      for hp in 0..<c.hp:
        shapes.box(x-0.4+hp.float32*0.3,2,z,0.12,0.12,0.12,rgbx(183,251,169,255))
    for b in world.balls:shapes.gem(vec3(b.pos.x.float32/100,0.8,b.pos.z.float32/100),0.18,teamColors[team(b.owner.int)])
    shapes.draw(vp);window.swapBuffers()
    when defined(emscripten):
      let tick=world.tick;let total=recording.frames.len;let red=world.captures[0];let blue=world.captures[1]
      {.emit:"EM_ASM({if(Module.polyworldFrame)Module.polyworldFrame($0,0);if(Module.paintbotHud)Module.paintbotHud($0,$1,$2,$3);}, `tick`, `total`, `red`, `blue`);".}
  while not window.closeRequested:pollEvents()
