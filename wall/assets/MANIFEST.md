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
holds the closed pool a line may pick from, and there are three places to put
them — beside the lamp, beside the monitor, and on the wall over the desk.

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
- **One recolour, for meaning and never for value.** `prop-books` came back with
  a bright `#ff2f45` cover, and in this palette that red is an alarm; it is on
  `#531820` now, pixel for pixel, the same call `room/plant.png` got when it came
  back in emerald. Nothing was recoloured for being too bright — an asset is
  authored at full value and the renderer is what veils it, which is why the
  football keeps its white and the room sinks it instead.

Nine props were generated and eight are here. `room-prop-headphones` was rolled
twice, at `18514` and `18524`, and came back both times as a spindle nobody would
read as headphones at 4x; it was thrown away rather than retouched, and the pool
is eight.

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
| `read8` | REVIEW | one hand off the keys and out on the mouse, the other still typing-side |
| `done8` | DEMO, PUSH, a shipped run | a mug up and out to the side |

and a MOVE for each — `lean`, `reach`, `toast` — eight frames that carry the person
from the base into the pose. The room plays a move forward once when a run enters a
pose and reversed when it leaves, so gate → review uncrosses the arms all the way
back to the base and then reaches for the mouse: 1.92 s, sixteen frames, and not one
cut. `type8` and `wait8` need no move, because both are AT the keyboard, which is
where the base is.

### Where they came from

Every one of the 192 frames is `pixellab.animate` at `frame_count: 8`,
`no_background`, then the palette lock, and every one traces back to a committed
base:

- **A move was animated from the set's own committed base**, handed over as the
  `first_frame` — the actual bytes, not a regenerated stand-in. What the endpoint
  returns as its frame 0 is the frame it was handed, unchanged: that was verified
  byte for byte against the file in this repo before any of the twelve moves was
  generated, and frame 0 is not committed for any of them.
- **A hold was animated from its own move's last frame**, so `watch8` starts one
  animation step past `lean-7`, `read8` past `reach-7`, `done8` past `toast-7`. That
  is the whole reason the moves exist: the frame that ends a strip is the frame its
  hold was drawn from, so the join between them is a step of the animation rather
  than a change of picture.
- **The four `toast` strips pin their ending.** Asked to lift a mug, the animator
  brings it up to the mouth: three rolls of the room's own worker put the mug beside
  the face at rows 8-22, which is above any cut that keeps the head — a mug cut off
  at the collar is a pale slab growing out of a shoulder. So each `toast` is an
  INTERPOLATION between the committed base and a frame of that set's own open-ended
  toast where the mug is still at chest height. Both ends are generator output from
  the same base; nothing was drawn by hand.

Balance: **37 generations** for the run (a cap of 40), 225 used before and 262
after. Twenty-four of them are what shipped; the other thirteen are the rolls the
notes list — four wordings of the reach, four heights of the toast, and re-rolls of
Angel's and Emre's reach.

### The rows they are cut at

The pin from PR #47 is still the mechanism — every drawn worker is the base above a
split row and the cycle's own frame below it — but the split is now per
**(set, cycle)**:

| set | `type8`/`wait8` | `watch8`/`lean` | `read8`/`reach` | `done8`/`toast` |
|---|---|---|---|---|
| `room` | 41 | 32 | 32 | 30 |
| `crew/angel` | 41 | 31 | 31 | 31 |
| `crew/emre` | 43 | 31 | 31 | 28 |
| `crew/ran` | 40 | 34 | 34 | 34 |

`type8` and `wait8` keep their hands on the keyboard, so a row at the bottom of the
ribcage leaves everything that moves below the cut: those four numbers are PR #47's
and none of them changed. The three new poses put the ARMS somewhere else in the
chair, and their moving rows start at the collar — so their cut is at the collar
too. A move is always cut where its own hold is cut, because the frame that ends one
is the frame the other was animated from.

No two columns are the same, and the reason is anatomy: Ran's bob reaches row 29, so
nothing of hers may be cut above 30; Emre's mug rides a row higher than everybody
else's, so his `done8` takes the lowest cut in the table at 28, still four rows clear
of his hair.

### And what the measurements say

`tests/wall.test.sh` re-measures all of it from these PNGs, over all 256 frames of
all four sets, on **what is DRAWN** — the base's rows above the split plus the
frame's rows at and below it — and never on raw generator output, because the
animator grows the head upward systematically and the room throws those rows away.
Four claims, and the worst number each of them measured:

