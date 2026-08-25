# shellcheck shell=bash
# The dependency cache: skip the install when the lockfile already proved it.
#
# `npm ci` deletes node_modules and rebuilds it from the lockfile, every time,
# in every fresh worktree — 60–90 seconds per dispatch on this machine to
# reproduce a tree that is a pure function of the lockfile. This cache stores
# that function's output once per lockfile hash and clones it back on the next
# dispatch. On APFS the clone is copy-on-write (~6s for a 462MB node_modules,
# measured; near-zero disk until files diverge), so a warm dispatch pays
# seconds where it paid minutes.
#
# Sourced by run-task.sh and sync-pr.sh, never executed. Same rule as
# lib/common.sh: read from beside the caller, safe under `set -u`.
#
# What makes a skipped install SOUND rather than merely fast:
#
#   - The key is the lockfile's content plus the exact INSTALL_CMD plus the
#     Node major — any of the three changing is a miss. A hit therefore means
#     "this exact command already ran against this exact lockfile on this
#     runtime", and its node_modules is byte-equivalent to running it again.
#   - The cache only claims to reproduce the install itself, so it only skips
#     INSTALL_CMDs it can fully account for: the well-known pure installs
#     (deps_cache_covered's list). A compound pin ("npm ci && cd app &&
#     flutter pub get") is covered only when the repo also pins
#     DEPS_CACHE_POST_CMD — the part the cache does NOT reproduce, run on
#     every hit. Anything else falls through to a real install, untouched.
#   - Root-project lifecycle scripts (prepare and friends) do not re-run on a
#     hit. Their in-node_modules effects were captured when the cache was
#     stored; effects outside node_modules (husky writing .git/hooks) are
#     developer conveniences no gate reads. A repo where that assumption is
#     wrong should not pin a covered INSTALL_CMD — set DEPS_CACHE_POST_CMD or
#     export HARNESS_DEPS_CACHE=0.
#
# Only the Node ecosystem is cached: uv and poetry already install by
# hardlinking from their own global caches, so there is nothing to win there.
#
# Layout: $HARNESS_DIR/cache/deps/<repo>/<key>/node_modules, where <key> is
# "<sha256 prefix>-<lockfile name>". The entry directory itself is the
# concurrency lock: whoever mkdir()s it owns the store; a clone that dies
# midway removes the whole entry so a torn tree can never be restored. The
# entry's mtime is refreshed on every hit — that is the janitor's LRU signal.

# Where entries live. A function, not a variable set at source time: HARNESS_DIR
# may be exported after this file is sourced in tests.
deps_cache_root() { printf '%s/cache/deps' "$HARNESS_DIR"; }

