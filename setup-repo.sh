#!/usr/bin/env bash
# setup-repo.sh — inspect a repo and propose (or write) a pinned pipeline entry.
#
# Onboarding a repo onto the harness means pinning a `repo_config_local()` case
# arm in your `repos.local.sh` (base branch, install + gate commands, MCP config,
# env subdirs, dev/demo server). This tool does that inspection for you:
#
#   1. Deterministic detection (default): reads package.json scripts,
#      pyproject.toml / uv.lock, .github/workflows, .env* layout, dev-server
#      port and .mcp.json to compose a complete, honest proposal. Never invents
#      commands — a field it can't determine is left for runtime auto-detection.
#   2. --ai       refine the proposal with one read-only `claude -p` call
#                 (model via SETUP_MODEL, default sonnet). Degrades to layer 1
#                 on any failure; works fine with `claude` absent.
#   3. --verify   prove the proposal in a throwaway worktree (INSTALL_CMD then
#                 GATE_CMD) before trusting it. A failing verify blocks --write.
#
# By default it prints the proposed entry + a one-line rationale per field and
# writes nothing. --write appends/updates the entry in your repos.local.sh
# (idempotently — re-running a repo updates its managed arm, never duplicates).
#
# IMPLEMENTER_PROVIDER is the one field never detected: it says which vendors
# may see a repo's code, so it is written only when you pass --provider, and an
# arm that already pins one keeps it through an update.
#
# Usage:
#   setup-repo.sh <repo-path> [--provider anthropic|zai] [--ai] [--verify] [--write]
#   setup-repo.sh -h | --help
#
# Env overrides:
#   HARNESS_DIR         where repos.local.sh lives   (default: ~/.claude/harness)
#   SETUP_MODEL         model for --ai               (default: sonnet; try opus)
#   CLAUDE_BIN          claude binary for --ai       (default: from PATH)
#   SETUP_AI_TIMEOUT    seconds cap on the --ai call (default: 180)
#   SETUP_VERIFY_TIMEOUT seconds cap on install+gate (default: 1200)
set -u

_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH

SETUP_MODEL="${SETUP_MODEL:-sonnet}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
SETUP_AI_TIMEOUT="${SETUP_AI_TIMEOUT:-180}"
SETUP_VERIFY_TIMEOUT="${SETUP_VERIFY_TIMEOUT:-1200}"

LOCAL_FILE="$HARNESS_DIR/repos.local.sh"

# Managed-block markers. setup-repo.sh only writes between these; a repos.local.sh
# lacking them is hand-written and never modified. Trimmed forms are what we
# match on (indentation-insensitive); indented forms are what the template ships.
MANAGED_BEGIN='# >>> setup-repo managed >>>'
MANAGED_END='# <<< setup-repo managed <<<'

# Fields we know how to pin. PREFLIGHT_CMD is deliberately absent from what we
# WRITE (auto-writing a preflight is out of scope — an untested path would break
# runs); it is accepted from --ai only so the model can suggest it as a hint.
# IMPLEMENTER_PROVIDER is absent from BOTH lists: --ai must not pick a vendor
# for a repo's code, and it reaches the arm only through --provider below.
KNOWN_FIELDS='BASE_BRANCH INSTALL_CMD GATE_CMD MCP_CONFIG ENV_SUBDIRS DEV_CMD DEMO_DEV_CMD DEMO_PORT PREFLIGHT_CMD'
KNOWN_PROVIDERS='anthropic zai'

usage() { harness_usage "$0"; }
warn()  { printf 'setup-repo: %s\n' "$*" >&2; }
die()   { warn "$*"; exit 1; }

# Resolve the directory of this script, following symlinks (it is installed into
# HARNESS_DIR as a symlink back to the source checkout, where the template lives).
self_dir() {
  local src="$0" dir
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" 2>/dev/null && pwd
}

# --- args --------------------------------------------------------------------
DO_AI=0; DO_VERIFY=0; DO_WRITE=0; REPO=""; PROVIDER_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ai)       DO_AI=1 ;;
    --verify)   DO_VERIFY=1 ;;
    --write)    DO_WRITE=1 ;;
    --provider) [ $# -ge 2 ] || { warn "--provider needs a value (one of: $KNOWN_PROVIDERS)"; exit 2; }
                PROVIDER_ARG="$2"; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         warn "unknown option: $1"; usage >&2; exit 2 ;;
    *)          [ -z "$REPO" ] || { warn "unexpected argument: $1"; exit 2; }
                REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || { usage >&2; exit 2; }

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || die "no such directory: $REPO"
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "$REPO is not a git repo"
NAME="$(basename "$REPO")"

