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

The `prompt` column names the entry in `.creative/assets.json`, which carries
the wording each seed was drawn against. The two `animate` jobs took
`room/worker-type-0.png` as their first frame, which is why the whole figure —
the hood, the headphones, the jacket, the keyboard — is the same person in every
frame the room can show.

## How they are served

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
