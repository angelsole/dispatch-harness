# The wall's own art

Everything under `wall/assets/` was **generated for this repo** — no upstream,
no licence to travel with it, nothing anybody else wrote. That makes it the
other half of `wall/THIRD_PARTY.md` rather than a row in it: same doctrine
(*nothing the wall needs leaves this machine*), same pin (a row per file, with
the hash it was committed at), different provenance question. Third-party code
asks "which build of somebody else's work is this?"; a sprite asks "what made
it, from what prompt, at what seed?".

A row is the pin. Changing a file under `wall/assets/` without updating its row
here fails `tests/wall.test.sh`, which re-hashes every non-markdown file in this
directory and compares — exactly as it does for `wall/vendor/`.

## How they were made

Through the creative harness's asset factory and the PixelLab MCP one-off path,
both driving [PixelLab](https://pixellab.ai). Every file then went through
`postpass.py` against `.creative/palette.png`, so **every pixel of every sprite
is one of the 32 colours the wall is locked to** — the suite re-checks that from
the committed PNGs rather than taking the post-pass's word for it.

Two rules the prompts are written to, both from `.creative/bible.md`:

- **No invented lettering.** Nothing generated here carries type. Every word in
  the room — the stage, the ticket, the repo, the floor, the dispatcher — is
  drawn a pixel at a time by `wall/room.js`, out of two bitmap faces set by
  hand in that file. An earlier batch put `LUATA` on a prop and a garbled neon
  sign on a blank one; those were thrown away rather than retouched.
- **An asset is authored at full value.** Nothing here has shadow, haze or
  distance baked into it. The room draws the near plane dark and the desk sunk
  because that is the renderer's job, which is also why the same desk sprite can
  be a lit surface under the lamp and a silhouette three pixels to the left.
- **Green is a word here, not a colour.** In this palette green means *shipped*,
  so a prop may not wear the success ramp. `room/plant.png` came back from the
  generator in mint and emerald and was recoloured pixel for pixel onto the cold
  ramp — `#9fe8b8` to `#2c4341`, `#2c9a61` to `#253038`, `#14342d` left where it
  was. Same shapes, same lock, one hash to update and no second generation: a
  colour that means the wrong thing is a recolour, not a re-roll. `room/lamp.png`
  had one pixel of `#3fd984` in the middle of its bulb, which the post-pass
  quantiser is entitled to choose and the palette rule is not; it now carries the
  bulb's own highlight. The suite refuses the whole ramp from here on.

## The room

`?shot=room`, and the destination of the director's dive.

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `room/desk.png` | one desk unit; three of them, one mirrored, make the run | pixellab.image | `/create-image-pixflux` | `room-desk` | `17430` | 2026-08-16 | generated for this repo | `5fe2730bb3b819ba019697335b4ded6ccce83cf93ac092cd2122f2c2362d6f3f` |
| `room/floor.png` | the floor, same idea | pixellab.image | `/create-image-pixflux` | `room-floor` | `17433` | 2026-08-16 | generated for this repo | `c73b195a72315d3282382986e40ae413ffebd5caf6571fed99f9e5648b345f8c` |
| `room/lamp.png` | the desk lamp - the warm light, in the dispatcher tint; one stray success-green pixel recoloured | pixellab.image + recolour | `/create-image-pixflux` | `room-lamp` | `3150714110` | 2026-08-16 | generated for this repo | `b0c1a8d1691e14cc4b2a119c73161240651c81723f48911d48929925cdd1ee1f` |
| `room/plant.png` | near plane, left; recoloured off the shipped-green ramp | pixellab.image + recolour | `/create-image-pixflux` | `room-plant` | `3855081884` | 2026-08-16 | generated for this repo | `20e42a2f62602dba9b66ec2b4c6bf0374e456ac30aa909c60226b59245aa84e2` |
| `room/shelf.png` | near plane, right | pixellab.image | `/create-image-pixflux` | `room-shelf` | `17434` | 2026-08-16 | generated for this repo | `3900279ad40d192dcbf515982f62a2f893c9fd2c78e316d36a7835e65b26b1e1` |
| `room/wall.png` | the back wall, as grain over a flat value | pixellab.image | `/create-image-pixflux` | `room-wall` | `17432` | 2026-08-16 | generated for this repo | `fbff77b5d7a982300ec61a8228a18a498e7dabfb9345f8cf944b1dbd19ddad4f` |
| `room/window.png` | the window frame and its rolled blind; the glass was flooded out so the page can draw the city through it | pixellab.image | `/create-image-pixflux` | `room-window` | `17431` | 2026-08-16 | generated for this repo | `d742f8b5831615bceb7077c0818b7f5ee2417b3e46d486ec3029e2a0cad1d1e4` |
| `room/worker-type-0.png` | the worker, hands on the keyboard - the base frame every other one is derived from | pixellab.image | `/create-image-pixflux` | `room-worker` | `17420` | 2026-08-16 | generated for this repo | `fda5c0a177c8ad2de6d32c65ead96c9a3bad5b32fdfcc429f910da8a384a4782` |
| `room/worker-type-1.png` | typing, frame 2 of 4 | pixellab.animate | `/animate-with-text-v3` | `room-worker-type` | `17421` | 2026-08-16 | generated for this repo | `158b84929ae5109a0e7c7fb1ee7f08b1be5138355261582e3690a1c1bd26014b` |
| `room/worker-type-2.png` | typing, frame 3 of 4 | pixellab.animate | `/animate-with-text-v3` | `room-worker-type` | `17421` | 2026-08-16 | generated for this repo | `acc65a6aac17aee49b27be146f14f111002b57c0fbe7cedca2ae9393d438d1eb` |
| `room/worker-type-3.png` | typing, frame 4 of 4 | pixellab.animate | `/animate-with-text-v3` | `room-worker-type` | `17421` | 2026-08-16 | generated for this repo | `8fbb112827b082f9e220a39aea83791a21a3e89312993ec393f4d8f01efe792f` |
| `room/worker-wait-1.png` | waiting, hands off the keys - what a blocked run looks like | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait` | `17422` | 2026-08-16 | generated for this repo | `88a8e6f0a6d7bd994dc9f76d8d94974cd08f914bbcdd54cfdf483c3e00373cbc` |
| `room/worker-wait-2.png` | waiting, second frame | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait` | `17422` | 2026-08-16 | generated for this repo | `cd6dcf0dc6d28d2bfca35e085c71b288e7e21ebd2a89d111fc105abfbcd4eb57` |
| `room/worker-type8-0.png` | typing, pose 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `210ed4fcc4bfc10bc5750c5487b3a22291cd43203f9d48f2bf797d4acda04920` |
| `room/worker-type8-1.png` | typing, pose 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `0f586baa7416e0f03047309c0fd86947f237ff43fbfdb851fb27f7b4ee240654` |
| `room/worker-type8-2.png` | typing, pose 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `ee72601a7a5562f4b9cb8634d812726454dbd9ccff3fb34b4f112c3a53b01d4b` |
| `room/worker-type8-3.png` | typing, pose 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `aad0e7f2b92304bce8bd8a4effbf337e589bd76d94d247282e5aee08099a46cc` |
| `room/worker-type8-4.png` | typing, pose 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `c32c52ad5d641fc10c5b178f883783f1a3844daa66d3a2a60262529d295f461b` |
| `room/worker-type8-5.png` | typing, pose 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `1b3aef9aa278bdda893edd61347649d58ce2cef1578c1fa5b382cfff6beb9916` |
| `room/worker-type8-6.png` | typing, pose 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `cc43c75ab12d7d77f1b96e80789e6d098c631d7199dbcb3d2ca74733b0308c78` |
| `room/worker-type8-7.png` | typing, pose 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-type8` | `17921` | 2026-08-17 | generated for this repo | `e82c8ad5b0a54204a2a353ac838eaa958460669ac43ccd240bd22902edf038f8` |
| `room/worker-wait8-0.png` | waiting, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `bcf16c95a9c98439103be28e067d69c3caf09785946d395a8185cf870fa9fc57` |
| `room/worker-wait8-1.png` | waiting, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `1ab80a29f3c7bb26f804a20c05be55d086921e88f60fda6d3ea46dd6eb23ef15` |
| `room/worker-wait8-2.png` | waiting, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `fd815319ea78254d9eb7c5f6a2faec3c4a04e9650b846445ead0585183bebd8a` |
| `room/worker-wait8-3.png` | waiting, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `3c8812128856771e91f9daf38df93ef99423f85ee49bcbee0963e86dd7f595cd` |
| `room/worker-wait8-4.png` | waiting, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `74e2be0cc2eeb8a18a1838c62f0ff84e2b323cb04a66ab83a92778085015b592` |
| `room/worker-wait8-5.png` | waiting, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `84ba67cb8d080a39dd570486b97d75221ce15e8bd081455d4888e43e341d349f` |
| `room/worker-wait8-6.png` | waiting, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `510bbe67cd10e0e40fcd66a1efc4c92372d7bc420f7c5c319631256a7e2fa16b` |
| `room/worker-wait8-7.png` | waiting, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-wait8` | `17972` | 2026-08-17 | generated for this repo | `49886ec8f3a6c355f41fa1240c9eac232d13429c9a031559d7c647bd626abdb5` |

The `prompt` column names the entry in `.creative/assets.json`, which carries
the wording each seed was drawn against. Every `animate` job took
`room/worker-type-0.png` as its first frame, which is why the whole figure —
the hood, the headphones, the jacket, the keyboard — is the same person in every
frame the room can show.

## Their things

The furniture above is the ROOM. These are the DESK, and a desk belongs to
somebody: `wall/crew.json` names two or three of them per owner, `wall/room.js`
holds the closed pool a line may pick from, and there are four places to put
them — beside the lamp, beside the monitor, on the wall over the desk, and in
the air in front of that wall, which is the one place no line may name.

The first assignment puts a DIFFERENT object in the place the eye lands on first,
on all four desks: Angel's mug, Emre's football, Ran's photograph, Reinier's
figurine. The mug is on two desks in two different places, which is what a mug
is. The line in `crew.json` is the point — each owner edits their own.

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `room/prop-mug.png` | a mug, for the desk | pixellab.image + halve + trim | `/create-image-pixflux` | `room-prop-mug` | `18520` | 2026-08-17 | generated for this repo | `c680e87651666df4268afdf46d945067a6382da362911efd6cb8075d1ea48637` |
| `room/prop-cactus.png` | a small cactus in a pot, for the desk | pixellab.image + halve + trim | `/create-image-pixflux` | `room-prop-cactus` | `18512` | 2026-08-17 | generated for this repo | `9235d7c876ad4e2c787b27803f7aa3f5bbab200a76a27bf3394ded7bafa24025` |
| `room/prop-books.png` | a stack of books, for the desk; one klaxon-red cover recoloured onto the palette's deep red | pixellab.image + recolour + halve + trim | `/create-image-pixflux` | `room-prop-books` | `18521` | 2026-08-17 | generated for this repo | `0098d2a62e6de5a2316f20ce3caae1a83b0b30fb6b7292aa18c4e7c36ed9efc1` |
| `room/prop-photo.png` | a framed photograph, for the desk | pixellab.image + halve + trim | `/create-image-pixflux` | `room-prop-photo` | `18523` | 2026-08-17 | generated for this repo | `5218a65059e4fa3baede822f902668a14c8435d3bf6f3675ea93acb1610932e7` |
| `room/prop-figurine.png` | a small toy figurine, for the desk | pixellab.image + halve + trim | `/create-image-pixflux` | `room-prop-figurine` | `18525` | 2026-08-17 | generated for this repo | `6ad29a722970b23eaad4cbebd3c86d39717be5d5cadc941972fb82d6f64dd0b7` |
| `room/prop-ball.png` | a football, for the desk | pixellab.image + halve + trim | `/create-image-pixflux` | `room-prop-ball` | `18526` | 2026-08-17 | generated for this repo | `e092f7d9f941d6a3c6fefb581eb9acab93562f616675c997bf27d6cc8d1f73d7` |
| `room/prop-poster.png` | a framed night landscape, for the wall | pixellab.image + trim | `/create-image-pixflux` | `room-prop-poster` | `18527` | 2026-08-17 | generated for this repo | `4e9f9ec53a15337fc88a1164621961c9307d8c5ace1d9e6e78389ecea5d148e6` |
| `room/prop-pennant.png` | a felt pennant, for the wall | pixellab.image + trim | `/create-image-pixflux` | `room-prop-pennant` | `18528` | 2026-08-17 | generated for this repo | `7539387a6ba16ab38c48226b3ae8de072c892ecf0d05e038acece3de34baa89b` |
| `room/prop-balloons.png` | a bunch of three party balloons, for the air; the klaxon-red rim recoloured onto the palette's deep red | pixellab.image + recolour + trim | `/create-image-pixflux` | `room-prop-balloons` | `18532` | 2026-08-18 | generated for this repo | `673ce10f331b4f469a3c64f12c1fc3884d840c27afbe5b307562a0f5a897b545` |

Three things about these files that the columns cannot say:

- **`halve` is not a resample.** The factory's smallest square canvas is 32x32 —
  its floor is 1024 px of area, so a 16x16 request is refused — and a mug drawn to
  fill 32x32 is a mug as tall as the desk lamp beside it. This room's scale is
  not negotiable: a person is 56 px and the lamp is 28, so a mug is 13. The desk
  props come down by exactly two, each 2x2 block voting: the winning opaque
  colour takes the output pixel, a block that is mostly transparent stays
  transparent. No new colour can appear and no edge goes soft. The two WALL props
  are not halved — a poster next to a 66 px window really is 24 px.
- **`trim` is why there is no padding table.** Every prop is cropped to its own
  drawing, so the committed file IS its content box and `room.js` places a thing
  by one corner. The furniture above still carries a `BOX` entry each, because
  those files predate the idea.
- **Two recolours, for meaning and never for value.** `prop-books` came back with
  a bright `#ff2f45` cover and `prop-balloons` with a fourteen-pixel rim of the
  same red, and in this palette that red is an alarm; both are on `#531820` now,
  pixel for pixel, the same call `room/plant.png` got when it came back in
  emerald. Nothing was recoloured for being too bright — an asset is authored at
  full value and the renderer is what veils it, which is why the football keeps
  its white and the room sinks it instead.

Ten props were generated and nine are here. `room-prop-headphones` was rolled
twice, at `18514` and `18524`, and came back both times as a spindle nobody would
read as headphones at 4x; it was thrown away rather than retouched, and the pool
is nine.

`room-prop-balloons` made it nine, and it is the only one of them nobody owns: a
line in `crew.json` cannot ask for it. It is granted by a DATE — the `birthday`
on somebody's roster entry, against the day the server says it is — and it hangs
in the air on the lamp's side of the room for that day only. Four rolls at
`18530`, `18531`, `18532` and `18534`: the first put the three balloons on one
thick bouquet stem, the second read the prompt's "side by side" literally and
returned three separate balloons with no strings at all, and the fourth came back
as flowers. `18532` is the one with three balloons clustered and something
hanging, which at 19x28 against a dark wall is what a bunch of balloons is.

## Eight frames, and a head that holds

`type-0..3` and `wait-1/2` are the four-and-two the room shipped with, and they
are still here: the room does not draw them any more, and this table is what a
diff of old against new is read from.

What replaced them, and why, in numbers measured off these files:

- **Four poses at 300 ms is 3.3 a second.** At 4x on a preview — 12 device
  pixels per authored one on the office panel — that is a slideshow, and the
  wrap from pose 4 back to pose 1 was the largest jump of the four. Eight poses
  at 120 ms is 8.3 a second, which is where a hand starts reading as a hand.
- **A generator asked to move two hands redraws the whole person.** Between two
  consecutive poses of the old loop 398-859 pixels of the room worker changed
  (up to 832 on Emre) — 10-21 % of the sprite — and most of it was the hood, the
  headphones, the shoulders and the jacket outline reflowing while the hands
  barely travelled. The same is true of the new frames: each differs from its
  base by 93-809 pixels ABOVE the split. The difference is that the room now
  throws every one of those rows away.
- **So the head is pinned at draw time.** `wall/room.js` composites every worker
  from two bands: the set's base above a per-set split row, the cycle's own
  frame below it. Room 41, Angel 41, Emre 43, Ran 40 — each chosen as the row
  whose worst single-frame silhouette mismatch against the base is smallest
  among the rows that still leave the forearms and hands in the animated band
  (one pixel in one frame for the room and Angel, one in seven of sixteen for
  Emre, two for Ran, whose sleeve is the widest edge in any of these boxes).
- **Which is where the pose lock is measured.** Every generated frame carries a
  redrawn head, and **the room discards those rows** — so a frame's own bounds are
  a fact about the animator, not about the picture, and they are not what the lock
  is checked against. `tests/wall.test.sh` measures the two things that are on the
  wall, over these PNGs, through `room.js`'s own splits:
  - the **drawn composite** — the base above the split plus the frame at and
    below it — within **±1 px** of the set's base box. Worst across all
    sixty-four: **1 px**.
  - the **animated band alone**, x / width / bottom edge, within **±3 px** of the
    base's same rows, so the arms cannot float or slide behind a head that is
    holding the top of the box steady. Worst: **2 px**.

  For the record, the raw frames drift up to 8 px on their own, always in the same
  direction — the head growing upward, into rows nothing draws. The bases are the
  committed ones and their drift from `room/worker-type-0.png`'s 56x53+4+7 is what
  PR #44 recorded: room 0/0/0/0, Angel -3/+2/+1/-2, Emre +2/+3/-4/0, Ran
  +2/-2/-2/-2.
- **And the frames were requested from the committed faces, not from a new roll.**
  Each base was regenerated at its committed seed first: none came back
  byte-identical (2592-3894 pixels differ, and the room worker's box moved to
  59x52+2+7), so none was adopted. The factory's body-hash cache was primed with
  the committed PNG instead, so what every one of the eight `animate` jobs was
  handed as `first_frame` is the committed base, byte for byte. That is the
  provenance claim, and the primed cache is what makes it true for all eight.
  What the endpoint *returns* as its own frame 0 is a redraw of that input like
  every other frame it returns; none of the eight frame zeros is committed,
  because the set already has that file as `base`.

Between consecutive drawn frames, 72-381 pixels change, all of them below the
split. Nothing here was retouched by hand.

## The crew

Who is at the desk, by the owner of the run — `wall/crew.json` maps a lane key
to one of these directories, and an owner with no entry gets the room's own
worker above. Each set is a base still made the way `room-worker` was, then the
same two `animate` jobs over it, so the person in every frame is the person in
the base.

`base.png` used to be the one file in a set that was never drawn: the **pose
lock**, the frame the `animate` jobs were handed, and the file the ±3 px check
below is run against. It is now the most-drawn file of the four sets — every
worker on the wall is `base.png` above the split and one cycle frame below it —
so it comes down the asset route with the rest, and the suite asks for it through
`FRAMES` rather than as a special case.

The room draws `base` plus `type8-0..7` and `wait8-0..7`; `type-0..3` and
`wait-1/2` are the old four-and-two and stay in the repo for the diff. The eight
of each cycle are the animate job's frames 1-8. Its frame 0 is that job's own
redraw of the first frame it was handed, and is not committed for any set — the
set already has the file it was handed, as `base`.

The rows each cycle frame carries **above** its set's split are not drawn: every
generated frame reflows the whole figure, and the room composites the base's head
band over all of them. Those rows are why a frame's own bounds are not the lock;
what is measured, from these PNGs, is in *Eight frames, and a head that holds*
below.

The lock is `room/worker-type-0.png`: opaque bounds **56x53 at +4+7** in a 64x64
canvas, seated, facing the viewer, hands on the keyboard, the same light. A new
character has to land in that box to be able to replace the worker at the same
room position, and `magick <file> -trim info:` is how that was checked. Where a
seed drifted it was re-rolled rather than retouched. What shipped:

| set | base | drift from the lock | frames |
|---|---|---|---|
| `crew/angel` | 56x55+4+5 | 0, +2, 0, -2 | 56 wide, 55 tall, every frame |
| `crew/emre` | 58x56+0+7 | +2, +3, **-4**, 0 | 56-58 wide, 56-61 tall |
| `crew/ran` | 58x51+2+5 | +2, -2, -2, -2 | 56-59 wide, 50-52 tall |

Angel and Ran are inside ±3 on all four numbers. Emre sits one pixel outside on
x and his frames run taller than the others': fifteen seeds produced either a
figure in the box whose face was lost to a bowed head and baked-in warm light,
or a legible one a few pixels out, and legibility is the first pillar of
`.creative/bible.md`. For scale, the room's own worker set spans 56x53+4+7 to
56x56+4+4 — ±3 is the breathing room a four-frame typing loop uses up by
itself, not a tolerance any of these had spare.

The eight-frame cycles gave that tolerance back rather than spending more of it.
Their raw frames drift up to 8 px on their own — Emre's `wait8` reaches
56x61+0+2, all of it the head growing upward into rows nothing draws — but the box
the room puts on the wall is each base's own to within **1 px** for all
sixty-four, and each animated band holds its base's x, width and bottom edge to
within **2 px**. Both are asserted from these PNGs by `tests/wall.test.sh`.

## Angel, on the owner's own description

`crew/angel` was regenerated on the owner's word: *short hair, a full beard, brown
hair with grey at the sides.* The set it replaces had messy shoulder-length dark
hair and a short beard, and was simply the wrong person. Everything else about the
entry is unchanged — seated, facing the viewer, forearms on a keyboard, olive
jacket over a pale tee, head and torso and arms only, no background.

Four seeds were drawn against the new wording and all four are in
`.harness/angel-candidates.png` at 4x, so the pick can be argued with by seed.
**18470** is the one committed. It was chosen on the description read off the
pixels rather than off an impression: its hair is `#4f4441` brown with `#525852`
and `#79907e` at both temples and down both sideburns, the beard is a full warm
mass over the whole jaw, and the hair is short. 18472 has the grey more obviously
at the sides but reads grey-haired overall and sits 4 px wider than the pose lock;
18471 and 18473 lose the face to warm blocks at 4x. 18470 is also the only one of
the four inside ±3 of `room/worker-type-0.png` on all four numbers.

The typing cycle took five `animate` jobs to land, and the reason is worth
writing down because it is not about seeds. This base's SLEEVES set the animated
band's outer columns, and the first prompt — the one both the room worker and the
previous Angel used, *"the fingers strike down onto the keys in a rolling wave and
the wrists lift and fall between strokes"* — made the animator lean the figure in:
the elbows came together and the band lost 4 px of width at mid-cycle, over the
±3 ceiling. Two more seeds of the same wording measured 5 and 6 px, and pinning
the last frame to the base (interpolating a closed loop instead of an open one)
measured 6. What fixed it was the wording, at the first seed it was tried on:
naming every part that must NOT move — *"and nothing else in the picture moves at
all: the forearms, the elbows, the sleeves, the shoulders, the jacket, the head
and the keyboard all stay exactly where they are and keep exactly the same
width"*. Seed `18945` holds the base's box and its animated band to **0 px** on
all sixteen frames, at every split row from 36 to 47.

What that costs is range: 57 to 321 band pixels change between consecutive drawn
frames, against 72-381 for the room's own worker, and one pair (poses 4 and 5) is
quieter than the room's floor. The hands still travel — `.harness/angel-hands-strip.png`
is 24 real-time frames at 8 fps off the running room — and a set that reads as
typing everywhere beats a set that reads as leaning in twice a second.

`wait8` needed one job: seed `18992` holds x, width and bottom to 0 px on all
eight.

The four-and-two under `crew/angel/` — `type-0..3` and `wait-1/2` — are the
PREVIOUS Angel's, kept exactly as they were, and the room has not drawn them since
the eight-frame cycles landed. `.creative/assets.json` keeps the wording and seed
they were drawn against in the `was` field of the rewritten entries, which is what
makes those rows still readable.

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `crew/angel/base.png` | the still every other frame of this set came from - the pose lock; regenerated to the owner's own description | pixellab.image | `/create-image-pixflux` | `crew-angel` | `18470` | 2026-08-17 | generated for this repo | `c5cd0e59b2c289f04f995d00221f0c6c34a2a16805a7fcbdb41a8667bf875f72` |
| `crew/angel/type-0.png` | typing, frame 1 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `5a6bfb0d11f1fceff9c88fc2581a3cf703998505a86b310568c6bd360411fb4f` |
| `crew/angel/type-1.png` | typing, frame 2 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `dd94a5ec4d18d53a6b5a3ab2ba7772936f399369314aa6e5f8ab81e6d904080b` |
| `crew/angel/type-2.png` | typing, frame 3 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `d813b773bae1924c34986c94d1e838d9f15757f0efc33e573306d4ed00c5b45f` |
| `crew/angel/type-3.png` | typing, frame 4 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `62c92abbab003edfa41ab5930d834245de25c342e9c466fca3821a6972862666` |
| `crew/angel/wait-1.png` | waiting, hands off the keys - what a blocked run looks like | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait` | `17442` | 2026-08-17 | generated for this repo | `b6128840fcdb440e6002935e951434c3f27d8fb532e2f6bea893f6276b4df58f` |
| `crew/angel/wait-2.png` | waiting, second frame | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait` | `17442` | 2026-08-17 | generated for this repo | `4630d173fe12565d5b1a0039e9636d27f06d4dd469601f1825105a2ab8176203` |
| `crew/angel/type8-0.png` | typing, pose 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `00019722038232f6c408eb7de26371d0e44893a652c14276c1c03ea32374fcf2` |
| `crew/angel/type8-1.png` | typing, pose 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `f7c2bb8f2d5f67d8706791b1650b300568cc86ca41b003dcdd9d65dfe181ba50` |
| `crew/angel/type8-2.png` | typing, pose 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `b7bade82dde9d4c980246cbff2a4bffb79a5ba2cdfa7e418c53c7090c414ec3f` |
| `crew/angel/type8-3.png` | typing, pose 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `13410c4c8eb78b9988f2f94247095f7a1c379b5641d90dc8d85e85bcb7e02773` |
| `crew/angel/type8-4.png` | typing, pose 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `1e0243e5ca93f3ded766b496c18d53d5b158ecfc749d0bf7378b121312f5813a` |
| `crew/angel/type8-5.png` | typing, pose 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `b7b97530810bb1f7fae9ad0c8cd1bae3925a4c15a86c0afbf887b154d70b812b` |
| `crew/angel/type8-6.png` | typing, pose 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `f8091b44bc754d45b3355ae898ceaa599491b729fbb24798cf51efea9d250657` |
| `crew/angel/type8-7.png` | typing, pose 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `18945` | 2026-08-17 | generated for this repo | `88f2762a2b7c7a8b9ac45f4a46c04338ecf974905567716f7b71c37493494dd1` |
| `crew/angel/wait8-0.png` | waiting, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `c25114660e812d29db60eaad61be1c19f1877c6d05a8fe24b18bdd9a4e30a6c4` |
| `crew/angel/wait8-1.png` | waiting, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `3081c37b9b2cce979e3455577ad03ed6a56e09006a836288f433e1b59cf8cdbb` |
| `crew/angel/wait8-2.png` | waiting, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `a8283f29eb8b875505acde96fb071ee0ccd2944eb60d5c9bdb8cc25a672b1e52` |
| `crew/angel/wait8-3.png` | waiting, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `46c714d07a2ddb6719f595b6f27814f86d3ec34e3e9bdec623a480c09796520d` |
| `crew/angel/wait8-4.png` | waiting, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `f92d22a6f9c88932e69033819c797247e09cb119156707879604041e5ab63ecc` |
| `crew/angel/wait8-5.png` | waiting, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `897249936713c782ff2334416d943cf6e7eacb60a5064605f6d186476d1e535c` |
| `crew/angel/wait8-6.png` | waiting, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `2aa863fc97bc0ec4e4bea5a1915fd364d3f1399d50045f28a7aaa0a4e5e7970e` |
| `crew/angel/wait8-7.png` | waiting, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `18992` | 2026-08-17 | generated for this repo | `957f0c62e29f8ccc0f91e0a4c62f8a10617157b9fc1e7b1d902ebd878e541756` |
| `crew/emre/base.png` | the still every other frame of this set came from - the pose lock | pixellab.image | `/create-image-pixflux` | `crew-emre` | `17455` | 2026-08-17 | generated for this repo | `e0ab7cf5c27ca7003b967117c0f5efe2dd4d7896b1508cbdaf50060208709ea1` |
| `crew/emre/type-0.png` | typing, frame 1 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type` | `17451` | 2026-08-17 | generated for this repo | `b89b7c3f6aa36cbef099869884eff9c0bc61979e491b32b557ff9b18778e0f33` |
| `crew/emre/type-1.png` | typing, frame 2 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type` | `17451` | 2026-08-17 | generated for this repo | `b6e2eeb5eccf1c12c7827a93f29fa1445b4b9e1bc1d0b1380ca690b808c4debc` |
| `crew/emre/type-2.png` | typing, frame 3 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type` | `17451` | 2026-08-17 | generated for this repo | `9b90c7d10671a59c16e257c67911277da313ff0b94bc69f06fb51e19d5ee7583` |
| `crew/emre/type-3.png` | typing, frame 4 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type` | `17451` | 2026-08-17 | generated for this repo | `25389c25a55dcd017741093a90fe63821d12c353b1977509321bdaba854ada66` |
| `crew/emre/wait-1.png` | waiting, hands off the keys - what a blocked run looks like | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait` | `17452` | 2026-08-17 | generated for this repo | `836661fa370a73d510c21ac516e84913f6ab7b91e66d5f04e06b522a4ea01bc4` |
| `crew/emre/wait-2.png` | waiting, second frame | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait` | `17452` | 2026-08-17 | generated for this repo | `b1c8db403812f23bd058541fff514d6c94de7c0e398ef488e649dd220f73834c` |
| `crew/emre/type8-0.png` | typing, pose 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `8c666c7506cb2a1761994cfe7266d92f0e6e09dd2ddbdfa66edbe51357011833` |
| `crew/emre/type8-1.png` | typing, pose 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `80cf844a9de5653e5963a489c170039a49fc06697237bd1fec8badab7a2e7497` |
| `crew/emre/type8-2.png` | typing, pose 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `1d2d319d47108066f906385b2a09162916766a0096bd9dfbb110a8c4b536ca56` |
| `crew/emre/type8-3.png` | typing, pose 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `255be499a8dc8c402a6c6d359ea230e143f757a2da66d4420c81645300836a54` |
| `crew/emre/type8-4.png` | typing, pose 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `248b11883909936e51712d8a033e013dc3ee92688d8688b1b25a9d8ec58c2dec` |
| `crew/emre/type8-5.png` | typing, pose 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `91260ebad456ccbd0ae317e30c729563816ac7c509a3452c313b3d7693ff7fbb` |
| `crew/emre/type8-6.png` | typing, pose 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `645d7f0757e04e4f501345f666cd8335ed333035d675c7d355ef0992c8c5010d` |
| `crew/emre/type8-7.png` | typing, pose 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-type8` | `17951` | 2026-08-17 | generated for this repo | `d1404fb1175a3c03494a2387a2340eef5702c88498f17762261e2dc0e4704e9e` |
| `crew/emre/wait8-0.png` | waiting, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `111faa35d6c765ec594c5ae80cd2afbcdaabedfaa3558bb8356b6635f902af15` |
| `crew/emre/wait8-1.png` | waiting, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `80faf2c64e7e2848c3393f053f83d6dd8f8fb988999b12c8c3dfdba2cafd3324` |
| `crew/emre/wait8-2.png` | waiting, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `d3f887bd699f4729075dfa155f7848e484ef93ca3c9c899a14ef18e16ef0377f` |
| `crew/emre/wait8-3.png` | waiting, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `2ed11e9f338ce5ca758ca5339364230965112d0571c3d70133f0fb28fffbae5d` |
| `crew/emre/wait8-4.png` | waiting, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `cda2934cd003816492de8e741242d0428b71902bcad53d305b6121c749b49286` |
| `crew/emre/wait8-5.png` | waiting, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `f8d8b029402d851d177ab4ffddfdd53b873f6e3f69c3840a55e3e0d110bb2041` |
| `crew/emre/wait8-6.png` | waiting, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `a0e39e3199a713427833391c0a333cf5bc442f9711e0e65a1c07d91adf8bc375` |
| `crew/emre/wait8-7.png` | waiting, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-wait8` | `17982` | 2026-08-17 | generated for this repo | `cab0db9c23452b7924322213975bcaf448098ef29361a252826c31b717c033cc` |
| `crew/ran/base.png` | the still every other frame of this set came from - the pose lock | pixellab.image | `/create-image-pixflux` | `crew-ran` | `17495` | 2026-08-17 | generated for this repo | `b4c5702155c70b2f9b626121b4160ca400768835c1db82b666305cb3bb804448` |
| `crew/ran/type-0.png` | typing, frame 1 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type` | `17461` | 2026-08-17 | generated for this repo | `41319b70c4382d513a7e30a6a48b1201c8a8dde3d005c7ef3ef38f1ede77a2f8` |
| `crew/ran/type-1.png` | typing, frame 2 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type` | `17461` | 2026-08-17 | generated for this repo | `adeef1641ba2e2965525cdf299ca28dc6c61c8be135b0be47af14a50568b85b5` |
| `crew/ran/type-2.png` | typing, frame 3 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type` | `17461` | 2026-08-17 | generated for this repo | `24f288c194049074e2e345d256621b041af544f71684ca64c3bf5d50caf91a50` |
| `crew/ran/type-3.png` | typing, frame 4 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type` | `17461` | 2026-08-17 | generated for this repo | `15f7b83aa1e85449b49af34174db31171d841a2ff6c72874b834f465740b9ee4` |
| `crew/ran/wait-1.png` | waiting, hands off the keys - what a blocked run looks like | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait` | `17462` | 2026-08-17 | generated for this repo | `cc0c9399aa58576b416c3d395cff57b2ff64b9ce9a90f89692c1094c40339695` |
| `crew/ran/wait-2.png` | waiting, second frame | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait` | `17462` | 2026-08-17 | generated for this repo | `957f6e22663985599342c2abefaec38616ce3b50bc11827a6fb5b24efab0a988` |
| `crew/ran/type8-0.png` | typing, pose 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `8bf36b173db6979d8de9ef0eaeda6240492f2b18f3f56323a6614485d6c1e3cd` |
| `crew/ran/type8-1.png` | typing, pose 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `4a39834b886b9b07337229ac4e166314218f039be738bfa3a6c099ca87291bdb` |
| `crew/ran/type8-2.png` | typing, pose 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `c642b29b93cd8c8dc0d433fe7e5dfb3b8f4128895c7c7921fdde1f0d38862e3d` |
| `crew/ran/type8-3.png` | typing, pose 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `bc6d97c91103a6351370df53550cad450aada93fb0f566706ad0baabf0a794d5` |
| `crew/ran/type8-4.png` | typing, pose 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `b7c964f26c50f6045f066b13b0f2bb17511942ca597fbdcb0c4ba7db699af1e7` |
| `crew/ran/type8-5.png` | typing, pose 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `f743b6311323bc3a29f8bd9b8fb79634f5ee4682884775ca50936a466a982ec4` |
| `crew/ran/type8-6.png` | typing, pose 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `b6ec69e06ee17a839c9b424f836a899b188440d744ab160d073779c79a5caf48` |
| `crew/ran/type8-7.png` | typing, pose 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-type8` | `17961` | 2026-08-17 | generated for this repo | `a1c4352ab2b9de57602b2411f6597cbf84fd01b08f77aa0d6060e8510e9952a6` |
| `crew/ran/wait8-0.png` | waiting, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `5a9f32a4a81ac5c1b4612d98a56f63923abf02072d86d404d993ef6e2b02225b` |
| `crew/ran/wait8-1.png` | waiting, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `4852be0a9e4b7c5dbcfcf96ad65ffb07cd0ea02c9345cf445c3cdc498b53d3c8` |
| `crew/ran/wait8-2.png` | waiting, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `f99e05ae500a93e68c711627be2098e590e50f0118d22706bc4e0b6813f6cbff` |
| `crew/ran/wait8-3.png` | waiting, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `7c061e1d8d86e3287be2305763fc0bd4ff0905c787a0e7fecd7dac36a69bf3cc` |
| `crew/ran/wait8-4.png` | waiting, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `0a4167f82e57078e741d02f42c8431541596ff08d559394d6b3ea41943fdce65` |
| `crew/ran/wait8-5.png` | waiting, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `4a0f536db53afc09a94c658df01f81acdc09df0817e8750aff5881ceef51ff69` |
| `crew/ran/wait8-6.png` | waiting, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `fd0845dd465fad4f133e0265e32284db7d8c5ee6ffff6a3e85ddfa888ffe8a33` |
| `crew/ran/wait8-7.png` | waiting, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-wait8` | `17902` | 2026-08-17 | generated for this repo | `768d4f96a058b5db0fb6926fd3905f65f21402bc0f8c1a1e701b8a638e0e85dd` |

## A pose per stage

The room had one person doing one of two things: typing, or — in an alarm —
breathing with their hands off the keys. Every other stage of the pipeline was
drawn as typing. The test gate was running and nobody was typing anything; the
reviewer was reading a diff and the hands were hammering the keys; the PR was out
and the hands were still on the keyboard. The plate said GATE, REVIEW, PUSH and the
body said IMPLEMENT.

So each of the four sets gained **three holds and three moves**, and
`wall/room.js` gained the table that picks them:

| pose | stage | what the body says |
|---|---|---|
| `watch8` | GATE | sat back, arms folded across the chest, hands off the keys |
| `read8` | REVIEW | one hand off the keys and resting on the mouse |
| `done8` | DEMO, PUSH, a shipped run | a mug up and out to the side |

and a MOVE for each — `lean`, `reach`, `toast` — eight frames that carry the person
from the base into the pose. The room plays a move forward once when a run enters a
pose and reversed when it leaves, so gate → review uncrosses the arms all the way
back to the base and then reaches for the mouse: 1.92 s, sixteen frames, and not one
cut. `type8` and `wait8` need no move, because both are AT the keyboard, which is
where the base is — a change between those two gets one held beat of the base
instead.

### Where they came from

Every one of the 192 frames is `pixellab.animate` at `frame_count: 8`,
`no_background`, then the harness's own `postpass.py` against
`.creative/palette.png`, and every one traces back to a committed base.

Two production paths, and the rows say which per file:

- **The one-off MCP `animate_image` path**, for 190 of the 192. What the endpoint was
  handed as `first_frame` is the committed base's own bytes, and what it returned as
  its frame 0 came back **pixel-identical to the file in this repo** — verified for
  all four sets, 0 of 4096 pixels differing, before any of the twelve moves was
  generated. Every hold then took the verified frame-0 URL of its own move. The `job`
  column carries the PixelLab job id, so the chain from any frame back to a committed
  base is checkable.
- **`factory.py`**, for `crew/emre`'s `reach` and `read8`, which round 2 regenerated.
  Its body-hash cache was primed with `crew/emre/base.png` exactly as PR #47 did, so
  the base entry is a cache HIT whose stored image is the committed PNG and the
  animate call is handed those bytes at no vendor cost. Both were re-verified the same
  way: the returned frame 0 differs from `crew/emre/base.png` by 0 pixels.

A move was animated from its set's committed base; a hold from its own move's last
frame, so `watch8` starts one animation step past `lean-7`, `read8` past `reach-7`,
`done8` past `toast-7`. That is the whole reason the moves exist: the frame that ends
a strip is the frame its hold was drawn from, so the join between them is a step of
the animation rather than a change of picture.

**The four `toast` strips pin their ending.** Asked to lift a mug, the animator brings
it up to the mouth: three rolls of the room's own worker, each capping the height in
words, put the mug beside the face at rows 8-22 — above any cut that keeps the head,
and a mug cut off at the collar is a pale slab growing out of a shoulder. So each
`toast` interpolates between the committed base and a frame of that set's own
open-ended toast where the mug is still at chest height. Both ends are generator
output from the same base; nothing was drawn by hand. `.creative/assets.json` records
the pinned frame per set, and notes that the factory does not yet drive `last_frame`
— a harness follow-up rather than something this repo carries.

Balance: **39 generations** across both rounds (225 used before, 264 after). 24 are
what shipped from round 1, two more are Emre's regenerated pair, and the other
thirteen are rolls that did not ship — four wordings of the reach, four heights of
the toast, and re-rolls of Angel's and Emre's reach.

### The rows they are cut at

The pin from PR #47 is still the mechanism — every drawn worker is the base above a
split row and the cycle's own frame below it — but the split is now per
**(set, cycle)**:

| set | `type8`/`wait8` | `watch8`/`lean` | `read8`/`reach` | `done8`/`toast` | chin ends |
|---|---|---|---|---|---|
| `room` | 41 | 32 | 32 | 30 | 23 |
| `crew/angel` | 41 | 31 | 31 | 31 | 22 |
| `crew/emre` | 43 | 31 | 31 | 28 | 20 |
| `crew/ran` | 40 | 34 | 34 | 34 | 29 |

`type8` and `wait8` keep their hands on the keyboard, so a row at the bottom of the
ribcage leaves everything that moves below the cut: those four numbers are PR #47's
and none of them changed. The three new poses put the ARMS somewhere else in the
chair, and their moving rows start at the collar — so their cut is at the collar too,
and never above the row where that set's own chin ends. Ran's bob reaches row 29, so
nothing of hers may be cut above 30; Emre's mug rides a row higher than everybody
else's, so his `done8` takes the lowest cut in the table at 28, still eight rows clear
of his chin. The chin column is measured by the suite from each base's own silhouette
rather than written down.

A MOVE is cut where the HOLD it leads into is cut, always: the frame that ends `lean`
is the frame `watch8` was animated from, and a split that moved between the two would
step in the middle of the move.

### And what the measurements say

`tests/wall.test.sh` re-measures all of it from these PNGs, over all 256 frames of
all four sets, **measured against the brief's round-2 LOCK** — fixed ceilings, set by
the brief and not by these assets. Everything is measured on what is DRAWN (the base's
rows above the split plus the frame's rows at and below it) and never on raw generator
output, because the animator grows the head upward systematically and the room throws
those rows away. Worst against ceiling:

| claim | worst | ceiling |
|---|---|---|
| (a) the outline never pinches at the seam | 2 px | 2 |
| (a) nor flares past what a mug in a hand takes | 11 px | 12 |
| (b) a held pose breathes rather than shifting | 1 px | 3 |
| (b) a move joins the base and its hold without a step | 1 px | 3 |
| (b) a move's largest single frame | 10 px | 10 |
| (b) and none past 60 % of that strip's own travel (floor 4 px), excess | 0 px | 0 |
| (c) every drawn figure sits in its base's chair | 3 px | 3 (1 for type8/wait8) |
| (c) none of them is wider than the base | 4 px | 6 |
| (c) a hold keeps one width across its eight frames | 2 px | 3 |
| (c) and a move starts at the base's own width | 1 px | 3 |

Between consecutive drawn frames of a hold, 0-641 band pixels change. Nothing here
was retouched by hand. Forty-eight pixels across twenty frames came out of the
post-pass on a colour that is a WORD in this palette — 45 klaxon `#ff2f45` (mostly the
highlight on Angel's ember mug) and 3 shipped `#3fd984` — and each was moved to the
nearest lock colour that means nothing (`#ff9a5e`, `#79907e`), then the set was
RE-POST-PASSED so what is committed is still `postpass.py` output. That is the same
call `room/plant.png`, `room/lamp.png`, `room/prop-books.png` and the city set got: a
recolour for meaning, never for value, and never a change of shape.

The typing and waiting frames and the four bases are **not** regenerated and not
rewritten: their rows below are byte for byte what PR #49 committed, and the rows they
are cut at are pinned by the suite as well.

### The frames

#### `room`

| path | what | tool | endpoint | prompt | seed | job | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|---|
| `room/worker-done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `2d5236f521e7fa53e01f7b9473c025f580ea6b936745561789361d8f3fcd6c6f` |
| `room/worker-done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `00e08afbcff2a6a5ed40e7f9006f0e8bdd8f9cb03396db1b3c3d36e6c0b9a919` |
| `room/worker-done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `d7caf94ad2ee2d3e4292c1392302880d1ce36dd144fedcb672a604b26b07b030` |
| `room/worker-done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `58b35513b0b065bb186a4e2a5777bed0a342ba11d78121ded31a41b01a0c12ca` |
| `room/worker-done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `8483d3531c458e674611121c7731b5252f9b59e8a0e6414f978f21ca25c860ad` |
| `room/worker-done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `79458a846ec9f222fe5b69a76b2e7ad9f26356a0c6227871daa105cdd71a8592` |
| `room/worker-done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `0e6d2d22b1effcbdcb0a52e1b283b74909381c8b9866dd81b4ebbfecc7f0482e` |
| `room/worker-done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | `1058fe42-4d6a-439c-9b91-c0bb03406228` | 2026-08-18 | generated for this repo | `9f009aec38c560a28ee2214f15d859e64f7bea8627aff3345ebdded6e812bc68` |
| `room/worker-lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `b5a088650faf70a89035d276e626e810368d1642f6c8d22d1cda5924f7a0e800` |
| `room/worker-lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `3e575b889f27416957b2742313ae9764a4a12f709e36ca0f244a512abbc358b4` |
| `room/worker-lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `21cab17a9bce388eb8447c6c90cc2146af278cd01b06b21e778302ac5472862f` |
| `room/worker-lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `afa01073a5b32208e8f25b3a22355eed0bcf797668459c2b273c2daeff48e948` |
| `room/worker-lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `2bf5eb4dc10984b46fb9ba079ea94cf65c99f22bb36a5989efab88792f282554` |
| `room/worker-lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `0bc48d79cba397fe491114ff1842df7e02c5c18dafdac31397ab9fba820c371f` |
| `room/worker-lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `38e82114335fa0de280db8f9f227cb52d298153b58ae9994fa1648cfae38946f` |
| `room/worker-lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | `d4400cdb-1e48-4e46-83a0-594894fda55d` | 2026-08-18 | generated for this repo | `78101937199b26e97bc4aeae267e08157ac6e0e8a055c4a26bc9e49ebd454b74` |
| `room/worker-reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `db7f0cd7275a37477514ccbca67f60cdfd4fc4eadce3a1b5e9f09f1f027a2476` |
| `room/worker-reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `636ab8275881fcaaf41876a30d72e9e43ba402935e59ba43ca3806b79b6ea177` |
| `room/worker-reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `11179490a1555ce84bb8dedb5b8b5dd956364782c139407e3b35113cbb0e4eb4` |
| `room/worker-reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `c1a85670b3428f478b97cafeef8261f350f68cdec0a24aa17f14f7784eb9f32d` |
| `room/worker-reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `e7ea93bf208db2507e8662c53a1fce7f19fc47176334f86a9e0fcbd6ae90c268` |
| `room/worker-reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `a5fbcf8dfb86829c9b9cc19017d46ec86bf2f311cd6d45e654923edb9d5f02bd` |
| `room/worker-reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `421d51167277416c8d958b06a64ebe806cbc21277f8dbe0da11808f25d1404ec` |
| `room/worker-reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | `3b3c408c-25a4-450f-8af2-8da19670f488` | 2026-08-18 | generated for this repo | `314be2e498e6bbb680fce9c9dafaa79930b1f27d02db029efca4a3f86de69ee6` |
| `room/worker-read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `c4794e9155437efcc368fc5df9b49860b797c074e6dddd451ce7dd7e87aa0bfe` |
| `room/worker-read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `a222a957a23aa1fbf5ea2c8adf0ce8272a9e597b7a4eca059c4f39af248c9fb6` |
| `room/worker-read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `b78478dceabebee2f5293df4f4fbcdc8a592fe966b752aa2ef915c3421f31c53` |
| `room/worker-read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `b417d1de21a56bff7c04441298e8801d6dec248af0885d3f0356206372031b0b` |
| `room/worker-read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `4a2c4a98d76052819bf7e67f55c33fcc49b2cef171690b3200a26f27ea6f23cf` |
| `room/worker-read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `52119a3f1ea5ae4ef6c8ecff8f512c50f1325608efbef992ca2ecafa178cbf7a` |
| `room/worker-read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `4ca06f2357785af9a7af6eafcfbcbf611dd76689594fe47aeea9010546634ed3` |
| `room/worker-read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | `21a85b7a-7b8a-453c-9979-ed7c16c090d7` | 2026-08-18 | generated for this repo | `73db6b7b56a19ace9f321ede9139f1d6e64ec619dbcf49172a264aed8c0df555` |
| `room/worker-toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `533662d2aaf442470d43828f4b50b7c3f9937bcdb3723141a196127fc818c75e` |
| `room/worker-toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `66a6923922f32c5af90a2b2c262efc2760e964cd7d0bd68e741fded26bc4cee5` |
| `room/worker-toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `e861b65d0a36374c22c9af87a955a71cdc10317a20b6837ac88dfa72dbf0190b` |
| `room/worker-toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `330f28c94ec0211928ce1d81abe4c37280a5101fa4d72a6155c481b453f4f457` |
| `room/worker-toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `ee67af9ab814fee012d708d7662b880e92101c5f0c657ba612b732ca2cf83e8d` |
| `room/worker-toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `0793ce0c8f20b37b19eabd109ca96e2f09f7a39746d90015dce431318f140b13` |
| `room/worker-toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `9ea316e41a9bb94ec8e9849b17ecca4a20f282c2b3e8346291f4d0d539e75f9f` |
| `room/worker-toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `room-worker-toast` | `21155` | `a02f075c-a0a7-475c-8c2f-6a395b51889e` | 2026-08-18 | generated for this repo | `7e876f710b5d7a2e3e306f8029c7ed1673437a213807bca1bab78fce869867d1` |
| `room/worker-watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `744f06b493275d553aa494e2a4e269de2bfb8864f14894c12cde80e87fd79745` |
| `room/worker-watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `6b6056d1b6f9b3a9ec2c2410ee80cfa20e81f80a6cefd0aa337e670c4cb028e1` |
| `room/worker-watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `f7496faa466cb02fa93461507701d67e78adbb1a92177b433f1e97c0d5594124` |
| `room/worker-watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `aea0c24cdaf38a8f0d031499903db0a23605093ccd748bab799a56638cd45e8a` |
| `room/worker-watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `e5762ab615882b606f70f20a3a5f2ba4b5dddcf88f419cb8070e9c177902ae5c` |
| `room/worker-watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `c588d2dcc4219c765b499e9e759b6bf2c12ee1c8d8244783d077445e93aaa493` |
| `room/worker-watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `8dcc958da3b7853e656de5715a72648ba4fd64439d856cbc1fba1ccae744c5d8` |
| `room/worker-watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | `e4922269-d811-4104-87ab-738236f1c6f9` | 2026-08-18 | generated for this repo | `0ec3c93e53585867a12634f3dd641fc8a9c4b5deb6f7d01a1f892d177be1d4e1` |

#### `crew/angel`

| path | what | tool | endpoint | prompt | seed | job | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|---|
| `crew/angel/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `f6b2b46f841654a1384ed98261cc15782e22df36a3a59e3982987231784e1d2f` |
| `crew/angel/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `b5fb953f3ab9f624c89c406fbc81e6bbf26646390c0f4e616a6442b2bd462da7` |
| `crew/angel/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `43af733bd014ca9bc25553522c453d38d2993aa2cced99cbd9d00abb251af9c8` |
| `crew/angel/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `dceae0cd18732c6158a8a3a941183205d77df20526d092b2601b348eefbaf8fb` |
| `crew/angel/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `2cf9251db86b7dfa6536298cbf93a53086a977b5a45f60ff2f2bc7e1d52c4b40` |
| `crew/angel/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `eb8d42449225e3495f94198ec89153248897e20f277c370d15d4327480f06cc7` |
| `crew/angel/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `84c97989d64f11d0c1bab8f4114f84699a574e755b18f595b45c10f3df23f0c3` |
| `crew/angel/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | `f5fec3da-67d1-451b-b3b5-4d2175b4ab09` | 2026-08-18 | generated for this repo | `5a3b8c9b8ef1bc046ad280a135b9da7091a9c4ac870f017e2cba334837ebffcc` |
| `crew/angel/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `a130977a70ed71306ab1fabf79b8d405b413159552bc30208df8064181c8a7b8` |
| `crew/angel/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `fe865d30c11924d63739182e6d96b3de492044a08bb6cfed2a5c4cba4b0acdd9` |
| `crew/angel/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `6e3408160865e5acb4cde790dc72bb967a3880a869495d122ee88a7a01c0928f` |
| `crew/angel/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `a89f11120ba39e6a3b2b2bb743e34258af60cc38d63c32c664e54da72da03c7a` |
| `crew/angel/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `0b7e62095a3ba30f84ef61455f37e5d12e11402f2046e9bf6d9c9b0d480b2b20` |
| `crew/angel/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `ee6145b57831f3f974c3838e38c530ac0aa01667f21868b3ca432e235a0a4d75` |
| `crew/angel/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `14ca582c9f216e442f915723e3bceca5d62a713eea2dbcb06579b3578728ea49` |
| `crew/angel/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | `494f6c1f-a3de-431d-b4d2-423be5398e63` | 2026-08-18 | generated for this repo | `c9a81b2b73c2f68cc4a40482214dd1e8aa91765bb8789625dd84c9f42418c193` |
| `crew/angel/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `8ca98cd57e2cfc794a8bda2547e5db91ff79ca575b12d865859aad1a4d8581fd` |
| `crew/angel/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `257c6c9e9dcd80130b56d728a0514c7b75155379b7ed2c4d4328f901a62834be` |
| `crew/angel/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `2c2941493f5cfbefdf4c9d4d7391e144366061b05a5baec04335be7d5d26c2d9` |
| `crew/angel/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `80aa416db5241aa1e186ba6804ca67c4ae08f1c90768ee6b199772dbb22b7fda` |
| `crew/angel/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `56e89e31fc15c27e4b618f2665e8cd522ece52e8ddab95d427c1d53f640fddfd` |
| `crew/angel/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `416318ba794238637bd87c7b37a5caadbd90986186683cdbd637efc9fe2204ff` |
| `crew/angel/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `80b8e07ee14cca765d469e333400742da2d147b016da70e044b568c9198507ae` |
| `crew/angel/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | `d99bfcbe-e08e-4dac-b196-55e511a4d55f` | 2026-08-18 | generated for this repo | `25902a775c3d74ce14ae92b4ddf788c6f740d4f3544a5f9c1b3d22dc9ba2859f` |
| `crew/angel/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `0bfd61234811f7d555ae4fbccb6835d362d0f72046172264c82d86596284a716` |
| `crew/angel/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `595d4c5b77e2361ab44459c9295c56d0a19cf8495c90a51a95110d7864b7b850` |
| `crew/angel/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `df73c958e6ec4d3fb761212633715d1135b26e39835c0c581af5e9ca47b96892` |
| `crew/angel/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `5051d7e5873e6e629a978407994ff98fbdbbdce18cb81d804b0c97bf71f027f4` |
| `crew/angel/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `95391e04cf784976b061796084d0ff21fa7a3b574b21f1d31676cdb93c79b4eb` |
| `crew/angel/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `6c3bf87e435d0e51dc2d8b8b8701c3fbdf3129f03eb9989de2d233e9e8a82c66` |
| `crew/angel/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `b430fac3dd0566dd16844a800c57b6066174e6bdf1b49f4742493b403b02bc08` |
| `crew/angel/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | `1f9d8648-1013-4015-b972-348cbb76264d` | 2026-08-18 | generated for this repo | `49b8626ee4eca635a4ed7715a5fe4c1c0839fe5b0b058b01992ba2fb8f691d5f` |
| `crew/angel/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `92d6f5ffec44655c429dcb03e3dff92fc73d916d6e30eba737848af3004883d1` |
| `crew/angel/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `31b49a7b72ce769ce4fa11fe503c835ab89dafdff3076fdb63b086d718e1d3af` |
| `crew/angel/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `44fdcae923726952a22be8f242314f2e94ba8c7dbaf9cf919517e496815be8be` |
| `crew/angel/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `5dbb0189609fb0402e2300f208e7e7372521d37b6e3408b43ebed6570140922a` |
| `crew/angel/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `cd9e5c5daa1f071605f497a90a54a2126a60098af13c05f942d810e054a404ed` |
| `crew/angel/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `6d8f6c4dcd8343af66a7ef5c37d5ed2873a727f387a23aa66a111d17ae7cec34` |
| `crew/angel/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `7a337c95dc461dcaebce58366bd2bf42c08099682b482e4ad460109237b3ad62` |
| `crew/angel/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | `1552ad3e-ee79-4593-8406-81705670584f` | 2026-08-18 | generated for this repo | `c16101045f9ec5c98ec2d3c1fc2aabfb601ba7dcfdbe722b5a9bef043da173a1` |
| `crew/angel/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `2537e6f833250fa633e31977a23f099caeee7485be70d16db9574ea25826c451` |
| `crew/angel/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `d6ee64d5051c5ed63536a2a4001946ead7a24d9efd776e06fcc991d3297ab108` |
| `crew/angel/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `beebf2d1f8dac848441296dacc12f5904aea10e18396fc0ddb59173b49eb0717` |
| `crew/angel/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `2e6f67657167255b8c465acd6637b1c3f20e4d78c832e6166b7a92a3acce0bee` |
| `crew/angel/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `81ce2ac82cdd3d2cb3781e94ba8f1ab648351509d11d51d37717b135bc8b0676` |
| `crew/angel/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `7ae2740591f183af55a28fec91b9a0202adae082da495f55a0cb4cd6f22cd531` |
| `crew/angel/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `c891c229bfa4bd8f16da1dff39f34cbc92cef3d2162da725c58f5a6c6d4109b7` |
| `crew/angel/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | `ec459e35-b28b-458e-8a5d-78e2d513b4aa` | 2026-08-18 | generated for this repo | `6bd42ba1b9c0938de5452a84cbab36de3bd50315bc59b15f91960d304b29e3f6` |

#### `crew/emre`

| path | what | tool | endpoint | prompt | seed | job | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|---|
| `crew/emre/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `2dbfb106b79906c8dba4cd4634c16827b84168c2868f7599827c4333de9c5a02` |
| `crew/emre/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `596961cfff9c434968fc0c65648ac3bd593c81e9dc091da7618ac787abe0b7bb` |
| `crew/emre/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `1242de8915a0f5469d441f58a23677b4b1bcc5ef178bae392fbfae126ca94e21` |
| `crew/emre/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `ca05280e71959412ed07623496d2eedc9253f82751649192c4b01c8a4d55b3f3` |
| `crew/emre/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `126b72c19ad72156a3beffb263ddbdd193af18a915092d44f8c87a560b7b726b` |
| `crew/emre/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `de61efb3a97059885b352e2999665199b1553a23dfc6e13150383356ad91aa76` |
| `crew/emre/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `d46bdc9bddf7f8bee88e94fdb9a86abbd88539062ee4d71f9c409653e08a8c8a` |
| `crew/emre/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | `5831ff61-d851-4598-aded-59f5d43aa0ae` | 2026-08-18 | generated for this repo | `7e35c22159013f2fadd709769f7c50bc2c78e61a01a5574771ea5c909091c2df` |
| `crew/emre/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `7cd53ad4ce877658e196271a5f0487b0ef6291c12b5fb1661122c49c595a10aa` |
| `crew/emre/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `1af7a26ab9b963c72789c89f18ba598a0a21f4068026ad4261b9f209b8c377f6` |
| `crew/emre/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `79e4a65da3b14724de70d5d1a81be5087854bc613a6dca155b0c3d462319847b` |
| `crew/emre/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `2f76e890f28763ac2d2c9f37d1b2422180b483c21b62b91869c923ccc95df8d8` |
| `crew/emre/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `d6b696795713f935a9f8c1fc73faed25696fdc982552d0df863beaf4586dad13` |
| `crew/emre/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `2c77057e497796fc34c589a7f4d7be5ba6629bac747c4a8f061c6c49329d7b72` |
| `crew/emre/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `654a3a0096c76f5c08bf9191a10046b268a48ac98df0c2bdcd3abb5533189e03` |
| `crew/emre/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | `f5941bb7-4089-4180-92dc-0e63e6520eb2` | 2026-08-18 | generated for this repo | `33f1bf15dd37768186fe4e374efab3ea2c4a03acfb27b00bf59e98b5ec27d417` |
| `crew/emre/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `91de7d49918a91ec26ceae9788fec8333c3aed6d965065b04dac8c7aa59bb154` |
| `crew/emre/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `ea43bb299d5bd174c6e1700f7528551ac51259285af9b6a91ad288d7d695f94d` |
| `crew/emre/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `e06783cb45bf5d1b0f053147ab3f0dd34faaaa5c1039d70945eeb0be603c3a8b` |
| `crew/emre/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `1fef4f5a2adf8a8acb17b33b74fa6a46f467115a7977b95a6a3cd97165321804` |
| `crew/emre/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `aa4cbbfab91bd3db518d85ffc09903459aa50c5e579c8558006cefaf47eb7450` |
| `crew/emre/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `c37c0026f44539e4510f09b9064ef9541b416c867c20e48c657f18d6f2b39fad` |
| `crew/emre/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `c5be64495802b0914d39406c37bfc43010abe62454bc9c0cbfe1942fab87d5f9` |
| `crew/emre/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21353` | `factory:crew-emre-reach` | 2026-08-18 | generated for this repo | `be23ebbeacfffb5f3b173dbd9bb4246604caa57ce162fb98568c1ac9ddfd15f1` |
| `crew/emre/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `2617c518c5f60b13647a7358249900b131589496e5721ee0528258452ba8af30` |
| `crew/emre/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `e727955f94caa65283504c52030b59d361f779804a370a8bae322d1b47e11e8b` |
| `crew/emre/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `2717e12af5f332a95ab2f8c0c2e4eb9b0c01b30760498607713baff08d0e591d` |
| `crew/emre/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `e8034f366b782c557dc2c10f6fa291485713aca7cfe0e995991d040dc50953de` |
| `crew/emre/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `1a10c1ddc478f7ece71e3e86babfedbcbe0cfedc5639411f5439470489246131` |
| `crew/emre/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `614b8c813fdb58238fd2041746309d664f1e90fc10bfeb2e7843e99a1f82b084` |
| `crew/emre/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `ee7b06d3b078b8426ab123b8cec9035da2233f18a8183e3b0f021b9ebadcc252` |
| `crew/emre/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | factory.py pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21354` | `factory:crew-emre-read8` | 2026-08-18 | generated for this repo | `dfd839cc75eaa3c89fde4d268d3012722b63140d76068fc790b9878c44051d7b` |
| `crew/emre/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `3ee49b9000f6e34580caa00fe061ce4c504091ab79af042760ce2a6470142f5f` |
| `crew/emre/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `a2a974ccdecdb53a916cd011c95b0fa71cafcb94a9713f906eddc16c7a08f0a6` |
| `crew/emre/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `04ed4bf344cb9440643cbbc97f65d064c35e26e18f9ba88b6ad1f6650a052db5` |
| `crew/emre/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `e9abdf55466c7fa82a0fef034822a04ce9d174e4091666424c1903b9b73a4aff` |
| `crew/emre/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `9d99af666e1c13c40fc03728232d4d1b0b206482bea6f84cb848f73b457ede57` |
| `crew/emre/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `e88c0315473239ac41030717b1f45c8053bc8e024b3517af193fadbeb5c1405b` |
| `crew/emre/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `15f2e9fef99fb1b05594759f26e1424f58b7da3d264cdfda883db6be6233c55e` |
| `crew/emre/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | `31a9b2ca-339f-456b-b213-c99f2c19afd6` | 2026-08-18 | generated for this repo | `6f5786c17bf84af9d4db367c140df242542fde0855ed168c18a0a35733c9ed4a` |
| `crew/emre/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `3c2e528da2ecd2e87a1367019bc0c2f25f54838e54d0e33dcccbeb61c8bcafa9` |
| `crew/emre/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `2064cd2c028a69c24e32e36246de8edc798736bcbd339c61c500431ba0a793b0` |
| `crew/emre/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `b27b754200456bf0683920ac50d73c48b96af452da4de2424da41eae27bef224` |
| `crew/emre/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `dd0202fefc2db79a788d801f88cb4379509e057f63bd0f89dcd9b1a52e735c85` |
| `crew/emre/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `c656f3e25500612f867cf94c619e949cbf38c0da8c2bd2333e78da6f12a0f151` |
| `crew/emre/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `eb26ae2d25489b9b685f071fbeaca3ac7a26a9ca8921f4c1e5b9a7f4e4c59952` |
| `crew/emre/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `1d141c65896a1bb856fdd24949a0fdd3015e63e1d5e336a17cde17bc5e9be8fd` |
| `crew/emre/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | `3875191d-1711-40ec-adad-1b44f26cc288` | 2026-08-18 | generated for this repo | `24dbfe39b63b7d4d124f89e27b8893ec3e6d351f76e3135433a79ca16eb41cf7` |

#### `crew/ran`

| path | what | tool | endpoint | prompt | seed | job | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|---|
| `crew/ran/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `c1857c02e7de6ace78f3f31e2c6ef4667cedfc0221d6d2325438905cf84ab7bf` |
| `crew/ran/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `eebe941a0aac32750ad4632c111b08df0aff86aa2777b683d6c9513c1f440799` |
| `crew/ran/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `57d530d670605620165ed386a7c9f286287f5a5988728b3f4a0eeaad1347a71b` |
| `crew/ran/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `7033675a8e4605817c5922aa6a711632c07555d826429d45ba38f52078df4857` |
| `crew/ran/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `a8e038081593d3c88ea5c48580b4e7b91c3e4f557725da23c80fc266f2aec117` |
| `crew/ran/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `85eedf89f31f4e3f02b75a324aedee5508673e16753f844b8e9cb714a0d01cfe` |
| `crew/ran/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `c8ba33504a8632ba3276609defe350619c3aba232d6887b0a35b078dabb84bfc` |
| `crew/ran/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | `9932feb4-655b-4a57-beb8-0acf9f74649a` | 2026-08-18 | generated for this repo | `9e26b5fc583ba524f1e87b8793d8bd1d74794a82352fdab0f4dace0e3c58b5e6` |
| `crew/ran/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `0aefb6ae2d84d33cdcc01b092dc7eac1dd3174046ebebfb24a1fa76fb8201f52` |
| `crew/ran/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `f20bb1787d04451abb31a268271dfcf5796f168c51c1acc60c115497bbc77fce` |
| `crew/ran/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `1efefb8e55b2a15b5f869d0a4c025d36f9083ae78c127cffcdf01f00844546fd` |
| `crew/ran/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `dec6c85c31e26c429a952f3975767adc7aa3c0d9d0f29f221188f00ed3fd30c2` |
| `crew/ran/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `fc7b64278a3d7948f1511b1337b404f748f9733e61daa75ee40d1e9ec8fef55d` |
| `crew/ran/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `47820caffc54f8b15c37242cb99c397bc2256a1a33485fa6e288c599dfae6c9d` |
| `crew/ran/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `321e5b4fc77aff2b3f0c4f3c61d135336f39ce4857c1cfd559f7796dcbea38bf` |
| `crew/ran/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | `6b1c5d94-6305-4c4c-80da-c9a2e2c8bba9` | 2026-08-18 | generated for this repo | `4856027b93d0c14b3d6f87b9ff356b7c2644e5d4e45ddfd5bc602777caf2843f` |
| `crew/ran/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `02cd3c8f3ef3fbd3f3cfc74a38c4a584fcf1a9e8988b8403fa2aa92671bc5a95` |
| `crew/ran/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `77a0d015828941acd325391405fa376412f3ab86c8fff72e8472fcbfca3ba413` |
| `crew/ran/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `c2fb69360be4707db620e22a79bf20277248ff1fa4b5d7d67b274b1dae33edaa` |
| `crew/ran/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `321db59f9aa43ba4ff426002cc808eae6935cd02b12d25f5780d0b7131e68dd6` |
| `crew/ran/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `950fee3f150822c8a041b78f819f765363bb97daa308c60eca7f6381a24d7b22` |
| `crew/ran/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `00fc889a10a97b5f145af49c35c12c43bb4be4cd0a6219853500317677572318` |
| `crew/ran/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `e11220ad56ab2c8034b650f0720e6ff48886ba73d9a9c069aee93e3105a423f7` |
| `crew/ran/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | `f043c8c0-1457-44c8-9fb1-91ba2cd499e4` | 2026-08-18 | generated for this repo | `e89bfadcf8647230f880f1086d57235d05f2bb27f1176eaec9ab32cec01a1f0f` |
| `crew/ran/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `c1e925f21148641803b317a73d31a02e957d7dba7a4a3297284736746a35c41a` |
| `crew/ran/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `8606c58ae9e6c124e5f2b57c413afdd0220eb09fa361c6c3c5e2b0871e9c822f` |
| `crew/ran/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `310cb6af30905ef8b179f059d9fb37f8d1e264e749956dcfecf17e1d5eb1f0cd` |
| `crew/ran/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `ed59f81f2ebe78e9bd5fd531c32e5c45578ceb5a8721c411eb5f12a0d98bad68` |
| `crew/ran/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `62a88b12375870505d9516beefe6713b2e451c52703163d8ff2002d1dce8a6a3` |
| `crew/ran/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `9d5434e00ab49413f351fcdacdc5603ceaa2cd252f5afe0ddb4f310bf47f29a4` |
| `crew/ran/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `3d24ad75c63abb8d78847dcb1b3c2000f39e6f957fa86ab9c43d3a48370009d8` |
| `crew/ran/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | `b99eac1e-b23d-4120-ae25-535c4b27f7fd` | 2026-08-18 | generated for this repo | `c7d511b2bd8dbb6ea5e83f5b0cca3623b1ae2480de185088a57d94919bc35f46` |
| `crew/ran/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `6c2c278282fb53965bc6a8a3d593fcebfb1bb9c823631c309aa8cd08e8e16202` |
| `crew/ran/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `8fc095ac6f1d84e0008abff073bd20a7d43ac0065b88542aa9489203d1d33ffe` |
| `crew/ran/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `431e5df1a84b8bb1c5dae544c743cd68988adb4f84de0ba30cad964662da1759` |
| `crew/ran/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `1076934f6fb8cd7c350557b8a8a0ae2e8b56f007e82538ecddb202670bc07577` |
| `crew/ran/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `713025ed560e1458dbe0295cc686d08a0c872930bd02521c8843008dac077bab` |
| `crew/ran/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `130e965a7394347625c57fd1d2e213b8da3fd981dadd421e0841bcdca1b8eb9f` |
| `crew/ran/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `970a6c0740c99b8f618788d579aa1ac6420dab470e44aec5e19482f7af418e07` |
| `crew/ran/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate + pinned last frame | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | `085e1968-c9fd-4c46-9c41-d3b2492265bf` | 2026-08-18 | generated for this repo | `5f21c0da47ab32c855abaca74c34f8ba74944c18821c286620f823177c8fdf92` |
| `crew/ran/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `04e0c679e7232a575fe6b7d93784b57253eaa196ac5fc7e4ac7252d0e64d5b9f` |
| `crew/ran/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `6fe09dff36fec086a156d3ce47d120c3d13f6b499ab116e0a5a04d7425fa3216` |
| `crew/ran/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `fe91a51396517a674ea4803a796170fb07e9737d768cda0193fc53166786823f` |
| `crew/ran/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `365203e5eacbe9b2a639dab0556e916fcb51aa120e12d3e9b034bdba8f7d971e` |
| `crew/ran/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `2233efec8f7b890fe9426fe148b36cd7fbb4f5eba39ee49f7760fe4f3db494d4` |
| `crew/ran/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `415bdc0bdd3433b882ebb21a450156042f577e373e7198bbeab7bf2f696880f3` |
| `crew/ran/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `19e72294b7025b908ee8558697b9a4228a93da14f288eaff8d72a3373bd4aaea` |
| `crew/ran/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | `3178aa73-a33f-4d23-82b8-940d99eb16d1` | 2026-08-18 | generated for this repo | `8bcdb0be23a34342770da7322d02cdedffb8e03bbf949bf083e296f7bfab504b` |

## The city

`?world=canvas`, and the whole of what the Phaser world is built out of. Two
committed files and twenty-three frames inside them: the set is packed by
`postpass.py --atlas`, so what the wall fetches is one texture and one frame
table rather than twenty-three requests.

Three rules the prompts settled into, all of them learnt by generating and
looking rather than by reasoning:

- **A wall is a texture, never a building.** Every prompt that said "a building
  wall at night" came back as a whole shophouse with sky over it, a pavement
  under it and a neon sign with invented lettering on it. *"a seamless repeating
  texture tile of X … continues past every edge, no sky, no ground"* draws the
  wall and only the wall.
- **A prop is an item, never a scene.** "one street lamp" draws a street. "one
  lamp post object, item on a plain empty background" draws a lamp post.
- **Nothing is authored unlit.** There is no dark variant of any wall in here,
  because three rolls asking for "every window dark and empty" came back with
  the windows lit anyway — and because a sprite is authored once at full value
  (`.creative/bible.md`). An empty floor, a shut shop and a far-band building
  are the same sprite with a multiply tint, applied by the renderer.

Two whole assets were thrown away rather than retouched, for the reason the
room's first batch set: a lobby and a roller shutter that kept coming back with
lettering across the fascia, and a road tile that came back with a word painted
on the tarmac. The world draws the roadway as a value instead and uses one
ground floor for every building.

**Red and green are words in this palette**, and the quantiser does not know
that: a brick course that lands on the alarm's own `#ff2f45`, or a lamp that
lands on the shipped ramp, is the palette telling the room a lie. Every such
pixel was recoloured onto the nearest lock colour that means nothing —
`#ff2f45` → `#5e3437`, the shipped ramp → the cold stone ramp — exactly as
`room/plant.png` was, and the set was re-post-passed afterwards so the atlas is
packed from what is committed.

| frame | what | size | tool | prompt | seed | date | origin |
|---|---|---|---|---|---|---|---|
| `city-facade-concrete-lit` | tower wall: stained concrete, narrow windows | 32 x 32 | pixellab.image | `city-facade-concrete-lit` | `19101` | 2026-08-17 | generated for this repo |
| `city-facade-glass-lit` | tower wall: dark curtain wall, wide glazing | 32 x 32 | pixellab.image | `city-facade-glass-lit` | `19403` | 2026-08-17 | generated for this repo |
| `city-facade-brick-lit` | tower wall: weathered brick, square windows and ledges | 32 x 32 | pixellab.image | `city-facade-brick-lit` | `19105` | 2026-08-17 | generated for this repo |
| `city-block-shophouse` | district wall: shophouse, louvered shutters and ledges | 32 x 32 | pixellab.image | `city-block-shophouse` | `19311` | 2026-08-17 | generated for this repo |
| `city-block-warehouse` | district wall: brick warehouse, tall arched glazing | 32 x 32 | pixellab.image | `city-block-warehouse` | `19112` | 2026-08-17 | generated for this repo |
| `city-block-setback` | district wall: concrete, recessed balconies | 32 x 32 | pixellab.image | `city-block-setback` | `19113` | 2026-08-17 | generated for this repo |
| `city-block-slab` | district wall: post-war slab, small square windows | 32 x 32 | pixellab.image | `city-block-slab` | `19314` | 2026-08-17 | generated for this repo |
| `city-block-tenement` | district wall: tenement with an iron fire escape | 32 x 32 | pixellab.image | `city-block-tenement` | `19115` | 2026-08-17 | generated for this repo |
| `city-ground-shop` | the one ground floor: a shop that is open | 64 x 32 | pixellab.image | `city-ground-shop` | `19121` | 2026-08-17 | generated for this repo |
| `city-tile-kerb` | the pavement, with its kerb along the bottom edge | 64 x 32 | pixellab.image | `city-tile-kerb` | `19331` | 2026-08-17 | generated for this repo |
| `city-crown-mast` | roof: a lattice mast | 32 x 32 | pixellab.image | `city-crown-mast` | `19441` | 2026-08-17 | generated for this repo |
| `city-crown-rig` | roof: a slatted plant box with a fan cowl | 32 x 32 | pixellab.image | `city-crown-rig` | `19342` | 2026-08-17 | generated for this repo |
| `city-crown-tank` | roof: a water tank on legs | 32 x 32 | pixellab.image | `city-crown-tank` | `19143` | 2026-08-17 | generated for this repo |
| `city-crown-deck` | roof: a stair head hut | 32 x 32 | pixellab.image | `city-crown-deck` | `19444` | 2026-08-17 | generated for this repo |
| `city-prop-ac` | roof: an air handling box, reduced 2:1 | 16 x 16 | pixellab.image | `city-prop-ac` | `19345` | 2026-08-17 | generated for this repo |
| `city-prop-antenna` | roof: an aerial | 32 x 32 | pixellab.image | `city-prop-antenna` | `19146` | 2026-08-17 | generated for this repo |
| `city-prop-lamp` | street: the lamp every pool on the pavement comes out of | 32 x 32 | pixellab.image | `city-prop-lamp` | `19151` | 2026-08-17 | generated for this repo |
| `city-prop-awning` | street: the awning that catches a shop's light | 32 x 32 | pixellab.image | `city-prop-awning` | `19352` | 2026-08-17 | generated for this repo |
| `city-prop-signtall` | the landmark's blank sign box; the page draws 冉 into it | 32 x 48 | pixellab.image | `city-prop-signtall` | `19156` | 2026-08-17 | generated for this repo |
| `city-car` | the street car, ~44 px long | 48 x 24 | pixellab.image | `city-car` | `19161` | 2026-08-17 | generated for this repo |
| `city-tram` | the tram a week that has shipped twenty puts on | 72 x 24 | pixellab.image | `city-tram` | `19162` | 2026-08-17 | generated for this repo |
| `city-walker` | a walker, mid stride, reduced 2:1 | 16 x 16 | pixellab.image | `city-walker` | `19371` | 2026-08-17 | generated for this repo |
| `city-walker-b` | a walker, feet together — the second pose, and the still one, reduced 2:1 | 16 x 16 | pixellab.image | `city-walker-b` | `19472` | 2026-08-17 | generated for this repo |

The three sprites marked *reduced 2:1* were generated at 32 px, which is the
generator's floor, and halved before the post-pass:
`.creative/proportions.md` puts a person at ~10 px and a district storey at
~14, so a 32 px figure is a landmark rather than a pedestrian.

| path | what | tool | prompt | date | origin | sha256 |
|---|---|---|---|---|---|---|
| `city/atlas.png` | the packed set — every frame above, one texture | postpass.py --atlas | `city` | 2026-08-17 | generated for this repo | `d67a40bb60bb6eeb03aef99efa3e13baeac67508c92f78a170049ac8b27abce3` |
| `city/atlas.json` | the frame table Phaser loads it with | postpass.py --atlas | `city` | 2026-08-17 | generated for this repo | `eadd42ad0b052eaab706cd1c9e1c4c96ffa1227057a7a763c531e3d8c2032752` |

## How they are served

`wall/crew.json` has its own route in `wall/server.js`. It is a fact about this
checkout rather than a sprite, so it does not come down the asset route — and it
is computed rather than read, because the roster the room is handed is the
authored file filtered by what is on the disk: every frame of every set it names
goes through the asset guard first, and an entry that does not survive is served
as `room`. A typo like `crew/angl` passes any syntax check `crew/angel` passes,
so a room that took the file at its word would ask for six sprites that are not
there and hold an empty chair. Everything below this line comes down the asset
route.

`wall/server.js` has one route for this directory, and it is fenced on all four
sides: the path must decode cleanly, every segment must be an ordinary name (no
dots, no separators, no encoded ones), the extension must be `.png` or `.json`,
and the resolved file must still be inside `wall/assets` after `path.resolve()`
has had its say. Anything else is a 404 and never a read. `tests/wall.test.sh`
runs the guard over the paths an attacker would try and the running server over
the ones a browser would send.

## Adding one

1. Put its entry in `.creative/assets.json` — id, tool, size, prompt.
2. Generate it, then run it through `postpass.py --palette .creative/palette.png`.
3. Drop the PNG under `wall/assets/<set>/` and add a row above with
   `shasum -a 256` of the committed file.
4. `bash gate.sh`.
