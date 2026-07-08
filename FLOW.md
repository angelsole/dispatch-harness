# Dispatch Harness — Flow

Multi-model pipeline: Planner researches and writes the brief (your session —
best results with Claude Fable 5; API credits or subscription) ·
Opus implements (Claude subscription) · Codex reviews (ChatGPT subscription) ·
deterministic gate + script glue (free).

## Main pipeline

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant F as Planner<br/>Fable 5 · your session
    participant S as run-task.sh<br/>script · free
    participant O as Opus<br/>implementer · Claude sub
    participant C as Codex<br/>reviewer · ChatGPT sub

    U->>F: /dispatch PROJ-1234 or free-form idea
    F->>F: research repo (Explore subagents)
    F->>U: brief.md — criteria + verify commands
    U->>F: approve (± create issue-tracker ticket)
    F->>S: launch run (background)
    S->>S: worktree from origin/staging<br/>copy .env · install deps
    S->>O: brief.md
    O->>O: design + implement + commit<br/>(Sonnet subagents explore)

    alt brief doesn't resolve a fork
        O->>F: QUESTIONS.md — needs_input ⏸
        F->>U: product forks only (arch: answers itself)
        U->>F: decisions
        F->>O: brief + answers — session resumes
    end

    S->>S: test gate #1 (per-repo cmds)
    S->>C: diff + brief + gate log
    C->>C: checklist: gate-gaming · business logic<br/>reuse · hardcoding · quality

    alt fundamental flaw
        C->>F: REJECTED.md
        F->>O: sharpened brief — re-dispatch
    else fixes / refactors in branch footprint
        C->>S: fix commits + review-notes.md<br/>(gate re-runs, max 2 rounds)
    end

    S->>S: push + draft PR (notes in body)
    S->>F: result.json — ready
    F->>U: verdict · preview.sh if frontend
    U->>F: approve
    F->>S: gh pr ready + cleanup.sh
    S->>U: PR ready for team · worktree cleaned
```

## Monitoring (ambient — nothing to remember)

```mermaid
flowchart LR
    R[("per-run files<br/>status · activity · feed.log")]
    R --> SL["Statusline in every Claude session<br/>run · model · current file · ±lines · sub usage"]
    R --> N["macOS notification<br/>per stage handoff"]
    R --> Z["zoom in: status.sh · attach.sh · preview.sh"]
```

To print: paste a block into https://mermaid.live → Export PNG/SVG,
or open this file in VS Code (Markdown Preview Mermaid Support).
