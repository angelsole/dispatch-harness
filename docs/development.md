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

`tests/docs.test.sh` is the docs-as-tests suite: [README's
Prerequisites](../README.md#prerequisites) name every binary the scripts need,
`install.sh`'s file list matches the repo, every knob `run-task.sh` honors is
documented in the README or under `docs/`, every docs page is reachable from
the README and every internal anchor resolves, and no script, link or promise
named in any of them has stopped existing.
