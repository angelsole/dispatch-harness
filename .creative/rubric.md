# Ghost Shift — what the wall is graded on

The wall is an office-TV dashboard that has to read as a **city at night in a
game**, from three metres away, at a glance, while it is also telling the truth
about every run on the machine. The six axes below are the schema's; what each
one means *here* is this file's job.

Grade the render in front of you. Do not soften, do not credit intent, and do
not reward density: this city has failed before by answering "flat" with "more
objects".

| Axis | What it means for the wall |
|---|---|
| `palette_discipline` | The night palette: deep blue-black sky, warm window amber, one red for alarm and one green for success. A colour that is none of those, or an alarm red used for anything but an alarm, is a stray. |
| `grid_discipline` | The city's own geometry — towers, windows, slabs, street — sits on one consistent pixel grid. HUD chrome and volumetric light are allowed to be smooth; a tower whose windows drift off their own rhythm is not. |
| `silhouette_readability` | Every tower reads as a distinct shape against the sky, and the lit cars read against the tower. Merged masses and towers distinguishable only by their labels score low. |
| `composition` | One hero (the tower a human must look at now), depth planes that separate, and sky left to breathe. Even, edge-to-edge density is the failure this axis exists to catch. |
| `animation_continuity` | Consecutive tiles read as one continuous shot: things move, and what moves keeps moving in the same direction. Fresh random scatter in every tile is flicker, not motion. |
| `style_match_to_reference` | The reference board in `.creative/refs/` is the shipped DOM city. A render may be better than the board, but it must be the same city — same world, same light, same visual language. |

**Pass** means: you would put this on the office TV in front of the team that
ships from it. Anything else fails.

## Inside a room

The camera goes indoors, and the same six axes read like this once it has.
Palette: a night room, the monitor cold and the lamp warm, red only for an
alarm and green only for shipped. Grid: a whole-number scale of the authored
canvas, every sprite on its own pixel grid. Silhouette: the worker and the desk
read at three metres. Composition: window, desk, foreground — three planes that
separate. Continuity: a loop that advances and a push that never reverses.
Style match: the same city, seen through the window.
