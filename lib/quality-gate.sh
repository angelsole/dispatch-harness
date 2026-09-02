#!/usr/bin/env bash
# The quality gate: deterministic static checks on the files a branch actually
# touches, meant to run as the FIRST element of GATE_CMD (pin QUALITY_GATE=1 in
# repos.local.sh) so a violation fails in seconds, before the repo's suite
# spends minutes proving the same tree.
#
# The bar, on changed files only — a legacy repo's whole backlog is not this
# run's problem, so the gate never judges files the branch did not touch:
#   - cyclomatic complexity per function  <= QG_MAX_COMPLEXITY  (default 21)
#   - lines of code per file              <= QG_MAX_FILE_LINES  (default 500;
#     blank lines and comments not counted)
#   - `any` types in TypeScript: none
#   - dead code (unused variables/imports, unreachable statements): none
#   - suppression comments ADDED by the branch (oxlint-disable, eslint-disable,
#     @ts-ignore, @ts-nocheck, noqa, type: ignore): none — a gate a worker can
#     comment its way past is not a gate
#
# JS/TS runs on oxlint (the repo's own binary when installed, an npx-pinned one
# otherwise); Python on ruff. A language whose tool cannot be found prints a
# `skip` line instead of failing: the gate never claims coverage it did not
# have, and never blocks a repo on a tool the machine lacks.
#
# Usage: quality-gate.sh [--base <ref>] [--all]
#   --base <ref>  diff against merge-base(<ref>, HEAD); a bare branch name is
#                 tried as origin/<ref> first, then locally. Default:
#                 origin/staging, origin/main or origin/master — first that
#                 exists.
#   --all         check every tracked file instead of the branch's diff
#
# Knobs (env): QG_MAX_COMPLEXITY  QG_MAX_FILE_LINES  QG_SUPPRESSIONS=0
#   QG_OXLINT_BIN  QG_RUFF_BIN  QG_OXLINT_VERSION
set -u

BASE=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?quality: --base needs a ref}"; shift 2 ;;
    --all)  ALL=1; shift ;;
    -h|--help)
      sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "quality: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "quality: not inside a git repository" >&2; exit 1; }
cd "$ROOT" || exit 1

MAXC="${QG_MAX_COMPLEXITY:-21}"
MAXL="${QG_MAX_FILE_LINES:-500}"

# --- Scope: which files this gate judges -------------------------------------
MB=""
if [ "$ALL" = 1 ]; then
  FILES=$(git ls-files)
  SCOPE="all tracked files"
else
  if [ -z "$BASE" ]; then
    for c in origin/staging origin/main origin/master staging main master; do
      if git rev-parse --verify -q "$c" >/dev/null; then BASE="$c"; break; fi
    done
  elif git rev-parse --verify -q "origin/$BASE" >/dev/null; then
    # origin first: the worktree was cut from origin/<base>, and a bare name
    # also resolves to the primary checkout's local branch, which is only as
    # fresh as the last time a human pulled it. Judged against a stale local
    # main, the branch owns every file the base moved since — and a legacy
    # file someone else grew past the ceiling fails a run that never touched it.
    BASE="origin/$BASE"
  fi
  git rev-parse --verify -q "$BASE" >/dev/null \
    || { echo "quality: base ref not found — pass --base <ref> or --all" >&2; exit 1; }
  MB=$(git merge-base "$BASE" HEAD) \
    || { echo "quality: no merge-base between $BASE and HEAD" >&2; exit 1; }
  # --diff-filter=d: a file the branch deleted has nothing left to judge.
  FILES=$(git diff --name-only --diff-filter=d "$MB" HEAD)
  SCOPE="changed vs $BASE"
fi

JS_FILES=(); PY_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case "$f" in
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.mts|*.cts) JS_FILES+=("$f") ;;
    *.py) PY_FILES+=("$f") ;;
  esac
done <<EOF
$FILES
EOF
echo "quality: $(( ${#JS_FILES[@]} + ${#PY_FILES[@]} )) code file(s) in scope ($SCOPE)"

