# The wall's private art packs

Everything in this directory except this file is **gitignored on purpose**. It
is bought pixel art, licensed to the machine the wall runs on, and the doctrine
that keeps the wall offline — *nothing the wall needs leaves this machine* —
cuts both ways: these bytes do not leave it either, so they are never committed
and never appear in a diff, a PR or a screenshot repository.

`wall/vendor/` is the opposite case and stays where it is: redistributable MIT
code, committed, and pinned by hash in `wall/THIRD_PARTY.md`. Nothing here is
listed there, because nothing here ships.

## What goes here

Two packs by the same artist, bought from itch.io. Restore them by copying the
folders out of the purchased archives, keeping the pack's own folder and file
names:

| directory | pack | bought from |
|---|---|---|
| `cyberpunk-rooftops/` | *Cyberpunk Rooftops* — 2D pixel art platformer asset pack | itch.io, personal licence |
| `cybercity/` | *CyberCity (Dog)* — 2D pixel art platformer asset pack | itch.io, personal licence |

The two packs share their skyline planes, terrain sheet and character sheets
byte for byte (`CyberCity` misspells its background directory `Nackgroud`), so
only `cyberpunk-rooftops/` has to be present for `?world=sideview` to draw. The
exact files it asks for are the declared list at the top of
`wall/world-sideview.js`; nothing else is ever fetched.

Layout, as the world expects it:

```
wall/private/cyberpunk-rooftops/
  Backgroud/BACKGROUND (1)/Backgroud (1) 1..16.png   water, 16 frames
  Backgroud/BACKGROUND (2)/Backgroud (2) 1.png       near buildings
  Backgroud/BACKGROUND (3)/Backgroud (3) 1.png       the neon district
  Backgroud/BACKGROUND (4)/Backgroud (4) 1..16.png   elevated highway, 16 frames
  Backgroud/BACKGROUND (5)/Backgroud (5) 1.png       far silhouette
  Backgroud/BACKGROUND (6)/Backgroud (6) 1.png       sky and clouds
  Terrain/Terrain.png                                walls, girders, terminals, machines
  character/Player 96X96 (1).png                     hero sheet, 10x19 frames of 96x96
  Character (2)/Player 96X96 (1).png                 the second hero sheet
```

## How it is served

`wall/server.js` has one route for this directory, `/private/<path>`, and it is
deliberately the narrowest thing that can work: it decodes the path once,
refuses NUL, `..` and absolute paths, resolves the result and refuses anything
that does not land under this directory, allows only `.png` and `.json`, and
404s on everything else. There is no directory listing and no walk.
