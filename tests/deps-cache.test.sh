#!/usr/bin/env bash
# The dependency cache's contract: a hit restores exactly the tree the install
# produced, and everything that is not provably that tree is a miss. The key
# binds lockfile content, the exact INSTALL_CMD and the Node major; coverage
# admits only the pure installs the cache reproduces (or any command whose
# remainder is pinned as DEPS_CACHE_POST_CMD); a store that loses its race or
# dies midway leaves nothing a later restore could mistake for a tree; and the
# janitor's prune evicts by last use, where restoring IS a use.
#
# Everything runs against a fixture HARNESS_DIR and fixture worktrees — no
# network, no git, no real installs. `node` is faked on PATH so the key's
# runtime component is deterministic.
#
# Usage: bash tests/deps-cache.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deps-cache-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()  { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()  { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
yes() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$* (returned nonzero)"; fi; }
no()  { if "$@" >/dev/null 2>&1; then bad "$* (returned zero)"; else ok "$*"; fi; }

# A deterministic `node` so the key's runtime component cannot drift with the
# machine this suite runs on.
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\necho v20.0.0\n' > "$ROOT/bin/node"
chmod +x "$ROOT/bin/node"
PATH="$ROOT/bin:$PATH"

export HARNESS_DIR="$ROOT/harness"
mkdir -p "$HARNESS_DIR"
# shellcheck source=../lib/deps-cache.sh
. "$SRC/lib/deps-cache.sh"

wt() {  # $1 = name, $2 = lockfile body -> prints the worktree path
  local w="$ROOT/$1"
  mkdir -p "$w/node_modules/somepkg"
  printf '%s' "$2" > "$w/package-lock.json"
  printf 'installed-by-npm' > "$w/node_modules/somepkg/index.js"
  printf '%s' "$w"
}

echo "== the key: lockfile content, INSTALL_CMD and node, nothing else =="
W="$(wt w1 'lock-v1')"
K1="$(deps_cache_key "$W" 'npm ci')"
check "a worktree with a lockfile keys" "${K1:+keyed}" "keyed"
case "$K1" in
  *-package-lock.json) ok "the key names its lockfile" ;;
  *) bad "the key names its lockfile (got [$K1])" ;;
esac
K1b="$(deps_cache_key "$W" 'npm ci')"
check "the same inputs key identically" "$K1b" "$K1"
printf 'lock-v2' > "$W/package-lock.json"
K2="$(deps_cache_key "$W" 'npm ci')"
if [ "$K2" != "$K1" ]; then ok "a changed lockfile changes the key"; else bad "a changed lockfile changes the key"; fi
printf 'lock-v1' > "$W/package-lock.json"
K3="$(deps_cache_key "$W" 'npm install')"
if [ "$K3" != "$K1" ]; then ok "a changed INSTALL_CMD changes the key"; else bad "a changed INSTALL_CMD changes the key"; fi
NOLOCK="$ROOT/nolock"; mkdir -p "$NOLOCK"
no deps_cache_key "$NOLOCK" 'npm ci'

echo
echo "== coverage: only what a restored node_modules provably reproduces =="
yes deps_cache_covered 'npm ci' ''
yes deps_cache_covered '  npm   ci  ' ''
yes deps_cache_covered 'yarn install' ''
yes deps_cache_covered 'pnpm install --frozen-lockfile' ''
no  deps_cache_covered 'npm ci && (cd app && flutter pub get)' ''
yes deps_cache_covered 'npm ci && (cd app && flutter pub get)' 'cd app && flutter pub get'
no  deps_cache_covered 'uv sync' ''
no  deps_cache_covered 'make deps' ''

