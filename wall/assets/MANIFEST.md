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