- **The outline never pinches at the seam: 2 px, ceiling 2.** The frame's row at the
  cut being NARROWER than the base's row above it is the defect — the base's
  shoulder overhanging nothing. The frame's row being WIDER is a mug, or a hand past
  the end of the keyboard, whose top edge is below the cut: the pose rather than a
  step. That FLARE reaches 11 px and is reported rather than bounded. Cutting
  `done8` at the row that would make both directions small means cutting below the
  raised hand, which is a 13 px pinch and is what the probe refuses.
- **A held pose breathes rather than shifting: 1 px, ceiling 3**, on the animated
  band's x, width and bottom between neighbouring frames — and **1 px, ceiling 3**
  where a move meets the base and where it meets its hold.
- **A move travels: its largest single frame carries 10 px.** Bounded against that
  move's own travel (60 %, floor 4) rather than against a flat number, because a
  strip that spent its whole journey in one frame and eight standing still is the
  defect, not a strip that moves.
- **Same person, same chair: bottom edge 3 px, width 4 px wider than the base at
  worst.** A composite may be NARROWER — folding two arms across a chest takes 10 px
  off Angel's silhouette and 19 off Ran's, whose own forearms are the widest thing in
  her base — and that is the pose. A rescaled person is caught from the other side:
  the eight frames of a hold agree on their own width to 3 px and a move starts at
  the base's width. The bottom edge is pinned to 1 px for the two cycles that keep
  their hands on the keyboard and to 3 for the three that take a hand off it, because
  the room seats this sprite so its last row lands on the desk: a hand that leaves
  the keys and rests lower is a hand ON the desk.

Between consecutive drawn frames of a hold, 2-286 band pixels change. Nothing here
was retouched by hand. Two pixels in two frames landed on colours that are WORDS in
this palette — one klaxon `#ff2f45` in `crew/ran/lean-2`, one shipped `#4ff08f` in a
roll that was not kept — and the post-pass moves such a pixel to the nearest lock
colour that means nothing, which is the same call `room/plant.png` and
`room/prop-books.png` got. It is a recolour for meaning, never for value, and never a
change of shape.

The typing and waiting frames and the four bases are **not** regenerated and not
rewritten: their rows below are byte for byte what PR #49 committed, and the rows
they are cut at are pinned by the suite as well.

### The frames