case "$PROVIDER_ARG" in
  '') ;;
  anthropic|zai) ;;
  *) die "--provider: '$PROVIDER_ARG' is not a known provider (one of: $KNOWN_PROVIDERS)" ;;
esac

# --- field + rationale state -------------------------------------------------
# One F_<field> value var and one W_<field> rationale var per field. Initialised
# empty so `set -u` is safe even for fields we never touch.
F_BASE_BRANCH=""; F_INSTALL_CMD=""; F_GATE_CMD=""; F_MCP_CONFIG=""
F_ENV_SUBDIRS=""; F_DEV_CMD=""; F_DEMO_DEV_CMD=""; F_DEMO_PORT=""; F_PREFLIGHT_CMD=""
F_IMPLEMENTER_PROVIDER=""
W_BASE_BRANCH=""; W_INSTALL_CMD=""; W_GATE_CMD=""; W_MCP_CONFIG=""
W_ENV_SUBDIRS=""; W_DEV_CMD=""; W_DEMO_DEV_CMD=""; W_DEMO_PORT=""
W_IMPLEMENTER_PROVIDER=""
HANDWRITTEN_MATCH=0
HINTS=""

add_hint() { HINTS="${HINTS}  - $1"$'\n'; }

# --- layer 1: deterministic detection ---------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# package.json helpers (JS/TS repos). jq is a harness-wide dependency; if it is
# missing we fall back to lockfile-level defaults with a warning.
pkg_script() {  # $1 = script name -> prints its command line (empty if absent)
  jq -r --arg s "$1" '.scripts[$s] // empty' "$REPO/package.json" 2>/dev/null
}
has_pkg_script() { [ -n "$(pkg_script "$1")" ]; }

# Compose "run this script" for the detected package manager.
pm_run() {  # $1 = package manager, $2 = script name
  case "$1:$2" in
    npm:test)   echo "npm test" ;;
    npm:start)  echo "npm start" ;;
    npm:*)      echo "npm run $2" ;;
    *)          echo "$1 $2" ;;   # yarn/pnpm run any script by bare name
  esac
}

detect_base() {
  local origin_head base
  # The remote's declared default branch is the strongest signal.
  origin_head="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$origin_head" ]; then
    base="${origin_head#origin/}"
    F_BASE_BRANCH="$base"; W_BASE_BRANCH="origin/HEAD points at $base"; return
  fi
  # No origin/HEAD (never fetched, or no remote): fall back to ref existence,
  # matching the harness runtime order (staging > main > master).
  if   git -C "$REPO" show-ref --verify --quiet refs/remotes/origin/staging; then
    F_BASE_BRANCH=staging; W_BASE_BRANCH="origin/staging exists (no origin/HEAD)"
  elif git -C "$REPO" show-ref --verify --quiet refs/remotes/origin/main; then
    F_BASE_BRANCH=main; W_BASE_BRANCH="origin/main exists (no origin/HEAD)"
  elif git -C "$REPO" show-ref --verify --quiet refs/remotes/origin/master; then
    F_BASE_BRANCH=master; W_BASE_BRANCH="origin/master exists (no origin/HEAD)"
  else
    W_BASE_BRANCH="no remote branches found — runtime will default to master"
  fi
}

