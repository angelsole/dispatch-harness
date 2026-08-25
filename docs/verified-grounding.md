# Trust me, said the reviewer. Show me, said the harness

*2026-08-25*

An agentic code review is only as good as the disagreements inside it. This is
a note about one small mechanism — making a refutation cite code the harness can
check — and about how it was attacked by the process it was built to improve.

## Half of what a review says is wrong

This pipeline reviews every branch it builds, in three passes rather than one.
A **find** pass reads the diff and writes a list of findings — `{file, line,
claim, scenario}` apiece — and changes nothing. A **refute** pass, a fresh
session that has not seen the diff, reads that list and tries to establish that
each entry is *wrong*. A **fix** pass edits only for the findings that survived,
one commit per finding. The full contract is in
[Find, refute, fix](reference.md#find-refute-fix); this page is the argument
behind it.

The split exists because of a number: roughly one review finding in two does not
survive checking. A reviewer that finds and fixes in the same breath turns every
one of those false positives into an edit to code that already passed the test
gate. So a finding has to earn its edit.

Which raises the question the split does not answer by itself: what does a
*refutation* have to earn?

## What the paper found

"Adversarial Review: Structured Disagreement for Grounded Agentic Code Review"
(Qiu & Gill, arXiv:2608.18167) makes the case for the small adversarial shape
over the big committee. A reviewer+critic pair beat a five-agent review system
on LiveCodeBench — 87% pass rate against 82%, three agents against five. Fewer
agents, better code.

Then the same pair scored **worst of the four methods** they compared on review
quality: F1 0.457 on SWE-PRBench. The diagnosis is the interesting part. Agents
that talk to each other optimize for agreement. Their Case A is a critic
confirming the reviewer's hedged noise, because confirming is the cooperative
move. Their Case B is worse: the critic raises a real bug, the reviewer rebuts
with confident prose citing no code at all, and the critic capitulates.
Confidence beat evidence, and the critic let the defect stand.

Their fix is at the prompt level — typed disagreement. A critic must answer
`AGREE`, `DISAGREE_EVIDENCE` with a code citation, or `DISAGREE_CONCERN` for
suspicion it cannot ground. Typing the disagreement lifts F1 to 0.533, the best
of the four.

## Requested is not verified

Read `DISAGREE_EVIDENCE` closely and the gap is right there. The citation is
*requested*. Nothing goes and looks.

That is an honor system, and it is exactly the wrong population to run one on.
The model that most needs stopping is the model that is wrong with confidence —
and that is precisely the model that will produce a fluent, well-formatted
citation to a line that says nothing of the kind. Typed disagreement changes
what a cooperative critic emits. It does not change what a mistaken one can get
away with.

The harness owns the worktree. It can go and look.

## What a refutation costs here

A verdict that says `refuted: true` must carry `evidence: {file, excerpt}`, and
the harness checks that citation mechanically before the verdict counts for
anything:

- **The file is a git-tracked path in the worktree.** Absolute paths are
  rejected, so are paths through `..`, and so is anything under `.harness/` —
  a refuter may not cite the orchestration metadata it was handed as if it were
  reviewed code. A tracked *symlink* is rejected outright on its index mode: the
  bytes behind a link need not belong to this checkout, so the harness never
  follows one, wherever it points.
- **The excerpt is at least ten non-whitespace characters of code**, counted as
  characters rather than bytes.
- **The excerpt is a contiguous verbatim slice of that file.** The whole file is
  compared at once, byte-exactly through a hex encoding, because a per-line
  match would happily accept an excerpt stitched together from lines that never
  touch.

A verdict that fails any of those is **discarded**, and the finding it tried to
kill is promoted anyway. The discard is not silent: it lands in
`refute-discarded.json` and as a line in the review ledger naming what was
thrown away and why, so the run's own paper trail shows the attempt. The
asymmetry is deliberate and holds everywhere in this stage — a wrong promotion
costs one unnecessary edit, a wrong refutation ships a defect, so every
degradation falls toward promotion and never toward a quiet drop.

Two structural points sit alongside the check. The refuter runs as an
independent session whose only output is a JSON file; there is no conversational
channel back to the finder. Case-B capitulation is not discouraged by prompt
here, it has nowhere to happen. And doubt gets its own verdict rather than being
squeezed into a refutation: `doubt: true` promotes the finding marked `doubted`,
and the fix pass is then required to confirm that scenario against the code
before it edits anything for it. That is the paper's Case A, addressed at the
edit boundary instead of the conversation.

## Four ways to lie to the checker

The pipeline built this feature about itself. While it did, its own review —
still binary at the time, since the new rules were the thing under construction
— found four real ways to get a fabricated citation past the validator. Each was
fixed in its own commit:

- **[F1]** a `./`-prefixed path slipping past the `.harness/` rejection, because
  git accepts the spelling and the policy check did not normalize it;
- **[F2]** a tracked symlink pointing outside the worktree, so text that was
  never in the repository could verify a refutation;
- **[F3]** bash command substitution silently stripping NUL bytes out of the
  file it was reading, so an excerpt spanning a NUL looked contiguous when it
  was not;
- **[F4]** the ten-character minimum measured in encoded bytes, so five emoji
  cleared a bar meant to require ten characters of code.

Adversarial inputs to an adversarial-input validator, caught by the adversarial
process they were about to upgrade. Every one of them is now a fixture in the
suite.

## What gets counted

None of the above is worth much as a story if the rates are guesswork, so every
run writes `review_findings: {found, refuted, promoted, doubted, fixed,
refute}` into its `result.json`
([schema](reference.md#metrics-schema)). The false-alarm rate and the doubt rate
are measured per branch rather than estimated, and `refute` records whether the
refutation pass ran at all — on anything but `ok`, every finding was promoted
unchecked, and the ledger says so in words.

## What this is not

This is an architectural argument, not a benchmark result.

The harness has not been measured against the paper's protocol on SWE-PRBench or
on any public benchmark. "Case-B capitulation cannot occur by design" is a claim
about one failure mode and its structural cause; it is not a claim that this
review is better than a benchmarked one, and a review can be worse in a hundred
ways that have nothing to do with capitulation. The rules above also buy their
guarantee with a cost: a correct refutation whose author quotes carelessly is
discarded, and the pipeline pays for that in an unnecessary edit.

Measuring binary against evidence-verified refutation on a public benchmark is
work that has not been done here. There is a
[design for a paired comparison](design-notes.md#the-public-benchmark-experiment)
on SWE-bench Verified that this would fit into.

## About this post

This page was written, gate-checked and adversarially reviewed by the pipeline
it describes, under the contract it explains. The find pass read it cold; the
refutation pass got the same deal as any other — anything it wanted to drop, it
had to quote out of a git-tracked file in this repository, verbatim and
contiguous, and the harness went and checked.
