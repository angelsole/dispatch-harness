<!-- Template. Copy to `.creative/proportions.md` in the target repo. Fill it in
     from the code that already draws the scene — constants, CSS custom
     properties, layout numbers — and from nothing else. A proportion card
     invented rather than read is how a sprite set arrives at the wrong scale
     and every asset has to be remade. Cite file:line for each row. -->

# <project> — proportions

The module: **N px = one <unit>**. Everything below is a multiple of it.

| Element | Size (px) | Source |
|---|---|---|
| tile | | `file:line` |
| storey | | |
| person | | |
| vehicle | | |
| door / window | | |
| ground line offset | | |
| shopfront sign | | |

## Ratios that must hold

- A person is N px; a storey is M px; a car is K px long. State the ratios so a
  generated asset can be rejected on arithmetic rather than on opinion.
- What the smallest legible feature is at the viewing distance the project is
  designed for, and therefore what detail is not worth drawing.

## What is derived, not drawn

Anything the renderer computes (heights from a data value, depth-band scale
factors, jitter). Note the formula and its bounds so assets are authored for the
range, not for the median.
