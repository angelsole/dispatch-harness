#!/usr/bin/env bash
# Smoke test for setup-repo.sh. Fabricates throwaway repos under a temp
# HARNESS_DIR and asserts layer-1 detection, --write idempotency, generated-shell
# quoting, the unmanaged-file refusal, --ai JSON handling and the
# verify-blocks-write path. No network, no package installs (INSTALL_CMD/GATE_CMD
# are only run in the one cheap verify-refusal case, which has no gate to run).
#
# Usage: bash tests/setup-repo.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$SRC/setup-repo.sh"
CONF="$SRC/repos.conf.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-repo-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3"; fi; }
grep_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3"; else ok "$3"; fi; }

git_init() {  # $1 = dir
  git init -q "$1"
  : > "$1/.gitkeep"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# --- fixture 1: npm repo with type-check + test scripts and a CI workflow ----
NPM="$ROOT/webapp"
git_init "$NPM"
: > "$NPM/package-lock.json"
cat > "$NPM/package.json" <<'JSON'
{ "name": "webapp",
  "scripts": { "type-check": "tsc --noEmit", "test": "vitest run", "build": "vite build" } }
JSON
mkdir -p "$NPM/.github/workflows"
cat > "$NPM/.github/workflows/ci.yml" <<'YML'
jobs:
  test:
    steps:
      - run: npm test
YML

echo "== npm repo (composed gate, npm ci, base from origin/HEAD) =="
OUT="$(HARNESS_DIR="$ROOT/h1" bash "$SETUP" "$NPM")"
grep_ok "$OUT" "GATE_CMD='npm run type-check && npm test'" "npm: composed GATE_CMD"
grep_ok "$OUT" "INSTALL_CMD='npm ci'"                       "npm: INSTALL_CMD npm ci"
grep_ok "$OUT" "BASE_BRANCH='main'"                         "npm: BASE_BRANCH from origin/HEAD"
grep_ok "$OUT" 'CI runs: npm test'                         "npm: CI gate surfaced as hint"

# --- fixture 2: uv/python repo with ruff + pytest ----------------------------
UV="$ROOT/pysvc"
git_init "$UV"
: > "$UV/uv.lock"
cat > "$UV/pyproject.toml" <<'TOML'
[project]
name = "pysvc"
[tool.ruff]
line-length = 100
[tool.pytest.ini_options]
addopts = "-q"
TOML

echo "== uv repo (ruff + pytest, uv sync) =="
OUT="$(HARNESS_DIR="$ROOT/h2" bash "$SETUP" "$UV")"
grep_ok "$OUT" "GATE_CMD='uv run ruff check . && uv run pytest'" "uv: composed GATE_CMD"
grep_ok "$OUT" "INSTALL_CMD='uv sync'"                           "uv: INSTALL_CMD uv sync"

# --- fixture 3: repo with no known stack -------------------------------------
BARE="$ROOT/mystery"
git_init "$BARE"

echo "== bare repo (honest could-not-detect, invents nothing) =="
OUT="$(HARNESS_DIR="$ROOT/h3" bash "$SETUP" "$BARE")"
grep_not "$OUT" 'INSTALL_CMD='          "bare: no INSTALL_CMD invented in block"
grep_not "$OUT" 'GATE_CMD='             "bare: no GATE_CMD invented in block"
grep_ok  "$OUT" '(could not detect)'    "bare: reports could not detect"

# --- --write idempotency into a managed (example-derived) file ---------------
echo "== --write idempotency =="
H="$ROOT/hw"; mkdir -p "$H"
cp "$SRC/repos.local.sh.example" "$H/repos.local.sh"
HARNESS_DIR="$H" bash "$SETUP" "$NPM" --write >/dev/null
count() { grep -cE '^[[:space:]]*# repo:webapp[[:space:]]*$' "$H/repos.local.sh"; }
check "write: single managed arm inserted" "$(count)" "1"

# Sourceable, and returns the pinned values for the repo AND its -<ticket> variant.
verify_pins() {  # $1 = expected GATE_CMD
  (
    # shellcheck disable=SC1090
    . "$H/repos.local.sh"
    for key in webapp webapp-abc123; do
      BASE_BRANCH=""; INSTALL_CMD=""; GATE_CMD=""; MCP_CONFIG=""; ENV_SUBDIRS=""
      DEV_CMD=""; PREFLIGHT_CMD=""; DEMO_DEV_CMD=""; DEMO_PORT=""
      repo_config_local "/x/$key" "$key"
      [ "$GATE_CMD" = "$1" ] || { echo "MISMATCH:$key:$GATE_CMD"; exit 1; }
    done
  )
}
if bash -n "$H/repos.local.sh" 2>/dev/null; then ok "write: file parses (bash -n)"; else bad "write: file parses"; fi
if verify_pins "npm run type-check && npm test"; then ok "write: pins resolve for repo + -ticket variant"; else bad "write: pins resolve"; fi

# Re-write unchanged -> still exactly one arm (idempotent, no duplicate).
HARNESS_DIR="$H" bash "$SETUP" "$NPM" --write >/dev/null
check "write: re-run does not duplicate" "$(count)" "1"

# Change a detected value -> arm updates in place, still one arm.
cat > "$NPM/package.json" <<'JSON'
{ "name": "webapp",
  "scripts": { "lint": "eslint .", "test": "vitest run" } }
JSON
HARNESS_DIR="$H" bash "$SETUP" "$NPM" --write >/dev/null
check "write: still one arm after change" "$(count)" "1"
if verify_pins "npm run lint && npm test"; then ok "write: arm updated in place"; else bad "write: arm updated in place"; fi

# --- --provider: written only when asked for, kept once pinned ----------------
echo "== --provider =="
HP="$ROOT/hp"; mkdir -p "$HP"
cp "$SRC/repos.local.sh.example" "$HP/repos.local.sh"
hp_count() { grep -cE '^[[:space:]]*# repo:webapp[[:space:]]*$' "$HP/repos.local.sh"; }
provider_pin() {
  (
    # shellcheck disable=SC1090
    . "$HP/repos.local.sh"
    IMPLEMENTER_PROVIDER=""
    repo_config_local "/x/webapp" webapp
    printf '%s' "${IMPLEMENTER_PROVIDER:-}"
  )
}
HARNESS_DIR="$HP" bash "$SETUP" "$NPM" --write >/dev/null
check "provider: not detected into a fresh arm" "$(provider_pin)" ""

HARNESS_DIR="$HP" bash "$SETUP" "$NPM" --provider anthropic --write >/dev/null
check "provider: --provider anthropic lands in the arm" "$(provider_pin)" "anthropic"
check "provider: one arm, not two" "$(hp_count)" "1"

# The pin is policy, not detection: an update without --provider keeps it.
HARNESS_DIR="$HP" bash "$SETUP" "$NPM" --write >/dev/null
check "provider: a re-run without --provider keeps the pin" "$(provider_pin)" "anthropic"
check "provider: still one arm" "$(hp_count)" "1"

HARNESS_DIR="$HP" bash "$SETUP" "$NPM" --provider zai --write >/dev/null
check "provider: --provider zai updates the pin in place" "$(provider_pin)" "zai"

if HARNESS_DIR="$HP" bash "$SETUP" "$NPM" --provider openai --write >/dev/null 2>&1; then
  bad "provider: an unknown provider is refused"
else
  ok "provider: an unknown provider is refused"
fi
check "provider: the refused run wrote nothing" "$(provider_pin)" "zai"

# Generated shell must be literal: repo names/paths can contain shell syntax and
# --ai output is untrusted model text. Sourcing repos.local.sh must not execute
# command substitutions embedded in values.
echo "== generated shell quoting =="
ODD="$ROOT/odd'name"
git_init "$ODD"
ODD="$(cd "$ODD" && pwd)"
: > "$ODD/package-lock.json"
cat > "$ODD/package.json" <<'JSON'
{ "scripts": { "test": "vitest run" } }
JSON
: > "$ODD/.mcp.json"
HQ="$ROOT/hq"; mkdir -p "$HQ"
cp "$SRC/repos.local.sh.example" "$HQ/repos.local.sh"
if HARNESS_DIR="$HQ" bash "$SETUP" "$ODD" --write >/dev/null; then
  ok "quote: writes repo with single quote in its basename"
else
  bad "quote: writes repo with single quote in its basename"
fi
quote_check() {
  (
    # shellcheck disable=SC1090
    . "$HQ/repos.local.sh"
    GATE_CMD=""; MCP_CONFIG=""
    repo_config_local "/x/odd'name-ticket" "odd'name-ticket"
    [ "$GATE_CMD" = "npm test" ] && [ "$MCP_CONFIG" = "$ODD/.mcp.json" ]
  )
}
if quote_check; then ok "quote: pins resolve with literal quoted values"; else bad "quote: pins resolve"; fi

AI="$ROOT/aiapp"
git_init "$AI"
: > "$AI/package-lock.json"
cat > "$AI/package.json" <<'JSON'
{ "scripts": { "test": "vitest run" } }
JSON
FAKE="$ROOT/fake-claude"
PWNED="$ROOT/pwned"
cat > "$FAKE" <<SH
#!/usr/bin/env bash
printf '%s\n' '{"result":"{\"GATE_CMD\":\"echo \$(touch $PWNED)\",\"DEMO_PORT\":1234}"}'
SH
chmod +x "$FAKE"
HA="$ROOT/ha"; mkdir -p "$HA"
cp "$SRC/repos.local.sh.example" "$HA/repos.local.sh"
HARNESS_DIR="$HA" CLAUDE_BIN="$FAKE" bash "$SETUP" "$AI" --ai --write >/dev/null
if (
  # shellcheck disable=SC1090
  . "$HA/repos.local.sh"
); then
  ok "ai: generated repos.local.sh sources"
else
  bad "ai: generated repos.local.sh sources"
fi
if [ -e "$PWNED" ]; then
  bad "ai: source executed command substitution from model output"
else
  ok "ai: source treats model output as literal text"
fi

# An unusable CLAUDE_BIN makes setup-repo.sh fall back to a PATH lookup, so this
# case only exercises the no-claude path when PATH has no claude either —
# otherwise it fires a real model call (slow, and not a test of anything).
path_without_claude() {
  local out='' d
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] && [ ! -x "$d/claude" ] && out="$out${out:+:}$d"
  done
  printf '%s' "$out"
}
NO_CLAUDE_PATH="$(path_without_claude)"

