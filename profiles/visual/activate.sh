# shellcheck shell=bash
# Does the visual profile apply to this run's repo? $1 is the repo path.
#
# Two ways in, and a repo needs only one: a VISUAL_GATE_CMD pin in
# repos.local.sh, or the art-direction contract itself — a repo carrying
# .creative/ is a repo whose work is judged by eye, and having to pin a command
# as well was a step that only ever got forgotten.
#
# Sourced in a subshell, so nothing here can reach the run it is deciding about.
[ -n "${VISUAL_GATE_CMD:-}" ] || [ -d "${1:-}/.creative" ]