#### `room`

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `room/worker-done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `14d45f3f40dd4d5c9c0011e738dc963c6f7834ae8b58d6557e315bfbf64f5eb9` |
| `room/worker-done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `4447f36eb75afee7f9c57491711d44e96ca10d4104daed762865eebfff5c9c28` |
| `room/worker-done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `69d32161ffb0ce4be342e6df0226006b2828401b6e42416bbe271e3ec9f380de` |
| `room/worker-done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `65a8c680eddd414592419595c508dfa583cf63af0fe1cd77b26595cbdd2ec164` |
| `room/worker-done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `db2cd263b299fa7475fca970395a1b407e88ed14dedb1bf43dd5c348c783790e` |
| `room/worker-done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `81de16565c5e6c4feba1af0a77d10683503bf86f031557f096fccbaf36d5ea6c` |
| `room/worker-done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `390d618f5b36f8fd5fb4b1645ca03d8aad474d660c55e9eb44e014cd753caf99` |
| `room/worker-done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-done8` | `21106` | 2026-08-18 | generated for this repo | `317d4411373c47fe99965cb3abd59e2619abd305beedb9cb5e8982032a6ae43b` |
| `room/worker-lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `ce8f15efd0017acab395d0fe426c909cc71e8ef3c1e79c8b5d358bd41c16e590` |
| `room/worker-lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `b8f9b9e59c264145142cccd67bc1cedc490deab4fb8a85e8ae6b896282eec607` |
| `room/worker-lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `f35d52302215c381f333115f287e9515c0dccb79ca42c793e187c67c7559a48b` |
| `room/worker-lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `1f656d45819254c3f92ca59f84dfda947b03f1c766da9f0d80055f60713c3a4e` |
| `room/worker-lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `de73fd4a48ee0cd609fa05d5d51b8e82fbcbe05d11819d24e229209c74cdcb2c` |
| `room/worker-lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `39f0377e10e2f642c6a16b43b46ef9ea8052155b167761793f5617c0976765bd` |
| `room/worker-lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `46578380dd9365655ff14d3aaf8f3e9305c542d1f3ad4cc35abf28762d93876c` |
| `room/worker-lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-lean` | `21101` | 2026-08-18 | generated for this repo | `28c2d1ebf15e6ebe593bf8527cefe88b36af19015ebaedb5e1367971793dc61a` |
| `room/worker-reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `f60796f8f8c796430495fa75f140978ea27e58cf171c3f5542ac5b8068a4edb6` |
| `room/worker-reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `31a672ee9049e2772fd9d98daa85bea3463ca1d14d1fd9bd97543623a7609e8a` |
| `room/worker-reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `3495c638fd991242f7cd3360e96f01eccde562d9d95782874ed7ff440b8500cf` |
| `room/worker-reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `ca1cc3a3f8bf7ef9438dbe7cd9cdbcb9bdeb93be575cf2e586b8fb7fbf3c5061` |
| `room/worker-reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `b68dab71e2c91135be5608256f5a407387b94b63bbf41793ba2797dd34207171` |
| `room/worker-reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `5638af1990119d7ac235864f6e9064b2b717352c800240cdd63dc4239d53bd28` |
| `room/worker-reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `677f6b8c2ed753eb854ba3bbf888ca3630cfe20d24fe9dc04f36a84c6dc4d49b` |
| `room/worker-reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-reach` | `21133` | 2026-08-18 | generated for this repo | `1b925416b76652b18a14a6b6663ac0a3ec4d7d5483f09ce11dcf3361a6752b3f` |
| `room/worker-read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `321d135d752815ab5048ec27a95e83a21c102276b82c0a7e5f972dadbe097d5c` |
| `room/worker-read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `acd1280aa46bbfe95a21517feff384cf74d62e106b9c91e7a233fddbaac454c2` |
| `room/worker-read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `511ef3fa4851bd596044c1f991882d5e87202efd69400a088ee4d3839202d1a4` |
| `room/worker-read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `98cb1f539b3f79c65d766d7c18999ce18554ab11219b3fb3410c8ff7d33dbf68` |
| `room/worker-read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `b17753b3f2ba27afc335d3ec4d0585248a91ffa0388ecb2c7d6734544258d8a1` |
| `room/worker-read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `32507844b9861d5e6a3c299f59b3c2fd3f17b9806db05cf4880c413d99db1a85` |
| `room/worker-read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `a353ce40c4f505c1eb8a8d5da34986e1fd9658e03e7cbcda9e2b5eaae3c16c8b` |
| `room/worker-read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-read8` | `21104` | 2026-08-18 | generated for this repo | `972769be00e30c8fdb260908be1dc7d7da8597729609d300560b97fa3fafffab` |
| `room/worker-toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `cb39b7290fa5d6994aca5a5aa2ca3152014ef783c722324f8c4e4644500e00d8` |
| `room/worker-toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `82f4293252b7fc42ca17e12620b115383ccfb1b4807cec54780c31ec48de6520` |
| `room/worker-toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `48989a302a28d445f6a490108894d7a15c64097277a2efc759c86f4202478574` |
| `room/worker-toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `4d4f93acb7ee8fdddf3851628b327ed821347842393c6408b459759e36998713` |
| `room/worker-toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `1734bb6bce6be7c20e59a82e37cfa8601f92b584d599d234d6108d9d98a6c502` |
| `room/worker-toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `cb001b777802a41ab6af5bb0da05f5373187e7125bdf99343777e2dba979a9bf` |
| `room/worker-toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `06c298e8fdc89d0f86ff79088d5da799429bd901b58aa03fd6179074f8e6a8b5` |
| `room/worker-toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `room-worker-toast` | `21155` | 2026-08-18 | generated for this repo | `4ea97cf5cb62763e15ff404438e1363436045757b5a73351cc8fdfbae93b3955` |
| `room/worker-watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `3d70f212d7502ac75acc3f702ae930e4071e7a8dd5771d0806c0950a780127ad` |
| `room/worker-watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `f7dfb74776d10a0b483c038c55772a3f0ca0dec660da3a944829063074f603a0` |
| `room/worker-watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `1e464a9ca043362a036d41e04e8c5401b118e6301d3800206c943065b52db0da` |
| `room/worker-watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `466001d468cb9e0ae399003e342607af9bb56aae2d2725a7e938a919afd0b3a3` |
| `room/worker-watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `e75bd7db65cecf899776affab605434728d900dde392352e6f689897a4ca3bc1` |
| `room/worker-watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `c234f93dc69fa64e23485cad6baad2675bb5da0fe2fca34254bebddeb4e3218c` |
| `room/worker-watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `bfff5daf60b2a4eea71c57321350377cba75aca1a86ff1790778f38a0122f515` |
| `room/worker-watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `room-worker-watch8` | `21102` | 2026-08-18 | generated for this repo | `394c08f69fe083904a42f20042acb6a12f156f84bf53450cc969bb6ba9b54e6a` |

