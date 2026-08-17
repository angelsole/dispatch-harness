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
- **Which settles the pose lock.** Because the head band is the base, the box the
  room DRAWS is the base's box to within **1 px** across all sixty-four frames,
  against raw frames that drift up to 8 px on their own. The bases are the
  committed ones and their drift from `room/worker-type-0.png`'s 56x53+4+7 is
  what PR #44 recorded: room 0/0/0/0, Angel -3/+2/+1/-2, Emre +2/+3/-4/0,
  Ran +2/-2/-2/-2.
- **And the frames were drawn from the committed faces, not from a new roll.**
  Each base was regenerated at its committed seed first: none came back
  byte-identical (2592-3894 pixels differ, and the room worker's box moved to
  59x52+2+7), so none was adopted. The factory's body-hash cache was primed with
  the committed PNG instead, which is why every `animate` job's own frame 0 —
  the first frame it was handed, returned verbatim — post-passes back to the
  committed base byte for byte. Seven of the eight jobs did; `crew-emre-wait8`
  is the one that came back a hair off, and its frame 0 is not committed either
  way.

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
of each cycle are the animate job's frames 1-8. Its frame 0 is the first frame it
was handed, returned verbatim, and is not committed — the set already has that
file.

The lock is `room/worker-type-0.png`: opaque bounds **56x53 at +4+7** in a 64x64
canvas, seated, facing the viewer, hands on the keyboard, the same light. A new
character has to land in that box to be able to replace the worker at the same
room position, and `magick <file> -trim info:` is how that was checked. Where a
seed drifted it was re-rolled rather than retouched. What shipped:

| set | base | drift from the lock | frames |
|---|---|---|---|
| `crew/angel` | 53x55+5+5 | -3, +2, +1, -2 | 51-54 wide, 54-57 tall |
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
56x61+0+2 — but the room only draws them below the split, so the box it puts on
the wall is each base's own to within **1 px** for all sixty-four. The frames'
drift is a fact about the generator now, not about the picture.

| path | what | tool | endpoint | prompt | seed | date | origin | sha256 |
|---|---|---|---|---|---|---|---|---|
| `crew/angel/base.png` | the still every other frame of this set came from - the pose lock | pixellab.image | `/create-image-pixflux` | `crew-angel` | `17470` | 2026-08-17 | generated for this repo | `f9997780b2857e33653b0893a8aa301b4e67afd1862ea89cf9dc20a4126a4dc5` |
| `crew/angel/type-0.png` | typing, frame 1 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `5a6bfb0d11f1fceff9c88fc2581a3cf703998505a86b310568c6bd360411fb4f` |
| `crew/angel/type-1.png` | typing, frame 2 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `dd94a5ec4d18d53a6b5a3ab2ba7772936f399369314aa6e5f8ab81e6d904080b` |
| `crew/angel/type-2.png` | typing, frame 3 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `d813b773bae1924c34986c94d1e838d9f15757f0efc33e573306d4ed00c5b45f` |
| `crew/angel/type-3.png` | typing, frame 4 of 4 | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type` | `17441` | 2026-08-17 | generated for this repo | `62c92abbab003edfa41ab5930d834245de25c342e9c466fca3821a6972862666` |
| `crew/angel/wait-1.png` | waiting, hands off the keys - what a blocked run looks like | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait` | `17442` | 2026-08-17 | generated for this repo | `b6128840fcdb440e6002935e951434c3f27d8fb532e2f6bea893f6276b4df58f` |
| `crew/angel/wait-2.png` | waiting, second frame | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait` | `17442` | 2026-08-17 | generated for this repo | `4630d173fe12565d5b1a0039e9636d27f06d4dd469601f1825105a2ab8176203` |
| `crew/angel/type8-0.png` | typing, pose 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `9e89db224d7b867fa2705e5c9fd4779a0756f37c1693d3a92162dde4d0e838de` |
| `crew/angel/type8-1.png` | typing, pose 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `915af6547619bcb9984f3325cb73c827ae0d772d94bd6117d3370819b1d6f306` |
| `crew/angel/type8-2.png` | typing, pose 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `87f31338bd211f11c9adf925151341abc1d480b315c32531a136c9338a4cd01f` |
| `crew/angel/type8-3.png` | typing, pose 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `ab5ec51b7ea1f6763f79aa5a6a0c31d48a21d923929d64b90b9d32b34424358f` |
| `crew/angel/type8-4.png` | typing, pose 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `de3d728990f19e3289cc48e1fd80a8d2c882607323ef477b2bc391a6ffe2ffc7` |
| `crew/angel/type8-5.png` | typing, pose 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `959e216edbd40ea9301415a8ff98c930f1110ad24f30193c2912cb5705e62109` |
| `crew/angel/type8-6.png` | typing, pose 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `e578f60b6063a9f2ca2c204d5b86ad6cf8f55d99c1859768f708b3e5f9334b4b` |
| `crew/angel/type8-7.png` | typing, pose 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-type8` | `17941` | 2026-08-17 | generated for this repo | `c24bd5c9310b283d184c85f0bf4f9e3e765c61fa250c923a3f9c0003f4c56f02` |
| `crew/angel/wait8-0.png` | waiting, breath 1 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `de9a21d73b9bbac9e327dba69fbe0a655a1409d2a28cdf4fae7b863c363776e6` |
| `crew/angel/wait8-1.png` | waiting, breath 2 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `e6c72d51e3d49d0e150e6c1dc67a35857a329c4a458780cc21dc7fd555ec20d4` |
| `crew/angel/wait8-2.png` | waiting, breath 3 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `e8f36e2edee97cd51c4c3ec1aacd5e9f928fbe025e21bb0e9afa6b771e9398dc` |
| `crew/angel/wait8-3.png` | waiting, breath 4 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `534439e3fda7eeb5c76fcf6a2e3037685d4fe3c7c2c79be73fc5ff6e58b4bdfd` |
| `crew/angel/wait8-4.png` | waiting, breath 5 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `e0b9ecb2bbabb6f48dc507028fb4dead04e1e07d80215ddeb1a308b78ef2f156` |
| `crew/angel/wait8-5.png` | waiting, breath 6 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `b924800317464b85be1c8c36d75238a590de54f883f9d55701ee5362739a024f` |
| `crew/angel/wait8-6.png` | waiting, breath 7 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `f3923eeb1c2f28a3d42cbea3c6ec697521a32ebd73c72ce62b32d1a3ffe5ec54` |
| `crew/angel/wait8-7.png` | waiting, breath 8 of 8 - only the band below the split is drawn | pixellab.animate | `/animate-with-text-v3` | `crew-angel-wait8` | `17992` | 2026-08-17 | generated for this repo | `ff5e7786b6e2abf2ccbd2b3decb9b75d9c4c57fb5aefd541c2f85f31f6b56142` |
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