# Pull the first gate-ish command out of CI `run:` steps. Best-effort: CI is the
# ground truth for what "green" means, but parsing arbitrary YAML in bash is not
# reliable, so we only use it as a fallback GATE and always surface it as a hint.
detect_ci_gate() {
  local d="$REPO/.github/workflows" f line cmd
  [ -d "$d" ] || return
  for f in "$d"/*.yml "$d"/*.yaml; do
    [ -f "$f" ] || continue
    # Grep run: steps whose command mentions a recognisable gate tool.
    line="$(grep -hE '(^|[[:space:]])run:' "$f" 2>/dev/null \
      | grep -iE 'test|pytest|lint|ruff|type-?check|tsc|jest|vitest|mypy' \
      | head -1)"
    if [ -n "$line" ]; then
      # Strip everything up to and including "run:" and surrounding quotes.
      cmd="$(printf '%s' "$line" | sed -E 's/^.*run:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
      [ -n "$cmd" ] && { CI_GATE="$cmd"; return; }
    fi
  done
}

detect_js() {
  local pm="" install="" gate=""
  if   [ -f "$REPO/yarn.lock" ];         then pm=yarn;  install="yarn install"
  elif [ -f "$REPO/pnpm-lock.yaml" ];    then pm=pnpm;  install="pnpm install --frozen-lockfile"
  elif [ -f "$REPO/package-lock.json" ]; then pm=npm;   install="npm ci"
  else pm=npm; install="npm install"
  fi
  F_INSTALL_CMD="$install"
  W_INSTALL_CMD="lockfile → $install"

  if ! have jq; then
    warn "jq not found — cannot read package.json scripts; using lockfile default gate"
    F_GATE_CMD="$(pm_run "$pm" test)"; W_GATE_CMD="lockfile default (install jq for script-aware composition)"
    has_pkg_script dev && { F_DEV_CMD="$(pm_run "$pm" dev)"; W_DEV_CMD="scripts.dev"; }
    return
  fi

  # Compose the gate from whatever quality scripts exist, strictest first.
  local tc=""
  if   has_pkg_script type-check; then tc=type-check
  elif has_pkg_script typecheck;  then tc=typecheck
  fi
  _GATE=""
  [ -n "$tc" ]        && gate_add "$(pm_run "$pm" "$tc")"
  has_pkg_script lint && gate_add "$(pm_run "$pm" lint)"
  has_pkg_script test && gate_add "$(pm_run "$pm" test)"
  gate="$_GATE"

  if [ -n "$gate" ]; then
    F_GATE_CMD="$gate"; W_GATE_CMD="composed from package.json scripts (${gate})"
  elif [ -n "${CI_GATE:-}" ]; then
    F_GATE_CMD="$CI_GATE"; W_GATE_CMD="no gate scripts; taken from CI run: step"
  else
    W_GATE_CMD="no test/lint/type-check script and no CI gate found — left for runtime"
  fi

  has_pkg_script dev && { F_DEV_CMD="$(pm_run "$pm" dev)"; W_DEV_CMD="scripts.dev"; }
  detect_js_demo "$pm"
}

# Append a command to the gate accumulator with " && ". Pure bash so a command
# with internal spaces ("npm run type-check") joins correctly on bash 3.2.
_GATE=""
gate_add() {
  [ -n "$1" ] || return 0
  if [ -z "$_GATE" ]; then _GATE="$1"; else _GATE="$_GATE && $1"; fi
}

detect_js_demo() {  # $1 = package manager
  local pm="$1" dev port="" cmd=""
  dev="$(pkg_script dev)"
  # Explicit port flag in the dev script wins.
  port="$(printf '%s' "$dev" | sed -nE 's/.*(--port|-p)[= ]+([0-9]+).*/\2/p' | head -1)"
  if [ -z "$port" ]; then
    port="$(printf '%s' "$dev" | sed -nE 's/.*PORT[= ]+([0-9]+).*/\1/p' | head -1)"
  fi
  if compgen -G "$REPO/vite.config.*" >/dev/null 2>&1; then
    if [ -z "$port" ]; then
      port="$(grep -hEo 'port:[[:space:]]*[0-9]+' "$REPO"/vite.config.* 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
    fi
    [ -n "$port" ] || port=5173
    cmd="$(pm_run "$pm" dev) -- --port $port --strictPort"
    W_DEMO_DEV_CMD="vite dev server (strict port $port)"
  elif compgen -G "$REPO/next.config.*" >/dev/null 2>&1 || printf '%s' "$dev" | grep -q 'next'; then
    [ -n "$port" ] || port=3000
    cmd="$(pm_run "$pm" dev) -- -p $port"
    W_DEMO_DEV_CMD="next dev server (port $port)"
  elif [ -n "$port" ]; then
    cmd="$(pm_run "$pm" dev)"
    W_DEMO_DEV_CMD="dev script pins port $port"
  fi
  if [ -n "$cmd" ]; then
    F_DEMO_DEV_CMD="$cmd"; F_DEMO_PORT="$port"; W_DEMO_PORT="from dev-server config"
  else
    W_DEMO_DEV_CMD="no vite/next config or port flag found — set manually for demos"
  fi
}