OUT="$(HARNESS_DIR="$ROOT/hai-missing" CLAUDE_BIN="$ROOT/no-claude" PATH="$NO_CLAUDE_PATH" \
       bash "$SETUP" "$NPM" --ai 2>/dev/null)"
grep_ok "$OUT" "GATE_CMD='npm run lint && npm test'" "ai: missing claude falls back to deterministic output"
BAD_FAKE="$ROOT/bad-claude"
cat > "$BAD_FAKE" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'not json'
SH
chmod +x "$BAD_FAKE"
OUT="$(HARNESS_DIR="$ROOT/hai-bad" CLAUDE_BIN="$BAD_FAKE" bash "$SETUP" "$NPM" --ai 2>/dev/null)"
grep_ok "$OUT" "GATE_CMD='npm run lint && npm test'" "ai: invalid JSON falls back to deterministic output"

# --- --write refuses an unmanaged (hand-written) file ------------------------
echo "== --write refuses unmanaged file =="
HU="$ROOT/hu"; mkdir -p "$HU"
cat > "$HU/repos.local.sh" <<'SH'
repo_config_local() {
  local name="$2"
  case "$name" in
    handwritten|handwritten-*) BASE_BRANCH=main ;;
  esac
}
SH
before="$(cat "$HU/repos.local.sh")"
if HARNESS_DIR="$HU" bash "$SETUP" "$NPM" --write >/dev/null 2>&1; then
  bad "unmanaged: --write should exit non-zero"
