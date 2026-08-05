# Questions

Legacy quotes still render through the old PDF pipeline. Keep it behind a
feature flag for existing quotes, or migrate them all in this release?

- Option A: flag it, migrate lazily on the next edit.
- Option B: one-shot backfill, delete the old renderer in this PR.
