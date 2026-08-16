# Ghost Shift — proportions

Read out of the code that already draws the city, and nothing else. The wall is
laid out in `rem` and `vh`, so every pixel figure below is stated at the
viewport the visual gate renders — **1280x720, dpr 1** (`.creative/visual.conf.sh:38-40`)
— where `html { font-size: clamp(12px, 1.05vw, 26px) }` (`wall/wall.css:96`)
resolves to **1rem = 13.44 px** and **1vh = 7.2 px**. On the office 4K panel the
clamp tops out at 26 px, so everything roughly doubles; author assets for the
ratios, not for these absolute numbers.

## The module

**16 px = one district tile. 32 px = one façade panel.** That is the smallest
pair that survives the finest repeating unit the city already draws: a district
block's façade cell is `--row: 0.3rem` by `--col: 0.2rem`
(`wall/wall.css:837-838`) = 4.0 x 2.7 px, and a tower's is `--row: 0.44rem` by
`--col: 0.3rem` (`wall/wall.css:478-479`) = 5.9 x 4.0 px. A 32 px panel carries
five to eight of those cells across, which is the density the shipped city has.

## Measured elements

| Element | Source | At 1280x720 |
|---|---|---|
| district block façade width | `--facade: 2.9rem * --deep * --wide * --form-wide * --jitter` (`wall.css:844`) | 39.0 px x factors; a mid-band residential shophouse ≈ 42 px |
| district block height | `(3.4vh + --storeys * 1.9vh) * --deep * --tall * --form-tall * --jitter-tall` (`wall.css:850`) | 24.5 px + 13.7 px per storey, x factors |
| shopfront sign strip | `.block__shop` height `0.44rem` (`wall.css:967`) | 5.9 px |
| shopfront glyph | `min(0.78rem, --facade * 0.3)` (`wall.css:1026`) | ≤ 10.5 px |
| tower storey pitch | `--row` 0.36–0.56rem by shape (`wall.css:620-623`) | 4.8–7.5 px |
| tower bay width | `--col` 0.24–0.42rem by shape (`wall.css:620-623`) | 3.2–5.6 px |
| tower crown | `2.6rem` (`wall.css:513`) | 34.9 px |
| lift car (a running job) | `1.3rem x 0.74rem` (`wall.css:1536-1537`) | 17.5 x 9.9 px |
| street walker | `0.3rem x 0.72rem` (`wall.css:1365-1366`) | 4.0 x 9.7 px |
| street robot | `0.4rem x 0.42rem` (`wall.css:1382-1383`) | 5.4 x 5.6 px |
| street car | `3.2rem x 0.14rem` (`wall.css:1403-1404`) | 43.0 x 1.9 px |
| foreground car | `4.2rem x 0.16rem` (`wall.css:319-320`) | 56.4 x 2.2 px |
| tram | `5.2rem x 0.46rem` (`wall.css:1460-1461`) | 69.9 x 6.2 px |
| sky ship | `1.1rem x 0.14rem` (`wall.css:241-242`) | 14.8 x 1.9 px |
| ground line above the bottom edge | `--ground: 9vh` (`wall.css:74`) | 64.8 px |
| district band height | `56vh` (`wall.css:810`) | 403 px |
| skyline band height | `74vh` (`wall.css:397`) | 533 px |

## Ratios that must hold

- **A person is ~10 px tall and a district storey is ~14 px.** A walker is
  therefore about two thirds of one storey — so a 16 px character sprite stands
  a little over one storey, and a 32 px one is a landmark, not a pedestrian.
- **A street car is ~43 px long and ~10 px of that is above the roadway.** At
  the 16 px module a vehicle is two to three tiles long and under one tall.
- **A shopfront sign is ~6 px tall and its glyph caps at ~10 px.** Nothing
  smaller than 3 px of stroke will read; lettering below that is texture, and
  this city does not do texture (`wall/scene.js:126-130`).
- **Legibility target is the office TV, not the laptop.** The gate scores
  edge energy surviving a downscale to 480x270 with a floor of 0.35
  (`.creative/visual.conf.sh:90`), i.e. a feature under ~3 px at 1280 is gone
  by the time it reaches the room.

## Derived, not drawn

- **Tower height** = `min(94, 48 + runs * 8)` percent of the skyline band, width
  = `3.4rem + min(runs, 8) * 2.2rem` (`wall/scene.js:321-323`) — so a tower is
  45.7–164 px wide and 48–94 % of 533 px tall. Author façade panels to tile
  across that whole width range, never to fit one of them.
- **District block height** comes from the run's diff, log-scaled and capped
  (README.md:962), through `--storeys`; the landmark pins `--storeys: 16`
  (`wall/wall.css:1233`, `wall/scene.js:270`).
- **Depth bands** scale everything by `--deep` 0.74 / 0.92 / 1.12 and veil it by
  `--veil` 0.62 / 0.34 / 0.12 (`wall/wall.css:865-867`). An asset is drawn once
  at full value; the far band is produced by the renderer, so do not bake haze
  into a sprite.
- **The ghost silhouette** (last week's city) lives in the sky SVG's own
  1600x900 space: block width 40, base height 31, +17 per storey, ground at
  y=819 (`wall/scene.js:45-51`).