detect_python() {
  local py="$REPO/pyproject.toml"
  if [ -f "$REPO/uv.lock" ]; then
    F_INSTALL_CMD="uv sync"; W_INSTALL_CMD="uv.lock → uv sync"
  elif [ -f "$REPO/poetry.lock" ]; then
    F_INSTALL_CMD="poetry install"; W_INSTALL_CMD="poetry.lock → poetry install"
  elif [ -f "$REPO/requirements.txt" ]; then
    F_INSTALL_CMD="pip install -r requirements.txt"; W_INSTALL_CMD="requirements.txt → pip install"
  fi

  local runner="" ruff="" pytest=""
  if [ -f "$REPO/uv.lock" ]; then runner="uv run "
  elif [ -f "$REPO/poetry.lock" ]; then runner="poetry run "
  fi
  # ruff / pytest presence: config table in pyproject or a dependency mention.
  if [ -f "$py" ]; then
    grep -qE 'tool\.ruff|(^|["[:space:]])ruff' "$py" 2>/dev/null && ruff=1
    grep -qE 'tool\.pytest|(^|["[:space:]])pytest' "$py" 2>/dev/null && pytest=1
  fi
  if [ -z "$pytest" ] && { [ -f "$REPO/pytest.ini" ] || [ -d "$REPO/tests" ]; }; then
    pytest=1
  fi

  _GATE=""
  [ -n "$ruff" ]   && gate_add "${runner}ruff check ."
  [ -n "$pytest" ] && gate_add "${runner}pytest"
  local gate; gate="$_GATE"
  if [ -n "$gate" ]; then
    F_GATE_CMD="$gate"; W_GATE_CMD="composed from pyproject (${gate})"
  elif [ -n "${CI_GATE:-}" ]; then
    F_GATE_CMD="$CI_GATE"; W_GATE_CMD="no ruff/pytest detected; taken from CI run: step"
  else
    W_GATE_CMD="no ruff/pytest detected and no CI gate — left for runtime"
  fi
}

detect_mcp() {
  if [ -f "$REPO/.mcp.json" ]; then
    F_MCP_CONFIG="$REPO/.mcp.json"; W_MCP_CONFIG=".mcp.json present in repo root"
  else
    W_MCP_CONFIG="no .mcp.json in repo root"
  fi
}

detect_env_subdirs() {
  local found="" rel dir
  # .env* files in the root and exactly one level down. Root ("." ) is always
  # copied by the harness, so it is never listed; we only surface extra subdirs.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    dir="$(dirname "$f")"
    rel="${dir#"$REPO"/}"
    [ "$dir" = "$REPO" ] && continue           # root: implicit
    case " $found " in *" $rel "*) ;; *) found="$found $rel" ;; esac
  done <<EOF
$(find "$REPO" -maxdepth 2 -type f -name '.env*' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
EOF
  found="$(printf '%s' "$found" | sed -E 's/^ +//; s/ +$//')"
  if [ -n "$found" ]; then
    F_ENV_SUBDIRS="$found"; W_ENV_SUBDIRS=".env* found under: $found"
  else
    W_ENV_SUBDIRS="no .env* outside the repo root"
  fi
}

detect_preflight_hint() {
  local f svc
  for f in "$REPO"/docker-compose.yml "$REPO"/docker-compose.yaml \
           "$REPO"/compose.yml "$REPO"/compose.yaml; do
    [ -f "$f" ] || continue
    svc="$(grep -ioE 'postgres|mysql|mariadb|mongo|redis' "$f" 2>/dev/null | head -1)"
    if [ -n "$svc" ]; then
      add_hint "docker-compose defines a '$svc' service — the gate may need a running/migrated DB. Consider a PREFLIGHT_CMD (see examples/preflight-postgres.example.sh)."
      return
    fi
  done
}

detect_all() {
  CI_GATE=""
  detect_base
  detect_ci_gate
  if [ -f "$REPO/package.json" ]; then
    detect_js
  elif [ -f "$REPO/pyproject.toml" ] || [ -f "$REPO/uv.lock" ] \
       || [ -f "$REPO/requirements.txt" ]; then
    detect_python
  else
    W_INSTALL_CMD="no known lockfile/manifest — could not detect an install command"
    if [ -n "${CI_GATE:-}" ]; then
      F_GATE_CMD="$CI_GATE"; W_GATE_CMD="unknown stack; taken from CI run: step"
    else
      W_GATE_CMD="unknown stack and no CI gate — could not detect a gate command"
    fi
  fi
  detect_mcp
  detect_env_subdirs
  detect_preflight_hint
  [ -n "${CI_GATE:-}" ] && add_hint "CI runs: ${CI_GATE} — make sure GATE_CMD matches what CI enforces."
}