#### `crew/angel`

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `crew/angel/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `d5b63895f9fe2e5258e078971f0e738dc87893619440bd262bd6047d3a8651ba` |
| `crew/angel/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `b3640c9e270fc785689db18a2e6ca2d68cc8197644dbe13b3dcb2c59d4205279` |
| `crew/angel/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `60934e082602f2c214b18bb42425bdc7418063bd654807b53c8095088e324eb1` |
| `crew/angel/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `1dc9228fbabac3741e0708862c0dfe13d198893eedb6382a2019edd643afdda0` |
| `crew/angel/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `149279fd2a87f187c207b0f87a6f7f5ee75b4b9e380e3ae488a004d4e8f6a0e7` |
| `crew/angel/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `d1fb26041bd794b63974ca4076747ab1a5267532d92cb18ba9aa5c70ab16650e` |
| `crew/angel/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `7ed01fba05884ef0d23f2da8a913990efa801c3b01b1dc30ecf423c2a5405a11` |
| `crew/angel/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-done8` | `21206` | 2026-08-18 | generated for this repo | `89c3d7205a1a7a36a9707dd5b051e0c5abfef247823abf775f7a95ac22562cc4` |
| `crew/angel/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `0c5aea16cf4ce1b40cfb2380f682db5cf09cc8e4cd6236a3c2fb95a4518237cc` |
| `crew/angel/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `89ec2c62f75345691233bd8e52264de8f3a84ad4d40f100c2ac72cba86e16926` |
| `crew/angel/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `6885384884413892ed44832f95b5fe838afc444dce388609572cd400703893e0` |
| `crew/angel/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `bf75bdb268eb39bbeed4ea12ae6d48d8f9c1d92000a8dfebffbf07b4e97e3d7e` |
| `crew/angel/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `330927426144f5f311ccfab751fb393f97ada99879d026cbcfdab840c65d533e` |
| `crew/angel/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `21afb6575aac6308d918f8a0a83dbe47c6973ac3fca30b2a0320a8c7b6f016c7` |
| `crew/angel/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `c2bfe2bd062b284ea8b9d30026fbd66efe90365d8c00024a65eb9ab1c492863d` |
| `crew/angel/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-lean` | `21201` | 2026-08-18 | generated for this repo | `b034a4137c8dba1d3bfaccf8324a0113cb8d4316f03f9bcba0eb292fcee84ae9` |
| `crew/angel/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `aa9e76f3990dfc8e3e3403d8025db4cdc8d89a10c6faef54f9aba05465c14f67` |
| `crew/angel/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `dc64faa174b0a4b175057d9cb0f2698996eb427b36df76aa53274c654d8e2c31` |
| `crew/angel/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `e443f41fd10aa446898b50023c2a19f4e0b140208032d88dc46a8db7febf0cd2` |
| `crew/angel/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `818eccb4f3bcedbc1e2674742438f108be13c56b5f7f8805c24511faf482bdf7` |
| `crew/angel/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `effa55572f419200fa06f6ce893e2d81db9f369764039766918f732c7b0762d1` |
| `crew/angel/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `9fc4f59648682558985793e151a8ebe20463163d4fd491d7093b4acc347916a2` |
| `crew/angel/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `7707d909861477397157c82108b5b0bcb27684b51d4d009276cd2c47548b8a27` |
| `crew/angel/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-reach` | `21243` | 2026-08-18 | generated for this repo | `8e89e6aa938efb4679acc148651bfe02052645285d5d5cf5fd2f53d057c9c65c` |
| `crew/angel/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `d88f02b2dd5cb401fe5c466790cccb5a5608d288bfab0822a9ddad1793fca023` |
| `crew/angel/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `6c13de7ccad33954567b05124096a57c9c4728b20cbe135ee92ac3e2985ec8f7` |
| `crew/angel/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `f69c424a51b446242d91b2d18d01c3a412427d273707623e5c9d24f7016de447` |
| `crew/angel/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `0b892e95ea371f0ca2e5581d352907c8f18fd1d43ecff9f99536542ebaffd17a` |
| `crew/angel/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `5f43af3aa2b1c679681aa79d16aea617bd249b91f0f81829fbd4437e1f74db9d` |
| `crew/angel/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `141ec1e9d2cb89fd5698494cb02cd92842af5ff81474ec76d910b70efd6678df` |
| `crew/angel/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `ad4d61e868d1aa6f0fa0c9e570e4840eaadc6fa8929643527b22f29ed2c6446d` |
| `crew/angel/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-read8` | `21204` | 2026-08-18 | generated for this repo | `8e59ad4048d1bee5d17a0a489237265bef82ad5ef768d98afc0c257b80261dbd` |
| `crew/angel/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `17e2670d312ddcf04abb1e5f8363b10b72d9027a8d3f70e0174ce661477f6ae6` |
| `crew/angel/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `8a669c215a5bb6f690192faeff9bc30374a403c73ba56f1becc71f8f4a8cdcc7` |
| `crew/angel/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `743c1134756aeb4e920aae4f461b1f22fb894fb5b46631c1886343b02093ba6a` |
| `crew/angel/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `c885fddf7b23446d9cf404cbf2b978b31eb021469d074a9de9b24d24e85cfd47` |
| `crew/angel/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `c98e5edc291e03909d13cf09d95bd2bda82d375a29e1bb72b3c9bd63f39b7a1e` |
| `crew/angel/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `e8208f2a4631c94396455565a4096c447734e80005ec1c4b0a1164bea64cbbf4` |
| `crew/angel/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `7a51d8f02ab7acbb784b71e548ba0459ad910ef87ce923d69c502bbfd760a89d` |
| `crew/angel/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-angel-toast` | `21265` | 2026-08-18 | generated for this repo | `078b5851f7b4557dee3883c193d97c538347c0d566829d529959a5c7d014336a` |
| `crew/angel/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `2d0263e40fbb6561b28a0c8b1b1e27916c74d2a7e78fc5941f1486654067fa8a` |
| `crew/angel/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `b554a9529621d249a43b77e34b49a4c3259c767664301bea4ed4e4ca4cdd7e32` |
| `crew/angel/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `b1e8562166ac91e9bd0275227ebb96d12b2981f9ec0d19bf99732234f8ee1dcc` |
| `crew/angel/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `cf02482e8593b45fb89edffc317de2a97695f36d4a1e68d7d4115efeb76ecf94` |
| `crew/angel/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `ee6c620b5a4b66848a67d52a3c985e6e02e3654d4b8630d568b2a2ad6b888bd9` |
| `crew/angel/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `ac7dd2b28ab8262fe2ffd7859b658a01a91ebd2de17f0016f73f30d4ecfbf6fe` |
| `crew/angel/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `0dc9112373c1b2cad1fdfad2aa5cea84fab5ee4e4f44645a627e1090823ba916` |
| `crew/angel/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-watch8` | `21202` | 2026-08-18 | generated for this repo | `6130580038aadc21da1af03d905858ad89d69e7f972bfca0b4e9733eefd1413a` |

