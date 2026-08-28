# Development

Working on the harness itself: its own gate, its suites, and the docs-as-tests
pass that keeps this documentation honest.

## The gate

This repo's own test gate is [`gate.sh`](../gate.sh): `bash -n` and
`shellcheck -x -S warning` over every shipped script, then every suite in
`tests/*.test.sh`. Run it before committing, or run one suite standalone — they
are self-contained bash: no framework, no network, no writes outside a temp
sandbox. CI runs the same gate on Linux for every push and pull request.

```bash
bash gate.sh
bash tests/docs.test.sh
```

The gate lints first and, if lint fails, stops there: a shellcheck warning is a
ten-second fix, and re-running the suites to learn about one once cost an
afternoon. `GATE_ALWAYS_ALL=1` runs the suites regardless. The suites then run
`GATE_JOBS` at a time (default: the machine's core count; `GATE_JOBS=1` is the
old serial gate) — every suite isolates itself in its own temp root, `HOME` and
`HARNESS_DIR`, with dynamic ports, so nothing about them needs the order. The
output is unchanged: one line per suite in filename order, a failing suite's
transcript right under its line, `  skip ` lines kept. Two things the gate sets
for every suite: `HARNESS_DETACH=0`, so a fixture `run-task.sh` stays in the
foreground where the suite can assert on it, and `HARNESS_PREFLIGHT=off`, so a
fixture run does not spend seconds asking `npx ccusage` about a config dir that
has no logs — the four suites whose fixtures need it switch it back on.

`tests/docs.test.sh` is the docs-as-tests suite: [README's
Prerequisites](../README.md#prerequisites) name every binary the scripts need,
`install.sh`'s file list matches the repo, every knob `run-task.sh` honors is
documented in the README or under `docs/`, every docs page is reachable from
the README and every internal anchor resolves, and no script, link or promise
named in any of them has stopped existing.