# --- layer 2: --ai refinement ------------------------------------------------
ai_settings_file() {
  # Prefer the shipped, reviewable settings file; otherwise synthesise an
  # equivalent read-only one in a temp file so --ai still works from a bare copy.
  local shipped; shipped="$(self_dir)/setup-ai-settings.json"
  if [ -f "$shipped" ]; then printf '%s' "$shipped"; return; fi
  shipped="$HARNESS_DIR/setup-ai-settings.json"
  if [ -f "$shipped" ]; then printf '%s' "$shipped"; return; fi
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/setup-ai-settings.XXXXXX")" || return 1
  AI_TMP_SETTINGS="$tmp"
  cat > "$tmp" <<'JSON'
{
  "permissions": {
    "allow": ["Read", "Glob", "Grep"],
    "deny": ["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash", "WebFetch", "WebSearch"]
  }
}
JSON
  printf '%s' "$tmp"
}

run_ai() {
  if [ ! -x "$CLAUDE_BIN" ]; then
    if have claude; then CLAUDE_BIN=claude
    else warn "--ai: claude binary not found ($CLAUDE_BIN) — keeping deterministic proposal"; return; fi
  fi
  local settings; settings="$(ai_settings_file)" || { warn "--ai: could not stage settings — skipping"; return; }

  local prompt
  prompt="You are configuring a CI-style test pipeline for the git repo at the current working directory.
Inspect it read-only and output ONLY a single JSON object (no prose, no markdown fences) with any of these keys you can determine confidently:
  BASE_BRANCH   base branch PRs target (the remote's default branch)
  INSTALL_CMD   command to install deps in a fresh clone
  GATE_CMD      the strictest fast gate: type-check/lint/tests, '&&'-joined
  MCP_CONFIG    absolute path to an .mcp.json if one exists
  ENV_SUBDIRS   space-separated subdirs (besides '.') that hold .env* files
  DEV_CMD       dev server command
  DEMO_DEV_CMD  dev server command with an explicit fixed port
  DEMO_PORT     the numeric port DEMO_DEV_CMD binds
  PREFLIGHT_CMD only if a service (e.g. a DB) must be up before tests
Omit any key you cannot determine — never guess a command. Values must be plain strings (DEMO_PORT a number)."

  # Run the call from inside the repo so the model inspects the target tree.
  # The settings path is absolute, so it survives the cd.
  local raw json
  raw="$(cd "$REPO" && with_timeout "$SETUP_AI_TIMEOUT" env -u ANTHROPIC_API_KEY "$CLAUDE_BIN" \
          -p "$prompt" --settings "$settings" --model "$SETUP_MODEL" \
          --output-format json --max-turns 30 </dev/null 2>/dev/null)" || {
    warn "--ai: claude call failed or timed out — keeping deterministic proposal"; return; }

  # Unwrap the CLI envelope, then strip any stray code fence the model added.
  json="$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)"
  json="$(printf '%s' "$json" | sed -E 's/^```[a-zA-Z]*//; s/```$//' | sed '/^[[:space:]]*$/d')"
  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e 'type=="object"' >/dev/null 2>&1; then
    warn "--ai: response was not a JSON object — keeping deterministic proposal"; return
  fi

  # Reject unknown keys wholesale rather than silently trusting a mangled reply.
  local bad
  bad="$(printf '%s' "$json" | jq -r 'keys[]' 2>/dev/null \
        | grep -vxE "$(printf '%s' "$KNOWN_FIELDS" | tr ' ' '|')" || true)"
  if [ -n "$bad" ]; then
    warn "--ai: response had unknown keys ($(printf '%s' "$bad" | tr '\n' ' ')) — keeping deterministic proposal"; return
  fi

  local f v
  for f in $KNOWN_FIELDS; do
    v="$(printf '%s' "$json" | jq -r --arg k "$f" '.[$k] // empty' 2>/dev/null)"
    [ -n "$v" ] || continue
    if [ "$f" = DEMO_PORT ] && ! printf '%s' "$v" | grep -qE '^[0-9]+$'; then
      warn "--ai: ignoring non-numeric DEMO_PORT '$v'"; continue
    fi
    # printf -v (not eval) — the value is model output and may contain shell
    # metacharacters; assign it to the F_<field> var without interpreting it.
    printf -v "F_$f" '%s' "$v"
    printf -v "W_$f" '%s' "proposed by --ai ($SETUP_MODEL)"
  done
}

# --- layer 3: --verify -------------------------------------------------------
VERIFY_WT=""
AI_TMP_SETTINGS=""
cleanup() {
  [ -n "$AI_TMP_SETTINGS" ] && { rm -f "$AI_TMP_SETTINGS" 2>/dev/null || true; AI_TMP_SETTINGS=""; }
  [ -n "$VERIFY_WT" ] || return 0
  git -C "$REPO" worktree remove --force "$VERIFY_WT" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$VERIFY_WT")" >/dev/null 2>&1 || true
  VERIFY_WT=""
}
trap 'cleanup' EXIT INT TERM

verify_proposal() {  # returns 0 on pass, non-zero on fail
  if [ -z "$F_GATE_CMD" ]; then
    warn "--verify: no GATE_CMD to run — cannot prove this repo; refusing to trust it"
    return 1
  fi
  local base tmp log
  base="$(mktemp -d "${TMPDIR:-/tmp}/setup-verify.XXXXXX")" || { warn "--verify: mktemp failed"; return 1; }
  VERIFY_WT="$base/wt"
  log="$base/verify.log"
  printf 'verifying proposal in a throwaway worktree (%s)...\n' "$VERIFY_WT" >&2
  if ! git -C "$REPO" worktree add --detach "$VERIFY_WT" HEAD >/dev/null 2>&1; then
    warn "--verify: could not create a worktree"; return 1
  fi

  if [ -n "$F_INSTALL_CMD" ]; then
    printf '  install: %s\n' "$F_INSTALL_CMD" >&2
    if ! (cd "$VERIFY_WT" && with_timeout "$SETUP_VERIFY_TIMEOUT" bash -c "$F_INSTALL_CMD") >"$log" 2>&1; then
      warn "--verify: INSTALL_CMD failed. Last lines:"; tail -30 "$log" >&2; return 1
    fi
  fi
  printf '  gate:    %s\n' "$F_GATE_CMD" >&2
  if ! (cd "$VERIFY_WT" && with_timeout "$SETUP_VERIFY_TIMEOUT" bash -c "$F_GATE_CMD") >>"$log" 2>&1; then
    warn "--verify: GATE_CMD failed. Last lines:"; tail -30 "$log" >&2; return 1
  fi
  printf 'verify: PASS\n' >&2
  return 0
}

# --- rendering ---------------------------------------------------------------
# Build the paste-ready case arm (only non-empty fields; PREFLIGHT is never
# written — it is a hint only).
shell_quote() {  # $1 = value -> single-quoted shell literal
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

render_assignment() {  # $1 = variable name, $2 = value
  printf '      %s=' "$1"
  shell_quote "$2"
  printf '\n'
}

build_arm() {
  printf '    # repo:%s\n' "$NAME"
  printf '    '; shell_quote "$NAME"; printf '|'; shell_quote "$NAME"; printf '%s\n' '-*)'
  [ -n "$F_BASE_BRANCH" ]  && render_assignment BASE_BRANCH "$F_BASE_BRANCH"
  [ -n "$F_INSTALL_CMD" ]  && render_assignment INSTALL_CMD "$F_INSTALL_CMD"
  [ -n "$F_GATE_CMD" ]     && render_assignment GATE_CMD "$F_GATE_CMD"
  [ -n "$F_IMPLEMENTER_PROVIDER" ] && render_assignment IMPLEMENTER_PROVIDER "$F_IMPLEMENTER_PROVIDER"
  [ -n "$F_MCP_CONFIG" ]   && render_assignment MCP_CONFIG "$F_MCP_CONFIG"
  [ -n "$F_ENV_SUBDIRS" ]  && render_assignment ENV_SUBDIRS "$F_ENV_SUBDIRS"
  [ -n "$F_DEV_CMD" ]      && render_assignment DEV_CMD "$F_DEV_CMD"
  [ -n "$F_DEMO_DEV_CMD" ] && render_assignment DEMO_DEV_CMD "$F_DEMO_DEV_CMD"
  [ -n "$F_DEMO_PORT" ]    && printf '      DEMO_PORT=%s\n' "$F_DEMO_PORT"
  printf '      ;;\n'
  printf '    # end:%s\n' "$NAME"
}

rationale_line() {  # $1 = label, $2 = value, $3 = why
  local why="$3"; [ -n "$why" ] || why="not detected"
  if [ -n "$2" ]; then
    printf '  %-13s %-40s # %s\n' "$1" "$2" "$why"
  else
    printf '  %-13s %-40s # %s\n' "$1" "(could not detect)" "$why"
  fi
}

print_proposal() {
  printf '\n# Proposed repo_config_local entry for "%s":\n\n' "$NAME"
  build_arm
  printf '\n# Rationale:\n'
  rationale_line BASE_BRANCH   "$F_BASE_BRANCH"  "$W_BASE_BRANCH"
  rationale_line INSTALL_CMD   "$F_INSTALL_CMD"  "$W_INSTALL_CMD"
  rationale_line GATE_CMD      "$F_GATE_CMD"     "$W_GATE_CMD"
  [ -n "$F_IMPLEMENTER_PROVIDER" ] \
    && rationale_line IMPLEMENTER_PROVIDER "$F_IMPLEMENTER_PROVIDER" "$W_IMPLEMENTER_PROVIDER"
  rationale_line MCP_CONFIG    "$F_MCP_CONFIG"   "$W_MCP_CONFIG"
  rationale_line ENV_SUBDIRS   "$F_ENV_SUBDIRS"  "$W_ENV_SUBDIRS"
  rationale_line DEV_CMD       "$F_DEV_CMD"      "$W_DEV_CMD"
  rationale_line DEMO_DEV_CMD  "$F_DEMO_DEV_CMD" "$W_DEMO_DEV_CMD"
  rationale_line DEMO_PORT     "$F_DEMO_PORT"    "$W_DEMO_PORT"
  if [ -n "$HINTS" ]; then
    printf '\n# Hints:\n%s' "$HINTS"
  fi
}

# --- write -------------------------------------------------------------------
file_is_managed() {  # $1 = file
  grep -qF -- "$MANAGED_BEGIN" "$1" 2>/dev/null &&
  grep -qF -- "$MANAGED_END" "$1" 2>/dev/null
}

arm_exists() {  # $1 = file — is there a "# repo:NAME" marker already?
  awk -v m="# repo:$NAME" '
    { t=$0; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t)
      if (t==m) { found=1; exit } }
    END { exit(found?0:1) }' "$1"
}

write_entry() {
  # Seed a fresh managed file from the template if none exists yet.
  if [ ! -f "$LOCAL_FILE" ]; then
    local tmpl; tmpl="$(self_dir)/repos.local.sh.example"
    if [ -f "$tmpl" ]; then
      mkdir -p "$HARNESS_DIR"
      cp "$tmpl" "$LOCAL_FILE"
      printf 'created %s from the managed template\n' "$LOCAL_FILE" >&2
    else
      warn "no $LOCAL_FILE and no template to seed it from — paste the block above into a repos.local.sh"
      return 3
    fi
  fi

  if ! file_is_managed "$LOCAL_FILE"; then
    warn "$LOCAL_FILE is hand-written (no managed markers) — refusing to modify it."
    warn "Paste the block above into its repo_config_local() case, or adopt the"
    warn "managed structure from repos.local.sh.example to enable --write."
    return 3
  fi

  if [ "$HANDWRITTEN_MATCH" = 1 ]; then
    warn "$LOCAL_FILE already has a hand-written arm that configures \"$NAME\"."
    warn "Refusing to insert an earlier managed arm that would shadow it; edit the hand-written arm directly."
    return 3
  fi

  local armfile tmp
  armfile="$(mktemp "${TMPDIR:-/tmp}/setup-arm.XXXXXX")" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/setup-local.XXXXXX")" || { rm -f "$armfile"; return 1; }
  build_arm > "$armfile"

  local action
  if arm_exists "$LOCAL_FILE"; then
    action="updated"
    awk -v repom="# repo:$NAME" -v endm="# end:$NAME" -v armfile="$armfile" '
      function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
      { t=trim($0) }
      (!inblk && t==repom) { inblk=1
        while ((getline line < armfile) > 0) print line; close(armfile); next }
      (inblk && t==endm) { inblk=0; next }
      inblk { next }
      { print }' "$LOCAL_FILE" > "$tmp"
  else
    action="inserted"
    awk -v endm="$MANAGED_END" -v armfile="$armfile" '
      function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
      { t=trim($0) }
      (!done && t==endm) { while ((getline line < armfile) > 0) print line; close(armfile); done=1 }
      { print }' "$LOCAL_FILE" > "$tmp"
  fi

  # Never leave a broken config: only replace if the result still parses.
  if ! bash -n "$tmp" 2>/dev/null; then
    warn "internal error: generated repos.local.sh does not parse — not written"
    rm -f "$armfile" "$tmp"; return 1
  fi
  cp "$tmp" "$LOCAL_FILE"
  rm -f "$armfile" "$tmp"
  printf '%s the "%s" entry in %s\n' "$action" "$NAME" "$LOCAL_FILE" >&2
  return 0
}

# --- main --------------------------------------------------------------------
detect_all
[ "$DO_AI" = 1 ] && run_ai
# Ask the file's own hook whether it already configures this repo. A matching
# hand-written arm must never be shadowed by a newly inserted managed arm: it
# may carry custom or dynamic behavior that setup-repo cannot safely reproduce.
# The hook's provider is also retained when refreshing an existing managed arm.
EXISTING_IMPLEMENTER_PROVIDER=""
if [ -f "$LOCAL_FILE" ]; then
  EXISTING_IMPLEMENTER_PROVIDER="$(
    (
      # shellcheck disable=SC1090
      . "$LOCAL_FILE" >/dev/null 2>&1 || exit 1
      # Match repo_config's initialized-output contract before invoking the
      # user's hook; hand-written arms may safely read any field under set -u.
      # shellcheck disable=SC2034
      {
        BASE_BRANCH=""; INSTALL_CMD=""; GATE_CMD=""; VISUAL_GATE_CMD=""; MCP_CONFIG=""
        VISUAL_SCOPE_GLOBS=""; IMPLEMENTER_PROVIDER=""; IMPLEMENTER_MODEL=""
        ENV_SUBDIRS=""; DEV_CMD=""; PREFLIGHT_CMD=""; DEMO_DEV_CMD=""; DEMO_PORT=""; PREPROD=""
      }
      command -v repo_config_local >/dev/null 2>&1 || exit 1
      repo_config_local "$REPO" "$NAME" >/dev/null 2>&1
      printf '%s' "${IMPLEMENTER_PROVIDER:-}"

      [ -n "$BASE_BRANCH" ] || [ -n "$INSTALL_CMD" ] || [ -n "$GATE_CMD" ] ||
        [ -n "$VISUAL_GATE_CMD" ] || [ -n "$VISUAL_SCOPE_GLOBS" ] ||
        [ -n "$MCP_CONFIG" ] || [ -n "$ENV_SUBDIRS" ] || [ -n "$DEV_CMD" ] ||
        [ -n "$PREFLIGHT_CMD" ] || [ -n "$DEMO_DEV_CMD" ] || [ -n "$DEMO_PORT" ] ||
        [ -n "$PREPROD" ] || [ -n "$IMPLEMENTER_PROVIDER" ] || [ -n "$IMPLEMENTER_MODEL" ]
    )
  )"
  existing_config_status=$?
  if [ "$existing_config_status" = 0 ] && ! arm_exists "$LOCAL_FILE"; then
    HANDWRITTEN_MATCH=1
  fi