echo
echo "== store + restore: the roundtrip is the tree the install produced =="
no deps_cache_restore myrepo "$K1" "$W"          # cold cache: a miss, not a crash
deps_cache_store myrepo "$K1" "$W"
exists "the entry landed" "$HARNESS_DIR/cache/deps/myrepo/$K1/node_modules/somepkg/index.js"
absent "no tmp name survived the rename" "$HARNESS_DIR/cache/deps/myrepo/$K1/node_modules.tmp"
rm -rf "$W/node_modules"
mkdir -p "$W/node_modules"
printf 'stale' > "$W/node_modules/stale-marker"
yes deps_cache_restore myrepo "$K1" "$W"
check "the stored file is back" "$(cat "$W/node_modules/somepkg/index.js")" "installed-by-npm"
absent "the pre-existing tree was removed first, npm-ci-style" "$W/node_modules/stale-marker"

echo
echo "== the restored clone is independent of the cache copy =="
printf 'mutated-in-worktree' > "$W/node_modules/somepkg/index.js"
check "mutating the worktree leaves the cache untouched" \
  "$(cat "$HARNESS_DIR/cache/deps/myrepo/$K1/node_modules/somepkg/index.js")" "installed-by-npm"

echo
echo "== a lost race and a torn store leave nothing restorable =="
W2="$(wt w2 'lock-race')"
KR="$(deps_cache_key "$W2" 'npm ci')"
mkdir -p "$HARNESS_DIR/cache/deps/myrepo/$KR"       # someone else owns the entry
deps_cache_store myrepo "$KR" "$W2"
absent "losing the mkdir race stores nothing" "$HARNESS_DIR/cache/deps/myrepo/$KR/node_modules"
no deps_cache_restore myrepo "$KR" "$W2"            # entry without a tree is a miss
rm -rf "${W2:?}/node_modules"
deps_cache_store myrepo "$KR" "$W2"                  # nothing to store is a no-op
absent "storing a missing node_modules stores nothing" "$HARNESS_DIR/cache/deps/myrepo/$KR/node_modules"

echo
echo "== prune: eviction is by last use, and restoring is a use =="
# The raced empty entry from above is now a dead store: fresh, so it is KEPT
# today — but once older than a day it goes regardless of the N-day policy,
# because it blocks its key (restore misses it, store loses the race to it).
W3="$(wt w3 'lock-old')"
KO="$(deps_cache_key "$W3" 'npm ci')"
deps_cache_store oldrepo "$KO" "$W3"
touch -t 202601010000 "$HARNESS_DIR/cache/deps/oldrepo/$KO"
PRINTED="$ROOT/printed"; : > "$PRINTED"
fake_printer() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$PRINTED"; }
deps_cache_prune report 14 fake_printer
check "report counts the stale entry" "$DEPS_CACHE_PRUNED" "1"
check "report keeps the fresh entry and today's dead store" "$DEPS_CACHE_KEPT" "2"
exists "report evicts nothing" "$HARNESS_DIR/cache/deps/oldrepo/$KO/node_modules"
if grep -q "oldrepo/$KO" "$PRINTED"; then ok "the printer was told which entry"; else bad "the printer was told which entry"; fi
touch -t 202601010000 "$HARNESS_DIR/cache/deps/myrepo/$KR"   # age the dead store
touch -t 202601010000 "$HARNESS_DIR/cache/deps/myrepo/$K1"
yes deps_cache_restore myrepo "$K1" "$W"             # a restore refreshes mtime
deps_cache_prune clean 14 fake_printer
check "clean evicts the unused entry and the aged dead store" "$DEPS_CACHE_PRUNED" "2"
absent "the stale entry is gone" "$HARNESS_DIR/cache/deps/oldrepo/$KO"
absent "its emptied repo dir went with it" "$HARNESS_DIR/cache/deps/oldrepo"
absent "the aged dead store is gone" "$HARNESS_DIR/cache/deps/myrepo/$KR"
exists "the just-restored entry survived" "$HARNESS_DIR/cache/deps/myrepo/$K1/node_modules"

echo
echo "== the callers still parse =="
for f in run-task.sh sync-pr.sh janitor.sh repos.conf.sh setup-repo.sh lib/deps-cache.sh; do
  if bash -n "$SRC/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

echo
printf 'deps cache: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
