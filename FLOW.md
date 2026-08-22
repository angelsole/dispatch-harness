# Dispatch Harness — Flow

Multi-model pipeline: Planner researches and writes the brief (your session —
best results with Claude Fable 5; API credits or subscription) ·
Opus implements (Claude subscription) · Codex reviews (ChatGPT subscription —
optional, skipped when the `codex` CLI is absent) ·
deterministic gate + script glue (free).

## Main pipeline

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant F as Planner<br/>API
    participant S as run-task.sh<br/>script · free
    participant O as Implementer<br/>Opus · Claude sub
    participant C as Reviewer · optional<br/>Codex · ChatGPT sub

    U->>F: /dispatch PROJ-1234 or free-form idea
    F->>F: research repo (Explore subagents)
    F->>U: brief.md — criteria + verify commands
    U->>F: approve (± create a ticket)
    F->>S: launch run (background)
    S->>S: worktree from origin/<base><br/>copy .env · install deps
    S->>O: brief.md
    O->>O: design + implement + commit<br/>(cheaper subagents explore)

    alt brief doesn't resolve a fork
        O->>F: QUESTIONS.md — needs_input ⏸
        F->>U: product forks only (arch: answers itself)
        U->>F: decisions
        F->>O: brief + answers — session resumes
    end

    S->>S: test gate #1 (per-repo cmds)
    S->>C: diff + brief + gate log
    C->>C: find: expected properties before the diff, then<br/>gate-gaming · logic · blind spots<br/>reuse · hardcoding · quality — fixes nothing

    alt fundamental flaw
        C->>F: REJECTED.md
        F->>O: sharpened brief — re-dispatch
    else findings
        C->>S: findings.json
        S->>C: refute — fresh session, disprove each
        C->>S: refuted.json — only survivors are promoted
        S->>C: fix — promoted findings only
        C->>S: one commit per finding + review-notes.md<br/>(gate re-runs, max 2 rounds)
    end

    S->>S: verify — third-vendor trajectory score (best-effort)
    S->>S: push + draft PR (notes in body)
    S->>F: result.json — ready
    F->>U: verdict · preview.sh if frontend
    U->>F: approve
    F->>S: gh pr ready + cleanup.sh
    S->>U: PR ready for review · worktree cleaned
```

The same block is inlined in [`README.md`](README.md); `tests/docs.test.sh`
asserts the two stay byte-identical.

## Claude-only mode (no `codex` CLI)

Cross-vendor review is the optional part; a review is not. When `codex` is not
installed the run pins the `claude_only` arm and takes the review straight to
the last tier: the same review prompt in a fresh Claude session, the same
evidence check, and the same `review_failed` hold — no PR — if it produces
nothing. `result.json` records `review: reviewed_claude` and the model that
reviewed. Base-sync merge conflicts (PR mechanics, not quality review) are then
resolved by a Claude worker instead of Codex. The only arm that ships without a
review is `no_review` (`HARNESS_SKIP_REVIEW=1`), which asks for that baseline
on purpose.

## Monitoring (ambient — nothing to remember)

```mermaid
flowchart LR
    R[("per-run files<br/>status · activity · feed.log")]
    R --> SL["statusline.sh in every Claude session<br/>run · model · current file · ±lines · elapsed"]
    R --> W["status.sh --watch<br/>live dashboard, no wiring needed"]
    R --> N["macOS notification<br/>per stage handoff"]
    R --> Z["zoom in: status.sh id · attach.sh · preview.sh"]
```

`statusline.sh` ships with the harness; `install.sh` offers to wire it into
`~/.claude/settings.json`, or append `statusline.sh --runs-only` to a statusline
you already have. `status.sh --watch` is the zero-config equivalent.

To print: paste a block into https://mermaid.live → Export PNG/SVG,
or open this file in VS Code (Markdown Preview Mermaid Support).