# The root lockfile that keys the cache. One name, fixed order — the same
# precedence repos.conf.sh detects installs by. Prints nothing for a repo
# without one (Python, Go, ...), which disables the cache for that run.
deps_cache_lockfile() {  # $1 = worktree; prints the lockfile basename, or nothing
  local f
  for f in package-lock.json yarn.lock pnpm-lock.yaml; do
    [ -f "$1/$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# The cache key: lockfile content + the exact install command + the Node major.
# INSTALL_CMD is in the key so a changed pin never serves the old tree; the
# Node major is in it because native modules (swc, prisma engines) are built
# per-runtime. Prints nothing when the worktree has no lockfile.
deps_cache_key() {  # $1 = worktree, $2 = INSTALL_CMD; prints "<hash12>-<lockfile>"
  local lock hash node_major
  lock="$(deps_cache_lockfile "$1")" || return 1
  node_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  hash="$( { cat "$1/$lock"; printf '%s\n%s\n' "$2" "node${node_major:-unknown}"; } \
    | shasum -a 256 | cut -c1-12 )" || return 1
  [ -n "$hash" ] || return 1
  printf '%s-%s' "$hash" "$lock"
}

# Is INSTALL_CMD fully reproduced by restoring node_modules? True for the
# well-known pure installs, or for any command when the repo pins
# DEPS_CACHE_POST_CMD (the pin names the remainder, and the caller runs it on
# every hit). Whitespace is normalised; nothing else is interpreted.
deps_cache_covered() {  # $1 = INSTALL_CMD, $2 = DEPS_CACHE_POST_CMD
  [ -n "$2" ] && return 0
  local cmd
  cmd="$(printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -E 's/^ | $//g')"
  case "$cmd" in
    'npm ci'|'npm install'|'yarn install'|'yarn install --frozen-lockfile'|\
    'pnpm install'|'pnpm install --frozen-lockfile'|'npm ci --ignore-scripts'|\
    'npm install --ignore-scripts')
      return 0 ;;
  esac
  return 1
}

# Clone a directory tree, copy-on-write where the filesystem allows it. cp -c
# asks for clonefile(2); a filesystem that cannot clone (non-APFS, or a cache
# on another volume) fails the whole cp, so the plain copy is retried from a
# clean slate — still cheaper than a package manager resolving the tree.
_deps_cache_clone() {  # $1 = src dir, $2 = dst dir (must not exist)
  if ! cp -Rc "$1" "$2" 2>/dev/null; then
    rm -rf "$2"
    cp -R "$1" "$2" 2>/dev/null || { rm -rf "$2"; return 1; }
  fi
  return 0
}

# Restore a hit into the worktree. Any pre-existing node_modules is removed
# first — that is exactly what `npm ci` would have done, and a stale tree left
# beside a fresh lockfile is the bug this replaces, not one it may keep.
# Refreshes the entry's mtime so janitor.sh's LRU eviction sees the use.
deps_cache_restore() {  # $1 = repo name, $2 = key, $3 = worktree; 0 = restored
  local entry; entry="$(deps_cache_root)/$1/$2"
  [ -d "$entry/node_modules" ] || return 1
  rm -rf "${3:?}/node_modules"
  _deps_cache_clone "$entry/node_modules" "$3/node_modules" || return 1
  touch "$entry" 2>/dev/null || true
  return 0
}

# Store a fresh install. mkdir on the entry is the lock: losing the race to a
# parallel run of the same lockfile just means the tree is already being
# stored, and nothing needs doing. The clone lands under a tmp name and is
# renamed only when complete, so a reader never sees a torn node_modules; a
# failed clone removes the whole entry so the lock is not left owning nothing.
deps_cache_store() {  # $1 = repo name, $2 = key, $3 = worktree; always returns 0
  local entry; entry="$(deps_cache_root)/$1/$2"
  [ -d "$3/node_modules" ] || return 0
  mkdir -p "$(dirname "$entry")" 2>/dev/null || return 0
  mkdir "$entry" 2>/dev/null || return 0
  if _deps_cache_clone "$3/node_modules" "$entry/node_modules.tmp" \
     && mv "$entry/node_modules.tmp" "$entry/node_modules"; then
    return 0
  fi
  rm -rf "$entry"
  return 0
}

# Evict entries not used in N days. mtime is the use signal (restore touches
# it), so "stale" means "no dispatch wanted this lockfile lately" — usually a
# lockfile that changed and left its predecessor behind. Report mode lists,
# clean mode removes; the caller (janitor.sh) supplies the printer so the
# lines match its own ledger format.
#
# An entry with no node_modules is a store that died between taking the mkdir
# lock and finishing the clone (a SIGKILL leaves exactly this). It blocks its
# key forever — restore misses it, store loses the race to it — so it is
# evicted after a single day, not N: the only reason to wait at all is a store
# that is legitimately mid-clone right now.
deps_cache_prune() {  # $1 = report|clean, $2 = max age days, $3 = printer "line"-alike
  local root mode="$1" days="$2" printer="${3:-}" entry kb n_stale=0 n_kept=0 limit
  root="$(deps_cache_root)"
  [ -d "$root" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    limit="$days"
    [ -d "$entry/node_modules" ] || limit=1
    if [ -n "$(find "$entry" -maxdepth 0 -mtime +"$limit" 2>/dev/null)" ]; then
      n_stale=$((n_stale + 1))
      kb="$(du -sk "$entry" 2>/dev/null | cut -f1)"
      [ -n "$printer" ] && "$printer" "$mode" "$entry" "${kb:-0}"
      [ "$mode" = clean ] && rm -rf "$entry"
    else
      n_kept=$((n_kept + 1))
    fi
  done <<EOF
$(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
EOF
  # Repo dirs left empty by eviction go too; -mindepth spares the root itself.
  [ "$mode" = clean ] && find "$root" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
  # Outputs read by the caller (janitor.sh's summary line), invisible from here.
  # shellcheck disable=SC2034
  DEPS_CACHE_PRUNED="$n_stale"; DEPS_CACHE_KEPT="$n_kept"
  return 0
}
