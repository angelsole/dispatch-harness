# Default app-UI rubric

The six axes the critic scores, 1–5, when `VISUAL_KIND=ui` and the target repo
ships no `.creative/rubric.md` of its own. A repo with a design system should
write its own — this one is deliberately generic, and generic is the weakest
form of this artefact.

This is the counterpart of `rubric.md`, which grades pixel art. Nothing here
asks about grid pitch or palette conformance: an app frontend is anti-aliased
by construction, so those numbers mean nothing about it, and what actually
breaks an app screen is layout, type, spacing, contrast and hierarchy.

Scores are **advisory**. The trustworthy signals are the deterministic checks
and the pairwise verdict between the two renders; a per-axis number from a VLM
is noisy in absolute terms and calibrated by nothing.

A rubric is pasted verbatim into a call that is shown two images, called A and
B, and told nothing else about either one. So a rubric describes the target
look and never the images being compared — see this directory's `README.md`.

| Axis | 1 | 3 | 5 |
|---|---|---|---|
| `layout_integrity` | content overflows or is clipped; elements overlap; a panel is collapsed, stretched or off-screen | the layout holds but something is cramped or has stray empty space | every region is sized for its content; nothing clips, overlaps or overflows at this viewport |
| `typography` | mixed unrelated sizes and weights; text truncated mid-word or wrapped to one character; unreadable at this size | a workable scale with one or two sizes that fight each other | a deliberate type scale; every label legible; truncation, where it happens, is intentional and readable |
| `spacing_alignment` | nothing shares an edge; padding differs on every side; controls sit at arbitrary offsets | mostly aligned, with visible drift in one or two places | one spacing rhythm throughout; edges and baselines line up across regions |
| `color_contrast` | body text or a control is unreadable against its background; disabled and enabled look the same | readable, with low-contrast secondary text or a weak focus/hover state | comfortable contrast everywhere, including secondary text, borders and states |
| `visual_hierarchy` | everything shouts equally; no primary action; the eye has nowhere to land | a primary element exists but competes with decoration | the most important thing reads first, the rest in order, and emphasis is spent where it matters |
| `polish` | placeholder text, lorem ipsum, debug output, spinners, error toasts, broken images or empty states left on screen | finished but unconsidered — default shadows, mismatched icons, ragged borders | reads as shipped software: consistent icons and corners, considered empty and loading states, no stray artefacts |

**Grading posture.** You are grading someone else's work, and the person who
asked for the grade wants the truth, not encouragement. Do not soften. A 3 is
"acceptable and unremarkable", not "good". Name what is wrong in the image —
a specific tile, a specific element — never a general impression.