#### `crew/emre`

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `crew/emre/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `c9d7800e22eefed9002cec2e6b5037f6135dd6d1f6a7e474cd9b3b2f710638c6` |
| `crew/emre/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `ff7498c801cb6276d846cd02b08ecd7ddac6bf098dfe07e91824c783d4865d8c` |
| `crew/emre/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `c887af359293d49e858b2603016b4a4789a98e376d5ac21a0293cd0d213f484d` |
| `crew/emre/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `59810705b4a3ac3456a6c343116d841b17f30ac83ef782b2ddd48a42f942207c` |
| `crew/emre/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `aac430c0dcc2e6990769f58a3b57288227b2c756ce9e887917e14fb21f9d83c0` |
| `crew/emre/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `249b1183866bcfdbc4813a3b862ab4cdc7ebdf893923a102298a1de28bb079a5` |
| `crew/emre/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `9c917a46e001a22c3e52d0b19dc129f8122914577824d3cd92c8a521e54624e4` |
| `crew/emre/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-done8` | `21306` | 2026-08-18 | generated for this repo | `d6d94182563f76e89e5d9b52cab5bdd18e714cacd5310a4d57e666899ec2b683` |
| `crew/emre/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `96ffe6125ce1aa6a354eaacf858e9370cfb746aed62d1d4d011d942162e008e6` |
| `crew/emre/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `60b4e4cff4893d307034b3fe2ccf43f6b4e2eafb4a89935483049676f6a18084` |
| `crew/emre/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `b1b01c0c9c333487491d3e84215e64dc3fbd0ef5c4f494189eba2a3c12c901f5` |
| `crew/emre/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `e76bad0230921a0e34e97992f34bb8c3e0ff88abf59a5ab82c06c3ea1d0c5724` |
| `crew/emre/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `0be7c52f1a5b6e049ed721be3896d0a21019559f26f6735544b8c26658e49674` |
| `crew/emre/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `3b6d9d439844e86dc87f451662d1dc618ad79d98b7111a3f424dd1da1f300c55` |
| `crew/emre/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `51e6f8059b81be6a3032047d1b2d306829b0efe4601752b2274d65e9c4a3d709` |
| `crew/emre/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-lean` | `21301` | 2026-08-18 | generated for this repo | `f841e7f41b03a36a4233f3086a2375a25acbcce30a938760e9b3ec7e3485f6b5` |
| `crew/emre/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `2c598505f331b4ebc2698b065059b8a80d9c76b27c4feef1067ba0b47ff1a840` |
| `crew/emre/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `435c97ef3e490d7874e2c254037acf80ac7010838c1eb4d1d486d875d7675267` |
| `crew/emre/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `0ad79bc10db9dbfcd067942bee16a85afd8414b44694f58e3838996013a406f9` |
| `crew/emre/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `325badf4446ad458afe2892f68d16e1e04be04dc88a7fbb2c47225c68ed1850f` |
| `crew/emre/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `4b03c1689409db190cf23494cb68c8e44e60a531639d3acda04c3fb9bd56c3de` |
| `crew/emre/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `69579fc88830961492a54d28f3388ddcf5f59caf5f08b61d25d35bf6c4f4cd99` |
| `crew/emre/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `fc4e9faf98889f000c889f80422dc5d53d12fa0328e4379b42da7b6672166fcd` |
| `crew/emre/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-reach` | `21343` | 2026-08-18 | generated for this repo | `cbba810869c5a9188ac01665bf1a48cc769f9eb3a028bdf53123581765d8d679` |
| `crew/emre/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `d39384185060aba5a9756e5ecbd30a0364a8f95d23a59c1c3ef0006609eba51d` |
| `crew/emre/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `2b8e7b5e1ce1bdf8d8babaf00b9fdf52b3efda098882dd02777a2e615540cfe2` |
| `crew/emre/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `551009514ac7b54abb2a4cdc8018a4f00bf64172d215c1991e6e25106adb9daf` |
| `crew/emre/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `1b109f69cafd754e6f307e37a050b0ec466023321d7a6aa6b554bb2d3ddeb2f0` |
| `crew/emre/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `95f7b5366c1fa544b40937b909d968734dbac40ccd93725914fc49cf1d9cde74` |
| `crew/emre/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `6e326bee9428a615828ef228233a195a53bfbc0e5bfdbbd351e9eb3bd3348cfe` |
| `crew/emre/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `d576bcf649d45b0fb314c014d4000bfe29af21ffbbbbb0526f54b8afa6eabd19` |
| `crew/emre/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-read8` | `21304` | 2026-08-18 | generated for this repo | `bcc8921487380037bd5b6830d4db356495b7bd677384bb94d279c16aa2def584` |
| `crew/emre/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `d4965574ac48fc2867d4ef42af351af99de07af68da34562a4cbecede87e0e3c` |
| `crew/emre/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `f57b754068194df8da2b255f30949690cc8b12146e7edc27b897cc763b9bfca9` |
| `crew/emre/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `9b824a1b10e9b34939900d450976acbb6b485f63d3e4c91a9a4e77002cc88d8c` |
| `crew/emre/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `2b3069b479bf1258d4f6c27b90c430c783f8881e83e788c8bfb2e334db1d826e` |
| `crew/emre/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `c25d8b05abaa3420f57d2b85b836e52218a82e0b552973ee5fcffef538ade15e` |
| `crew/emre/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `0a77aaf21ffe8301aa2da65c057dbfefced1fcccfd8c27c032f2889e6b2ae8b5` |
| `crew/emre/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `b52353c8a66754b8c947d1a2e473ec1e1a60b5baf29bee9b26d1ab21c7aa5f7f` |
| `crew/emre/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-emre-toast` | `21355` | 2026-08-18 | generated for this repo | `cdbf651375b3e02f9c4ccebcc2819ad41a730ff8079277adfadf45d6274742f8` |
| `crew/emre/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `3ce43342dba4b7cc0697dff96cef2620684a80fef878b0cc47742f707c495296` |
| `crew/emre/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `5893ce27cb252d980b7f0c42027ba6772e8b5be05c07ad4c7fd8d0fafbc6298a` |
| `crew/emre/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `2f44e1685b1c0edc04ec37bd232e94419f32e2264ba7485c0bc5a583ce722097` |
| `crew/emre/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `62fdccfcc88b597798e5754d8ad2131e2ee3dba3f63a849a6331ec7afa6c11fc` |
| `crew/emre/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `96b62013c455b5170127f87eabddbf61543fccb1f1fda18307edcd8820ba63db` |
| `crew/emre/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `618537a8d493657be513b1ad4b7e2c87218a5c505e4c371f8b115e89628392d7` |
| `crew/emre/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `85590004967c541930e708a865f5d07eff563a86bb184f39d8eed72ad4c130c8` |
| `crew/emre/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-emre-watch8` | `21302` | 2026-08-18 | generated for this repo | `d2989014cfeefed917fb5d47b00e404a8468dd52a31154b788eec0888d2be23d` |