fi

F_IMPLEMENTER_PROVIDER="$PROVIDER_ARG"
[ -z "$PROVIDER_ARG" ] || W_IMPLEMENTER_PROVIDER="from --provider"
if [ -z "$F_IMPLEMENTER_PROVIDER" ] && [ -n "$EXISTING_IMPLEMENTER_PROVIDER" ]; then
  F_IMPLEMENTER_PROVIDER="$EXISTING_IMPLEMENTER_PROVIDER"
  W_IMPLEMENTER_PROVIDER="kept from the existing pin"
fi

# PREFLIGHT_CMD is never auto-written (an untested path would break runs); if the
# model suggested one, surface it as a hint the user can act on deliberately.
[ -n "$F_PREFLIGHT_CMD" ] && add_hint "PREFLIGHT_CMD suggested by --ai: $F_PREFLIGHT_CMD (not auto-written — add it yourself if the run needs it)."

verify_ok=1
if [ "$DO_VERIFY" = 1 ]; then
  if verify_proposal; then verify_ok=1; else verify_ok=0; fi
fi

print_proposal

if [ "$DO_WRITE" = 1 ]; then
  if [ "$DO_VERIFY" = 1 ] && [ "$verify_ok" != 1 ]; then
    warn "verify failed — not writing. Fix the repo/proposal and re-run."
    exit 1
  fi
  write_entry; rc=$?
  exit "$rc"
fi

# Dry run: tell the user how to persist it.
printf '\n# Dry run — nothing written. Re-run with --write to save into %s\n' "$LOCAL_FILE" >&2
[ "$DO_VERIFY" = 1 ] && [ "$verify_ok" != 1 ] && exit 1
exit 0
