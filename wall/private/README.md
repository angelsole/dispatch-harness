# wall/private — bought art, never committed

Everything in this directory except this file is **gitignored** (`.gitignore`:
`wall/private/*`). The packs below are licensed to the owner, not to this
repository, and not one byte of them may ever be tracked. `git status` showing
a pack file is a bug in the ignore rule, not a file to add.

The wall serves this directory over one guarded route, `GET /private/<path>`
(`wall/server.js`), which is the `/assets/`-style handler: percent-decoded once,
`..`/absolute/NUL rejected, the resolved path re-checked to be under this
directory, extensions limited to `png json`, `Cache-Control: no-store`, 404 for
anything else. Nothing leaves the machine — the packs are read off local disk
and served to the TV on the tailnet, exactly like the rest of the wall.

## What goes here

| Path | Pack | Bought from |
|---|---|---|
| `beezeebox-exterior/` | BeezeeBox — *Cyberpunk Sci-Fi City Exterior* 16×16 v2.2 (`CyberPunk_Buildings_V2.png`, `CyberPunk_Objects_V2.png`, `CyberPunk_SignsGrafitti_V2.png`, `CyberPunk_Terrains.png`, `Animations/`, `Characters/Char1..5.png`) | itch.io — BeezeeBox |
| `beezeebox-interior/` | BeezeeBox — *Cyberpunk Sci-Fi City Interior* 16×16 (`Cyberpunk_Interiors.png`, `_Walls.png`, `_Floors.png`, `_DOORS.png`) | itch.io — BeezeeBox |
| `limezu-free/` | LimeZu — *Modern Interiors* FREE sampler (`Interiors_free/`, `Room_Builder_free_*`, `Characters_free/`) | itch.io — LimeZu (free sampler; the full Interiors/Office/Exteriors packs are bought separately) |

The LimeZu **free sampler is non-commercial** (`limezu-free/LICENSE.txt`). It is
here so a throwaway spike can show the look; the paid packs replace it before
anything ships.

## Layout

Mirror the pack's own folder names under a per-pack directory, so a file's path
here is the path it has in the download. `wall/world-topdown.js` declares the
exact list of files it loads (`PACK_FILES`); nothing else is ever requested, and
a file that is not in that list is not served to the page even though the route
would allow it.
