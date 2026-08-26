# Dispatch Harness — Flow

Multi-model pipeline: Planner researches and writes the brief (your session —
best results with Claude Fable 5; API credits or subscription) ·
Opus implements (Claude subscription) · Codex reviews (ChatGPT subscription —
optional, skipped when the `codex` CLI is absent) ·
deterministic gate + script glue (free).

## Main pipeline

```mermaid
flowchart LR
    U(["👤 You<br/>/dispatch a ticket or a description"])
    B["📝 Brief<br/>acceptance criteria + verify commands<br/>you approve it"]
    I["🤖 Implementer<br/>Claude, alone in a fresh git worktree"]
    G{"✅ Deterministic gate<br/>your repo's lint · types · tests<br/>no model in the loop"}
    P["📬 Draft PR<br/>both models' notes in the body"]
    M(["🎉 You merge<br/>the pipeline never does"])

    subgraph REV ["🔎 Review — three passes, never the model that wrote the code"]
        direction LR
        F["🔍 Find<br/>a different vendor reads the diff cold<br/>reports, fixes nothing"]
        R["⚖️ Refute<br/>a fresh session tries to disprove every finding"]
        X["🔧 Fix<br/>survivors only, one commit per finding"]
        F --> R --> X
    end

    U --> B --> I --> G
    G -->|"green"| F
    G -->|"red — back to the implementer"| I
    I -.->|"a fork the brief didn't answer"| U
    X --> P --> M

    N["📎 A refutation only counts if it cites code<br/>the harness verifies byte-for-byte"]
    R -.- N

    classDef you fill:#c9d6e4,stroke:#54677d,color:#1a1a1a
    classDef implementer fill:#d9cfe9,stroke:#6f5f92,color:#1a1a1a
    classDef reviewer fill:#f2d9c0,stroke:#a5764a,color:#1a1a1a
    classDef script fill:#c8ddc9,stroke:#4f7f5b,color:#1a1a1a
    classDef callout fill:#efe4c2,stroke:#96814a,color:#1a1a1a
    class U,B,M you
    class I implementer
    class F,R,X reviewer
    class G,P script
    class N callout
```

The same block is inlined in [`README.md`](README.md); `tests/docs.test.sh`
asserts the two stay byte-identical.

## The same pipeline, step by step

Every stage and every branch, including the two optional stages the hero above
leaves out:

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
    S->>S: worktree from origin/<base><br/>copy .env · install deps<br/>(node_modules cloned CoW on a lockfile-cache hit)
    S->>O: brief.md<br/>+ factory keys, if MCP_CONFIG is pinned
    O->>O: design + implement + commit<br/>(cheaper subagents explore)

    opt MCP_CONFIG is pinned (repos with an asset factory)
        O->>O: PixelLab / Retro Diffusion via MCP or factory.py<br/>then the mandatory post-pass
    end

    alt brief doesn't resolve a fork
        O->>F: QUESTIONS.md — needs_input ⏸
        F->>U: product forks only (arch: answers itself)
        U->>F: decisions
        F->>O: brief + answers — session resumes
    end

    S->>S: test gate #1 (per-repo cmds)
    opt the visual profile applies (repos judged by eye)
        S->>S: visual gate: render fixed shots<br/>model-free checks · contact sheet
        S->>S: critic (fresh, no shell): rubric<br/>+ pairwise vs champion
        alt worse than the champion, or a check failed
            S->>C: visual fix round — frames + one_fix<br/>(Claude fallback when Codex is unavailable)
            C->>S: fix commits, then re-render
        end
    end

    S->>C: diff + brief + gate log<br/>+ contact-sheet.png + visual-score.json
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

## The visual gate (repos the visual profile applies to)

A stage between the test gate and the review, for work judged by eye. It renders
fixed shots headless, measures them without a model (palette, grid, luminance
floor, legibility, continuity, SSIM against the reigning champion), and then asks
one fresh critic — no shell, strict JSON schema — to grade a rubric and, the
verdict that decides the round, whether the challenger is **better or worse than
the champion**. Worse fails, however good the absolute scores are. A failure runs
a visual fix round on the normal fix backend (Codex when available, a fresh
Claude worker otherwise) and re-renders; when the rounds run out the run ends
`visual_failed` with the frames, the sheet and the critic's reasons, and no PR.
Champions are promoted by a human at milestones, never by the pipeline.

The profile applies to a repo that carries a `.creative/` contract or pins
`VISUAL_GATE_CMD`; for every other repo none of this exists. See
[Profiles](docs/reference.md#profiles) and
[`profiles/visual/creative/README.md`](profiles/visual/creative/README.md).

## The factory (repos that set `MCP_CONFIG`)

Not a stage — a set of hands the implementer has, and a rule about what it does
with them. Pinning `MCP_CONFIG` to
`profiles/visual/creative/factory.mcp.json` gives the worker the PixelLab and
Retro Diffusion MCP servers, and makes the visual profile source
`$HARNESS_DIR/factory.conf.sh` into **that process only**, through the same
`implementer_env` hook the GLM credential uses: the gate, the reviewer, the PR
stage and the live feed never see a key. Bulk work goes through
`profiles/visual/creative/factory.py` (frozen prompt templates, `seed =
sha256(id)`, a body-hash cache, a provenance manifest), and everything it
produces goes through `postpass.py` before it is an asset.

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
