# Third-party code in the wall

The doctrine is *nothing the wall needs leaves this machine* — not *nothing was
ever written by somebody else*. Everything the page can load ships in this
repo, and everything in this repo that somebody else wrote is listed here, with
the hash that says which build of it we are running.

There are two pins, because code and art are not the same kind of thing:

- **Code is pinned by hash.** Replacing a file under `wall/vendor/` without
  updating its row here fails `tests/wall.test.sh`, which re-hashes every
  non-markdown file in that directory and compares. A minified bundle is
  unreadable, so the digest is the only honest statement about which build we
  are running.
- **Art is pinned by presence and by this manifest.** The pixels under
  `wall/assets/` are in the repository and are what the page draws; a hash of a
  PNG says nothing a reviewer can check by looking. Instead the suite holds the
  directory to the shape of this table: every top-level pack has a row here and
  a licence file inside it, every file the browser can load is declared in
  `ASSETS` in `wall/world-canvas.js` and served by `wall/server.js`, and nothing
  loadable sits in there unreferenced. Our own art carries a third pin: it is
  written by a committed script from pixel grids you can read as text, and the
  suite re-runs that script and compares.

| path | what | version | license | upstream | sha256 |
|---|---|---|---|---|---|
| `wall/vendor/phaser.min.js` | Phaser — the WebGL/Canvas game framework the `?world=canvas` city is drawn with | 4.2.1 | MIT (`wall/vendor/PHASER-LICENSE.md`) | https://www.npmjs.com/package/phaser/v/4.2.1 (`dist/phaser.min.js`) | `66348b1b5141e49b7d5ebbe688cddcb502eab1cb00f21c538686a5b2c5abe4de` |
| `wall/assets/warped-city/` | The canvas city's pixels: pedestrians and a cop (`people`), cars, a truck and a drone (`vehicles`), and the neon banners, screens and roof props hung on the district (`signs`). Three atlases packed from two packs by the same artist | packs downloaded 2026-08-15 | CC0 / public domain (`wall/assets/warped-city/LICENSE.txt`, both texts) | ansimuz (Luis Zuno) — https://opengameart.org/content/warped-city and https://opengameart.org/content/warped-city-2 | — |
| `wall/assets/ark-pixel/` | Ark Pixel Font, 12px proportional, `zh_hk` (traditional Chinese, Hong Kong glyph forms) — the face the canvas world's shop glyphs and the 冉 and 麵 signs are set in | release 2026.08.11 | SIL OFL 1.1 (`wall/assets/ark-pixel/OFL.txt`) | https://github.com/TakWolf/ark-pixel-font/releases/tag/2026.08.11 | — |
| `wall/assets/own/` | Ours, not third-party, listed here so the directory is complete: the noodle bar's cook and the silhouettes behind the district's lit windows, written by `make-own.js` beside them | — | CC0 1.0 (`wall/assets/own/LICENSE.txt`) | this repository | — |

## Why it is here rather than in a package.json

The wall runs on a screen that can reach this machine and nothing else, and it
starts with `bash wall.sh` on a box with node and no build step. A dependency
that has to be installed before the city lights is a dependency the TV does not
have. So the bundle is committed, pinned by hash, marked `-diff
linguist-vendored` in `.gitattributes`, and served from `/vendor/` by the same
`STATIC` table that serves `wall.css`.

The same argument applies to the art, one step further: a CDN sprite sheet is a
request that leaves the machine, and a build step that packs one is a build step.
So the atlases and the font are committed too, and `wall/server.js` serves them
from one guarded `/assets/` route that only ever hands out `.png`, `.json` and
`.woff2` from under `wall/assets/`.

## Updating the engine

1. Drop the new `dist/phaser.min.js` in `wall/vendor/`.
2. Copy the release's `LICENSE` beside it as `PHASER-LICENSE.md` if it changed.
3. `shasum -a 256 wall/vendor/phaser.min.js` and put the digest in the row above,
   with the new version.
4. `bash gate.sh`.

## Adding or changing art

1. Put the files in `wall/assets/<pack>/`, with the pack's licence text beside
   them. One directory per upstream; never loose files at the top level.
2. Add a row above: path, what it is, when it was taken, licence, upstream.
3. Declare every file the page loads in `ASSETS` at the top of
   `wall/world-canvas.js`. A file that is not in that list is not served, is not
   loaded, and fails the suite as a dead file.
4. `bash gate.sh`. For `wall/assets/own/`, edit the pixel grids in
   `make-own.js` and re-run it (`node wall/assets/own/make-own.js`) — the suite
   re-runs it with `--check` and fails if the committed PNG is not what the
   grids draw.