#### `crew/ran`

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `crew/ran/done8-0.png` | it shipped, the mug up, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `b62a768e939be80cf760ef83e62498b124a9f1adf6e24de9ecb15c56e2ac3099` |
| `crew/ran/done8-1.png` | it shipped, the mug up, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `84775076b021222bfe0eb68917d0c359499ae53402f933ff714814bbc104f026` |
| `crew/ran/done8-2.png` | it shipped, the mug up, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `74952b77579a699904de35e9512fa94eb8d8f1da5dd397a9ab04d24677a8dab5` |
| `crew/ran/done8-3.png` | it shipped, the mug up, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `5676981604cb0c782f91cd6e92ee19ee8a9031aaed1a096775bf9e3f952d7811` |
| `crew/ran/done8-4.png` | it shipped, the mug up, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `78b5452e976011e15e729f2bba27db6cdc55fbe3a47657f05a739ec39dae4633` |
| `crew/ran/done8-5.png` | it shipped, the mug up, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `4085af966af2372cf7881da11ad2481adf09b61dd70c924d93644f916581636a` |
| `crew/ran/done8-6.png` | it shipped, the mug up, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `f8756fba0824504444157cc4aa67166f1811a5a338fdd5f27f1e6f3e90782ee8` |
| `crew/ran/done8-7.png` | it shipped, the mug up, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-done8` | `21406` | 2026-08-18 | generated for this repo | `154b2ba88774f39e1d196e39b62d063eb3c0e9347464daf07acd364506323dd6` |
| `crew/ran/lean-0.png` | the move into the gate pose, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `0d1c5baeefa90363837492b17f1bc0a3ede58f9cde00e0a3058f3ae5dded1ab3` |
| `crew/ran/lean-1.png` | the move into the gate pose, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `18119cc514401f428e3e9284b031dd0763577421161a7dcd4f38bb1c95996423` |
| `crew/ran/lean-2.png` | the move into the gate pose, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `4c211bde946489beb90287654aea2ae27cb2031656ada2bf226cd9a0dc70a852` |
| `crew/ran/lean-3.png` | the move into the gate pose, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `7d27e56a7e89f88f5e73867b7ea3c0031097845ecd677d044f632d54205f9614` |
| `crew/ran/lean-4.png` | the move into the gate pose, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `843fea5d8289a2970bae47d60d0dbbe7f6db680bc0ed50f096c48f4d6b331c00` |
| `crew/ran/lean-5.png` | the move into the gate pose, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `037092d1cf8a14c9e2f621af0bd66df52a9fc1d6aefdda960891d0cfda2eeed4` |
| `crew/ran/lean-6.png` | the move into the gate pose, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `7e03c97a63249a0540dba88931ca79c24d9b9ea43f856fec943de619618e8c5c` |
| `crew/ran/lean-7.png` | the move into the gate pose, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-lean` | `21401` | 2026-08-18 | generated for this repo | `63bd3a1960d141999626e80ccd34abd541c908058981500979de41c355222c30` |
| `crew/ran/reach-0.png` | the move onto the mouse, frame 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `e271242fc78226698b38504ddfa12380de4be10cdc39a51d4c924660429ce23a` |
| `crew/ran/reach-1.png` | the move onto the mouse, frame 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `14c71a59c32f640ea111a73fc0f37bbda60b9cc87ef9827600a778e0deeaa1cd` |
| `crew/ran/reach-2.png` | the move onto the mouse, frame 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `0e13db38030ab91ea03fc502eb9dd9126b455b57cf1208e087660186ba1870b0` |
| `crew/ran/reach-3.png` | the move onto the mouse, frame 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `0123b0b2cc79fb3adc96771f58c93a4ec1b1c44808d9c0e29a44d87280b223e7` |
| `crew/ran/reach-4.png` | the move onto the mouse, frame 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `ec869937e1c0309013d4d0bb03e9caf8bca12400f0a1887531b9884690f4f91e` |
| `crew/ran/reach-5.png` | the move onto the mouse, frame 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `6e8164ca73302cb302789135cb2de5f20795b3f30ca85b141c4eb662f6413961` |
| `crew/ran/reach-6.png` | the move onto the mouse, frame 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `b85d3d71c2755f494daeee0a6cfd23328bba33b678a35632b4ca8fe3594efea3` |
| `crew/ran/reach-7.png` | the move onto the mouse, frame 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-reach` | `21433` | 2026-08-18 | generated for this repo | `9c3ba4ab45162ffdbdca9c7c3e0ce46020b8bbbfaa44c904f6e0d0571f73ecf4` |
| `crew/ran/read8-0.png` | reading the diff, scroll 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `b7e715e5dd04ff76523f3901df361d7bf5e0a4f55cd415d955c8574334da191c` |
| `crew/ran/read8-1.png` | reading the diff, scroll 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `1fd7a64dbed8aa6783f554f01269528fe3e87fe59743ec0a291b321eac396cd0` |
| `crew/ran/read8-2.png` | reading the diff, scroll 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `2ea418aed635772ef0cf8d1496c3115482d07c46fd104d7a1c6356a822ab76e3` |
| `crew/ran/read8-3.png` | reading the diff, scroll 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `7116b78eae5b5cc91220394308eaa2a822f484fc0a4c6b4e88f31f06b117a7ae` |
| `crew/ran/read8-4.png` | reading the diff, scroll 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `ef638d86725784ae5284d9c877ad533887cb78294534e7016c40ba3b1c9c53cc` |
| `crew/ran/read8-5.png` | reading the diff, scroll 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `1d30fc94ae4731f1c6121d520dc758af60cca6fc9dfa45ef740d3df10b41bda7` |
| `crew/ran/read8-6.png` | reading the diff, scroll 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `8afde962447b8ddfd8f0214431a6c0ba3adbd031329130acf73bf5143a9d84b8` |
| `crew/ran/read8-7.png` | reading the diff, scroll 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-read8` | `21404` | 2026-08-18 | generated for this repo | `c9c96aeebe49f562611ec244d3a6daedeb1a68fea5aafcdc5b2cd2c1c670c860` |
| `crew/ran/toast-0.png` | the move that lifts the mug, frame 1 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `6b0b7bdaa56b0f8591823b89338d351bad08ba6d1449a550ae5513a53d711a49` |
| `crew/ran/toast-1.png` | the move that lifts the mug, frame 2 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `3db8b574817f2126b3ad2acf138af394aec76babdb5a96e998614560f4ae3b24` |
| `crew/ran/toast-2.png` | the move that lifts the mug, frame 3 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `683ba31618f05debe9c3e0dba86aaf4795c4e2797b46eb9c9a398eb63df03e6f` |
| `crew/ran/toast-3.png` | the move that lifts the mug, frame 4 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `92193a8392ed76553d3ba4226bdcd3bda2f62d7677d80022157320de0d606471` |
| `crew/ran/toast-4.png` | the move that lifts the mug, frame 5 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `b08b168d15df46b90eaa9a9f664bbfb1e4d2e05af1915fb1a7fb0d9c325a2bd3` |
| `crew/ran/toast-5.png` | the move that lifts the mug, frame 6 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `9e0038584c498a5d6c9cc3949e4e066d42b4c05bdb49c4f48ceec338fe1aadfb` |
| `crew/ran/toast-6.png` | the move that lifts the mug, frame 7 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `ccca56c4f24399b363c0e399adcd4f136b65093e3fe83cc55a18bdc41f952014` |
| `crew/ran/toast-7.png` | the move that lifts the mug, frame 8 of 8 - only the band below the split is drawn | pixellab.animate (interpolated) | `/animate-with-text-v3` | `crew-ran-toast` | `21455` | 2026-08-18 | generated for this repo | `fbd46316689857422356bdd25e8173f4dadfc53ef50084d0b89b916264aa1f23` |
| `crew/ran/watch8-0.png` | watching the tests run, arms folded, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `df8c3f716f37ca28c23fe027f7f0594a1dde1d0c776c303f07d63ac3698e4f95` |
| `crew/ran/watch8-1.png` | watching the tests run, arms folded, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `4a335b40dc28b38e79af174c323eb885a17001f12603d9ec50dc57374cc114fe` |
| `crew/ran/watch8-2.png` | watching the tests run, arms folded, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `d1e192bfa5309dd10bd209cf530f2be4c67177707da4f5b805c7565206ff87a6` |
| `crew/ran/watch8-3.png` | watching the tests run, arms folded, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `a3958fc09f69d8fab954889c655bb40e1b7acba57f531acd62ccb54a76ee3861` |
| `crew/ran/watch8-4.png` | watching the tests run, arms folded, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `31e259e99a4aac6910033be105aaeaecc66f6e5c488b42543eab4c6f6c5c80aa` |
| `crew/ran/watch8-5.png` | watching the tests run, arms folded, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `ee871da45e33ff58d9f4217e0476015bd7d1b6ad4b5b8d5635dd684805f44a6b` |
| `crew/ran/watch8-6.png` | watching the tests run, arms folded, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `8b2ec501afad7c103825697f6bf0efeb27ac9db90be6875016650d7b3c6699e7` |
| `crew/ran/watch8-7.png` | watching the tests run, arms folded, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-ran-watch8` | `21402` | 2026-08-18 | generated for this repo | `8b93b1d7db6ad970ad37c964e0decc13dd090484b35819c30888d8857d70a54e` |

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
