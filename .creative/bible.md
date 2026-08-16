# Ghost Shift — art bible

From `.creative/refs/` (three stills of the shipped DOM wall — the reigning look,
preferred over every rebuild so far), README's Ghost Shift section and the design
comments in `wall/{wall.css,scene.js,index.html}`. Nothing invented.

## What it is

**A city at night, in the rain, seen from across a room.** One tower per project;
one lit car climbing it per running job, at the floor its pipeline stage has
reached; a district below where every shipped run pours a permanent building
(README.md:924-932, 950-969). Nothing is on the skyline that is not happening
now (`wall.css:1-3`); last week is a flat ghost silhouette behind it.

## Pillars and camera

- **Legibility beats decoration** (`wall.css:5-8`) — if it does not read at 3 m
  on a TV it is not there.
- **Depth by planes.** Three bands scale and veil what the renderer draws
  (`wall.css:863-867`); a sprite is authored once at full value, never pre-hazed.
- **Every object means something.** A sign that means nothing is texture, and this
  city does not do texture (`scene.js:126-130`).
- **Warm first, cold second** (`wall.css:47-59`) — pale amber, dirty white and cold
  cyan are the window colours; shop signs are those turned up.

Flat elevation at street eye level, no perspective on façades (`wall.css:2158-2167`).
Light comes from inside the buildings and from the signs; the sky is lit from
underneath by the city (`index.html:82-85`). Sky ships and rooftop lamps may glow;
nothing else may, because red belongs to an alarm and green to a run that just
shipped (`wall.css:1107-1108`). Module and scale: `.creative/proportions.md`.

## Palette

`.creative/palette.png` — 32 colours, one row of 1x1 swatches, the single lock
artefact. Twenty-two are `wall.css` `:root` tokens verbatim; ten are the stone and
brick ramp sampled from the refs (`palette.py extract`, then hand-pruned).

- **Night and stone** `#010306 #0a1220 #101e2a #15202e #1d2930 #253038 #2c4341 #14342d #525852 #79907e #96c3c8 #a9d9c6`
- **Warm masonry and light** `#531820 #5e3437 #4f4441 #e0a23c #e8cfa6 #ffc27d #ffc680 #ff9a5e`
- **Cold light and signage** `#7ad6ec #7fd4ec #deeaee #e6dfc8 #e4fff3 #4e7168`
- **Actor neon** (a car's tint is who is running it) `#4c9dff #3fd984 #4ff08f #2c9a61 #9fe8b8 #ff2f45`

## Do / Don't

- Keep a luminance floor — the wall measures 42 % pure black; read as a night, not
  a hole. Distinct near / mid / far silhouettes, flat within each.
- Nothing under ~3 px of stroke. Lettering is Latin or the wall's own CJK
  signage (shopfronts 麵 食 樂 修, `scene.js:126-130`; landmark 冉) — owner's
  call, 2026-08-16: the Chinese stays. Any other lettering is none.
- No noir flood (one colour plus black is an unlit render), and no dashboard-y flat
  elevation — no even density, no grid of identical bays.
- No invented lettering. The first live batch put "LUATA" on a prop and garbled neon
  on a blank sign; type gets drawn, not hallucinated.

## References

`.creative/refs/wall-0{1,2,3}.png` (the reigning champion); `.creative/demo/asset-sheet.png` is the first factory batch judged against this.
