# 0010. No third-party cockpit: the team surface is the tracker, the wall and the PR

- **Status**: Accepted — 2026-08-28

## Context

With four people and several machines, the harness needed a shared surface: a
place to see every run, and somewhere to act on one. An entire product category
had appeared to serve exactly that — Electron cockpits that adopt external git
worktrees, show diffs, and drive coding agents from a GUI. One of them was
evaluated seriously, at source level, along with the rest of the field.

Three findings decided it.

1. **The gaps a cockpit fills are small.** Of everything the team needed —
   cross-machine fan-in, per-owner notification, an approval mechanism, a
   shared record — a cockpit supplied two: a diff viewer, and a board. The
   rest it did not address at all.
2. **The hazards are structural.** A cockpit that launches an agent inside a
   live harness worktree drops the worker's deny list and the repo's provider
   pin; `.harness/` is a shared mailbox, so a foreign findings file or a commit
   past the implementer's head can forge review evidence; a read-only pass that
   resets a changed tree destroys work. Every one of these is a direct assault
   on [0003](0003-every-arm-reviews-or-holds.md) and
   [0004](0004-findings-must-survive-refutation.md).
3. **The category is not stable.** Several comparable projects launched and
   died inside six months. None of the survivors could attach to a running
   headless session, which is the one thing that would have been genuinely new.

The category's own history points the same way: the shared team surface that
actually ships, everywhere, is the ticket and the pull request.

## Decision

No third-party cockpit becomes the team surface, and no part of the pipeline is
ported onto another tool's orchestration protocol. The surface is assembled
from things the team already lives in:

- **The tracker.** The harness registers as an agent, so every run is a session
  on its ticket, with the run link one click away.
- **The wall.** Workers fan in over HTTP — stage posts, hook events and OTel
  metrics — so any machine's runs appear on one board without a shared
  filesystem.
- **The PR.** "Files changed" is the diff surface, at the moment that matters:
  approval.
- **Owner-routed notification** for the run that is actually yours.

A cockpit remains acceptable as a *personal* viewer, never pointed at a live
harness worktree.

## Consequences

- The team surface is built rather than bought, and its maintenance is the
  harness's problem. That work has been done and the alternative would have
  been a dependency on a pre-1.0 GUI whose CLI flags change between releases.
- No live steering, consistent with
  [0006](0006-no-live-steering-of-the-implementer.md) — a cockpit's headline
  feature was one the harness had already rejected.
- If this is revisited, start from the finding that the gaps are two and the
  hazards are three, not from the product's feature list.
