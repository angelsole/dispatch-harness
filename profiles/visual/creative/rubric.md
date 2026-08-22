# Default visual rubric

The six axes the critic scores, 1–5, when the target repo ships no
`.creative/rubric.md` of its own. A repo with an art bible should write its
own — this one is deliberately generic, and generic is the weakest form of
this artefact.

Scores are **advisory**. The trustworthy signals are the deterministic checks
and the pairwise verdict between the two renders; a per-axis number from a VLM
is noisy in absolute terms and calibrated by nothing.

A rubric is pasted verbatim into a call that is shown two images, called A and
B, and told nothing else about either one. So a rubric describes the target
look and never the images being compared — see this directory's `README.md`.

| Axis | 1 | 3 | 5 |
|---|---|---|---|
| `palette_discipline` | many colours from nowhere; gradients and blends fight the locked palette | mostly on-palette, a few strays | every colour is a palette colour, used with intent |
| `grid_discipline` | sprites scaled to fractions, mixed pixel sizes, soft edges everywhere | one dominant grid with lapses | one pixel size, everything on it, edges hard |
| `silhouette_readability` | shapes merge into each other and into the background | main shapes read, secondary ones mush | every element reads by outline alone, at a glance |
| `composition` | no focal point; density even and flat; the eye has nowhere to go | a focal point exists but competes | clear hierarchy, depth, and negative space that works |
| `animation_continuity` | frames jump; things teleport or flicker between them | motion is continuous but arbitrary | motion has weight and timing; the frames read as one shot |
| `style_match_to_reference` | a different visual language from the reference board | the same family, uneven | indistinguishable in language from the references |

**Grading posture.** You are grading someone else's work, and the person who
asked for the grade wants the truth, not encouragement. Do not soften. A 3 is
"acceptable and unremarkable", not "good". Name what is wrong in the image —
a specific tile, a specific element — never a general impression.