status=0
okline()   { printf 'quality: %s — ok\n' "$1"; }
failline() { printf 'quality: %s — FAIL\n' "$1"; status=1; }
skipline() { printf 'quality: %s — skip (%s)\n' "$1" "$2"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/quality-gate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- Suppressions added by the branch ----------------------------------------
# Judged on the diff's ADDED lines only, so a pre-existing suppression in the
# repo never fails a branch that did not write it. Nothing to judge in --all
# mode, where there is no diff.
SUPPRESS_RE='oxlint-disable|eslint-disable|@ts-ignore|@ts-nocheck|#[[:space:]]*noqa|#[[:space:]]*type:[[:space:]]*ignore'
if [ "${QG_SUPPRESSIONS:-1}" = 1 ] && [ "$ALL" != 1 ] \
   && [ $(( ${#JS_FILES[@]} + ${#PY_FILES[@]} )) -gt 0 ]; then
  added=$(git diff -U0 "$MB" HEAD -- \
            ${JS_FILES[@]+"${JS_FILES[@]}"} ${PY_FILES[@]+"${PY_FILES[@]}"} \
          | grep -E '^\+' | grep -vE '^\+\+\+' | grep -E "$SUPPRESS_RE")
  if [ -n "$added" ]; then
    failline "suppressions (branch adds lint/type suppression comments — refactor instead)"
    printf '%s\n' "$added"
  else
    okline "suppressions (none added)"
  fi
fi

# --- JS/TS: oxlint ------------------------------------------------------------
# Explicit rules over an explicit config, default categories off: the gate
# enforces exactly its bar, not oxlint's opinions, and the repo's own lint
# setup (or lack of one) never changes the verdict.
if [ "${#JS_FILES[@]}" -gt 0 ]; then
  cat > "$TMP/oxlintrc.json" <<EOF
{
  "categories": { "correctness": "off" },
  "rules": {
    "complexity": ["error", $MAXC],
    "max-lines": ["error", { "max": $MAXL, "skipBlankLines": true, "skipComments": true }],
    "no-unused-vars": "error",
    "no-unreachable": "error",
    "typescript/no-explicit-any": "error"
  }
}
EOF
  OXLINT=()
  if [ -n "${QG_OXLINT_BIN:-}" ]; then
    # shellcheck disable=SC2206  # deliberate: the override may carry arguments
    OXLINT=($QG_OXLINT_BIN)
  elif [ -x node_modules/.bin/oxlint ]; then OXLINT=(node_modules/.bin/oxlint)
  elif command -v oxlint >/dev/null 2>&1; then OXLINT=(oxlint)
  elif command -v npx >/dev/null 2>&1; then
    # Pinned: a gate whose verdict changes the day a linter releases is not
    # deterministic.
    OXLINT=(npx --yes "oxlint@${QG_OXLINT_VERSION:-1.80.0}")
  fi
  label="js/ts static, ${#JS_FILES[@]} file(s) (complexity<=$MAXC, <=$MAXL lines/file, no any, no dead code)"
  if [ "${#OXLINT[@]}" -eq 0 ]; then
    skipline "$label" "no oxlint and no npx on PATH"
  elif out=$("${OXLINT[@]}" -c "$TMP/oxlintrc.json" "${JS_FILES[@]}" 2>&1); then
    okline "$label"
  else
    failline "$label"
    printf '%s\n' "$out"
  fi
else
  skipline "js/ts static" "no JS/TS files in scope"
fi

# --- Python: ruff -------------------------------------------------------------
if [ "${#PY_FILES[@]}" -gt 0 ]; then
  cat > "$TMP/ruff.toml" <<EOF
[lint]
select = ["C901", "F401", "F811", "F841"]

[lint.mccabe]
max-complexity = $MAXC
EOF
  RUFF=()
  if [ -n "${QG_RUFF_BIN:-}" ]; then
    # shellcheck disable=SC2206  # deliberate: the override may carry arguments
    RUFF=($QG_RUFF_BIN)
  elif [ -x .venv/bin/ruff ]; then RUFF=(.venv/bin/ruff)
  elif command -v ruff >/dev/null 2>&1; then RUFF=(ruff)
  elif command -v uvx >/dev/null 2>&1; then RUFF=(uvx ruff)
  fi
  label="python static, ${#PY_FILES[@]} file(s) (complexity<=$MAXC, no dead code)"
  if [ "${#RUFF[@]}" -eq 0 ]; then
    skipline "$label" "no ruff on PATH (and no uvx to fetch one)"
  elif out=$("${RUFF[@]}" check --no-cache --config "$TMP/ruff.toml" "${PY_FILES[@]}" 2>&1); then
    okline "$label"
  else
    failline "$label"
    printf '%s\n' "$out"
  fi
  # ruff has no file-length rule, so the LOC ceiling is counted here: lines
  # that are neither blank nor comment-only.
  over=""
  for f in "${PY_FILES[@]}"; do
    n=$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$f")
    [ "$n" -le "$MAXL" ] || over="$over
  $f: $n lines of code"
  done
  if [ -n "$over" ]; then
    failline "python file length (<=$MAXL lines/file)"
    printf '%s\n' "$over"
  else
    okline "python file length (<=$MAXL lines/file)"
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "quality: gate passed ($SCOPE)"
else
  echo "quality: gate FAILED ($SCOPE)"
fi
exit "$status"