else
  ok "unmanaged: --write exits non-zero"
fi
check "unmanaged: file left untouched" "$(cat "$HU/repos.local.sh")" "$before"

# --- --verify with no gate blocks --write ------------------------------------
echo "== --verify blocks --write when there is no gate =="
HV="$ROOT/hv"; mkdir -p "$HV"
cp "$SRC/repos.local.sh.example" "$HV/repos.local.sh"
before="$(cat "$HV/repos.local.sh")"
if HARNESS_DIR="$HV" bash "$SETUP" "$BARE" --verify --write >/dev/null 2>&1; then
  bad "verify: unverifiable proposal should not write"
else
  ok "verify: blocks write on failure"
fi
check "verify: file untouched on failed verify" "$(cat "$HV/repos.local.sh")" "$before"

# --- sanity: repos.conf.sh still sources with a written local file -----------
# repos.conf.sh sources repos.local.sh from its OWN directory, so colocate them
# (as install.sh does inside HARNESS_DIR) before sourcing.
echo "== repos.conf.sh integration =="
cp "$CONF" "$H/repos.conf.sh"
cp -R "$SRC/lib" "$H/lib"   # ...and the shared helpers it reads from beside itself
conf_check() {
  export HARNESS_DIR="$H"; GATE_CMD=""
  # shellcheck disable=SC1090
  . "$H/repos.conf.sh"
  repo_config "$NPM"
  [ "$GATE_CMD" = "npm run lint && npm test" ]
}
if ( conf_check ); then
  ok "conf: repo_config returns the pinned gate through repos.conf.sh"
else
  bad "conf: repo_config returns the pinned gate"
fi

echo
printf 'setup-repo smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
