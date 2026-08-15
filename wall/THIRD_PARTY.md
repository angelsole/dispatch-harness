# Third-party code in the wall

The doctrine is *nothing the wall needs leaves this machine* — not *nothing was
ever written by somebody else*. Everything the page can load ships in this
repo, and everything in this repo that somebody else wrote is listed here, with
the hash that says which build of it we are running.

A row is the pin. Replacing a file under `wall/vendor/` without updating its
row here fails `tests/wall.test.sh`, which re-hashes every non-markdown file in
that directory and compares.

| path | what | version | license | upstream | sha256 |
|---|---|---|---|---|---|
| `wall/vendor/phaser.min.js` | Phaser — the WebGL/Canvas game framework the `?world=canvas` city is drawn with | 4.2.1 | MIT (`wall/vendor/PHASER-LICENSE.md`) | https://www.npmjs.com/package/phaser/v/4.2.1 (`dist/phaser.min.js`) | `66348b1b5141e49b7d5ebbe688cddcb502eab1cb00f21c538686a5b2c5abe4de` |

## Why it is here rather than in a package.json

The wall runs on a screen that can reach this machine and nothing else, and it
starts with `bash wall.sh` on a box with node and no build step. A dependency
that has to be installed before the city lights is a dependency the TV does not
have. So the bundle is committed, pinned by hash, marked `-diff
linguist-vendored` in `.gitattributes`, and served from `/vendor/` by the same
`STATIC` table that serves `wall.css`.

## Updating it

1. Drop the new `dist/phaser.min.js` in `wall/vendor/`.
2. Copy the release's `LICENSE` beside it as `PHASER-LICENSE.md` if it changed.
3. `shasum -a 256 wall/vendor/phaser.min.js` and put the digest in the row above,
   with the new version.
4. `bash gate.sh`.
