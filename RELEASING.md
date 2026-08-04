# Releasing

This repo was exported from a private, single-tenant working copy and
generalized for publication. Publishing is a **manual** step — this checklist is
the gate to run before flipping the repository public. Do not automate the flip.

## 0. Confirm the excluded secret-bearing files never came back

These are gitignored and were deliberately left out of the export. The repo
ships only their `*.example` templates. Verify none exist as tracked files:

```bash
git ls-files | grep -E '^(notify\.conf|demo\.conf\.sh|repos\.local\.sh)$|^auth/|^runs/' \
  && echo "LEAK: real config tracked" || echo "ok — only *.example templates ship"
```

## 1. Final identifier sweep

Grep the whole tree (tracked and untracked) for anything tenant-specific that
survived generalization. Build the pattern from **your own** identifiers — the
former organization/product names, your username and home path, any
notification topic, and any storage domain used in the private copy:

```bash
# Replace the placeholders with the literal strings from your private setup.
PATTERN='<org-name>|<product-name>|<unix-username>|<ntfy-topic>|<storage-domain>'
grep -rIiE "$PATTERN" . --exclude-dir=.git --exclude-dir=.harness \
  && echo "IDENTIFIER LEAK — sanitize before publishing" || echo "clean"
```

Also skim for absolute machine paths that shouldn't ship:

```bash
grep -rIn "/Users/\|/home/" . --exclude-dir=.git --exclude-dir=.harness
```

Every script honors `HARNESS_DIR`; the only default path that should remain is
`$HOME/.claude/harness` (as a documented default, never a hardcoded absolute).

## 2. Secret scanning

Run at least one dedicated secret scanner over the full history, not just the
working tree — a squash (step 4) removes old commits, but scan *before* you rely
on that:

```bash
# pick whichever you have installed
gitleaks detect --source . --redact
trufflehog filesystem . --only-verified
```

Resolve every finding. Tokens, API keys, `.env` contents, and cookies/auth
state must not appear anywhere in history.

## 3. Gate + prerequisites

```bash
bash gate.sh          # shellcheck -x + bash -n on every shipped script,
                      # then every suite in tests/*.test.sh
```

Confirm the CI workflow ([`.github/workflows/gate.yml`](.github/workflows/gate.yml))
is present so the gate also runs on GitHub for every push and PR.

## 4. Squash to a single clean commit

The export history contains pre-sanitization commits. Collapse everything into
one clean commit so no intermediate state leaks tenant strings or secrets:

```bash
git checkout --orphan release
git add -A
git commit -m "Initial public release"
git branch -M release main      # replace main with the squashed branch
```

Re-run steps 1–3 on the squashed result before pushing.

## 5. Publish

- Push the squashed branch to the public remote.
- Confirm `LICENSE` (MIT) and `README.md` render correctly.
- Flip the repository to **public** in the host's settings (manual).
- Tag the release if you version it.

## Out of scope

Creating the GitHub repo, pushing, and the public flip are done by hand. The
pipeline pushes feature branches during normal operation; it does not publish
this repository.
