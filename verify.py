"""Score a finished run against a fixed rubric with a third-vendor verifier.

The harness records plenty about how a run BEHAVED — turns, tokens, gate rounds,
commit counts, +/- lines — and nothing about how well it satisfied its brief.
This adapter turns the artefacts a run already leaves on disk into evidence a
judge can read — the ordered trajectory (each action WITH its observed output)
and the complete diff — and scores it.

WHY A RUBRIC AND NOT ONE NUMBER. A single-pass scalar over a long agentic
trajectory is close to uninterpretable, and the judge literature says why:
judges are noisy on long agentic-coding outputs and per-item scoring beats
batched (2606.29920); self-preference bias is real and capability-independent,
and structured multi-dimensional decomposition cuts it by ~31.5% (2604.22891) —
and our trajectories NAME the models, which is an open invitation; judges carry
verbosity/length bias (2510.24367), so a raw trajectory score rewards exactly
the bloat we want it to penalise; and judging against a pre-stated spec rather
than the raw trajectory cut judge FPR from 0.64 to 0.28 (2510.03217). So:

  * five FIXED rubric items, each scored on its own call, never batched;
  * K independent samples per item, aggregated by median;
  * every sample must quote the diff hunk or trajectory line that decides it —
    a quote that is not found verbatim in the evidence scores that sample 0;
  * the evidence is anonymised before the judge sees it: every vendor and model
    name becomes an IMPLEMENTER/REVIEWER role token;
  * the headline scalar is the plain MEAN of the item scores, so nothing about
    the LENGTH of a trajectory can move it — a longer run has more to be judged
    on, not more to be rewarded for.

Four of the five items are judged from the DIFF against a spec written before
the work started (brief.md), which is the regime that measured the lowest false
positives; only "resume coherence" needs the trajectory, and it is only asked at
all when the run actually has more than one segment.

The verifier is a third vendor on purpose: it is nobody's own homework being
graded. `llm_verifier.create_client()` picks the backend from OPENAI_BASE_URL,
DEEPSEEK_API_KEY or VERTEX_API_KEY, in that order, so this process sets exactly
one of them and clears the rest, and the item calls go to whichever client that
produced — `client.models.generate_content` for google-genai,
`client.chat.completions.create` for an OpenAI-compatible one.

Vertex is the exception, and the corporate-safe backend: outside express mode it
refuses API keys outright (`401 UNAUTHENTICATED: API keys are not supported by
this API. Expected OAuth2 access token or other authentication credentials that
assert a principal`), so a service-account JSON in the key file is authenticated
as a principal instead — GOOGLE_APPLICATION_CREDENTIALS gets the PATH, and the
`google.genai` client this file builds is used directly.

WHAT IT COSTS. At most `items × K` calls: 15 with the defaults, 12 for a run
that never resumed. The item prompts are a few hundred characters and the
answers are one small JSON object each, so the bill is the evidence: a diff item
carries at most MAX_CHARS/4 characters (~25k tokens) and the one trajectory item
at most MAX_CHARS (~100k tokens), which is ~600k input tokens in the worst case
against the ~2.7M of the single-scalar design this replaces (up to 9 passes ×
K over the whole trajectory).

The score is ADVISORY. Nothing in run-task.sh branches on it: a run that scores
0.1 ships exactly like one that scores 0.9, and the only thing the number is for
is sorting a corpus by "how well did this actually satisfy its brief".

Usage: verify.py <run-dir> <worktree> <base-ref> [--dry-run]

  --dry-run  build the trajectory, the evidence and the item prompts, print them
             as JSON, and stop — without importing llm_verifier and without
             reading the key. This is the whole adapter minus the network, which
             is what the test suite drives on a machine that has neither.

Env (all optional except the key file, which run-task.sh always passes):
  HARNESS_VERIFY_KEY_FILE     the credential: either a one-line API key or a
                              Google service-account JSON. Read in-process,
                              never in argv (same discipline as linear-api-key)
  HARNESS_VERIFY_PROVIDER     deepseek | vertex | openai. Unset infers it from
                              the key file: service-account JSON -> vertex,
                              anything else -> deepseek
  HARNESS_VERIFY_BASE_URL     OPENAI_BASE_URL for the openai provider
  HARNESS_VERIFY_GCP_PROJECT  vertex project; the JSON's project_id when unset
  HARNESS_VERIFY_GCP_LOCATION vertex region (default global; pin an EU region
                              for data residency)
  HARNESS_VERIFY_MODEL        model id; the library's default when unset
  HARNESS_VERIFY_EVALS        K independent samples per rubric item (default 3)
  HARNESS_VERIFY_MAX_CRITERIA cap on the acceptance criteria quoted into the
                              task spec (default 8; 0 = the Problem section
                              alone)
  HARNESS_VERIFY_STEP_CHARS   per-step clip (default 2000)
  HARNESS_VERIFY_MAX_CHARS    whole-trajectory clip (default 400000); the diff
                              evidence gets a quarter of it, because it is sent
                              once per diff item and the trajectory only once
  HARNESS_VERIFY_EFFORT       passed through as DEEPSEEK_EFFORT (default high),
                              using the library's existing DeepSeek request
                              configuration

Exit codes: 0 scored (or dry-run ok) · 2 usage · 3 skipped, one line on stderr
(no trajectory, no evidence, no key, library missing) · 1 anything else,
traceback on stderr.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_SKIP = 0, 1, 2, 3

# The seven filenames the reviewer prompt excuses (run-task.sh:1662): a resolver
# writes thousands of lines nobody reads, and they would eat the trajectory
# budget the actual change needs.
LOCKFILES = (
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock",
    "Podfile.lock", "pubspec.lock", "composer.lock",
)


# --- small helpers -----------------------------------------------------------

def env_text(name, default=""):
    """An env var, treating empty exactly like unset.

    run-task.sh passes every knob through unconditionally rather than building a
    conditional env list, so an unset knob arrives as an empty string.
    """
    value = os.environ.get(name)
    return value.strip() if value and value.strip() else default


def env_int(name, default, minimum=0):
    raw = env_text(name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= minimum else default


def clip(text, limit):
    """Clip to `limit` CHARACTERS, marker included, and say what was cut.

    The marker is inside the budget rather than added to it, so "clipped to N"
    is a fact a caller can assert on the string it gets back.
    """
    text = (text or "").strip()
    if limit <= 0 or len(text) <= limit:
        return text
    marker = "\n… [clipped: this step was %d characters]" % len(text)
    if len(marker) >= limit:
        return text[:limit]
    return text[: limit - len(marker)].rstrip() + marker


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, IOError):
        return ""


def git(worktree, *args):
    """A git call that never raises: an unreadable tree is an absent step."""
    try:
        out = subprocess.run(
            ("git", "-C", worktree) + args,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
    except (OSError, ValueError):
        return ""
    if out.returncode != 0:
        return ""
    return out.stdout.decode("utf-8", "replace")


# --- anonymisation -----------------------------------------------------------
# Self-preference bias is capability-independent and survives every prompt that
# merely asks a judge to be impartial, so the names are removed rather than
# deprecated: a judge that cannot tell whose work this is cannot prefer its own.
# Substrings, not word boundaries — `opus-stream.jsonl` and `.claude/` are names
# too, and a guarantee with an exception is not a guarantee.
VENDOR_ROLES = (
    ("anthropic", "IMPLEMENTER"),
    ("openai", "REVIEWER"),
    ("claude", "IMPLEMENTER"),
    ("sonnet", "IMPLEMENTER"),
    ("codex", "REVIEWER"),
    ("opus", "IMPLEMENTER"),
    ("gpt", "REVIEWER"),
)
VENDOR_RE = re.compile("|".join(re.escape(name) for name, _ in VENDOR_ROLES),
                       re.IGNORECASE)
VENDOR_ROLE_OF = {name: role for name, role in VENDOR_ROLES}


def anonymize(text):
    """Every vendor and model name replaced by the role that wore it.

    Idempotent: the role tokens contain none of the names, so a payload can be
    passed through this twice — once as it is built, once as it is sent.
    """
    return VENDOR_RE.sub(lambda m: VENDOR_ROLE_OF[m.group(0).lower()],
                         text or "")


# --- the implementer's stream ------------------------------------------------

def content_blocks(event):
    """The content blocks of a stream-json message event, whatever its shape."""
    message = event.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return []


def flatten(content):
    """A tool_result's content, which is a string or a list of text blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text") or ""))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    if content is None:
        return ""
    return json.dumps(content, ensure_ascii=False)


def stream_steps(path):
    """One stream-json file -> (its steps, how many segments it holds).

    Each assistant text block is a narration step and each tool_use is folded
    together with its matching tool_result into a single "action + observed
    output" step: the judge is told to distrust the narration and read the
    output. `system` events carry no work.

    A `result` event is a segment boundary, not the end of the file: the
    implementer's stream is append-only within an invocation, so a turn-ceiling
    resume leaves its whole segment in the same file behind the exhausted one.
    Each result event therefore becomes a step of its own, in place — the resume
    marker for a turn budget that ran out, the closing message for the segment
    that ended the attempt — so the trajectory reads as the continuous piece of
    work it was rather than jumping from the first segment's last tool call to
    the last segment's first one. Those boundaries are also what the resume
    coherence item is asked about.
    """
    events = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue  # a stream killed mid-write ends on half a line
        if isinstance(event, dict):
            events.append(event)

    observed = {}
    for event in events:
        if event.get("type") != "user":
            continue
        for block in content_blocks(event):
            if block.get("type") == "tool_result":
                observed[block.get("tool_use_id")] = flatten(block.get("content"))

    steps = []
    segments = 0
    for event in events:
        kind = event.get("type")
        if kind == "assistant":
            for block in content_blocks(event):
                btype = block.get("type")
                if btype == "text":
                    text = str(block.get("text") or "").strip()
                    if text:
                        steps.append(("impl:narration", "The agent says:\n" + text))
                elif btype == "tool_use":
                    name = str(block.get("name") or "tool")
                    args = block.get("input")
                    try:
                        rendered = json.dumps(args, ensure_ascii=False, sort_keys=True)
                    except (TypeError, ValueError):
                        rendered = str(args)
                    output = observed.get(block.get("id"))
                    if output is None:
                        output = "(no output was recorded for this call)"
                    steps.append((
                        "impl:action",
                        "The agent ran %s with:\n%s\n\nObserved output:\n%s"
                        % (name, rendered, output.strip()),
                    ))
        elif kind == "result":
            segments += 1
            final = str(event.get("result") or "").strip()
            if event.get("subtype") == "error_max_turns":
                text = ("The agent's turn budget ran out here; the same session"
                        " was resumed with a fresh budget.")
                if final:
                    text += "\nIts last words before the resume:\n" + final
                steps.append(("impl:resume", text))
            else:
                if not final:
                    final = "(no closing message was recorded)"
                steps.append(("impl:result",
                              "The agent's closing message:\n" + final))
    return steps, segments


def stream_files(run_dir):
    """Every implementer stream this run has, oldest attempt first.

    attempts/<n>/opus-stream.jsonl is a finished attempt (run-task.sh rotates it
    on the way in); the live filename is the attempt that just ran. Each file is
    one attempt whole, turn-ceiling resumes and all — the stream is truncated
    once per invocation, not once per implementer spawn.
    """
    files = []
    attempts = os.path.join(run_dir, "attempts")
    try:
        names = os.listdir(attempts)
    except OSError:
        names = []
    numbered = []
    for name in names:
        if not name.isdigit():
            continue
        path = os.path.join(attempts, name, "opus-stream.jsonl")
        if os.path.isfile(path):
            numbered.append((int(name), path))
    files.extend(path for _, path in sorted(numbered))
    live = os.path.join(run_dir, "opus-stream.jsonl")
    if os.path.isfile(live):
        files.append(live)
    return files


# --- everything after the implementer ----------------------------------------

def gate_steps(run_dir):
    """One step per gate round: which round, its verdict, what it died on."""
    steps = []
    for line in read_text(os.path.join(run_dir, "gate-rounds.log")).splitlines():
        line = line.rstrip("\n")
        if not line.strip():
            continue
        head, _, failed = line.partition("\t")
        fields = head.split()
        if len(fields) < 2:
            continue
        text = "Test gate round %s: %s" % (fields[0], fields[1])
        if failed.strip():
            text += "\nFailing step: " + failed.strip()
        steps.append(("gate:round", text))
    return steps


def review_steps(run_dir, worktree):
    """The reviewer's own evidence: what it wrote, and what it committed.

    The notes live in the worktree while the run is in flight and are harvested
    into the run dir when it ends, so both are consulted — this stage runs
    between those two moments.
    """
    steps = []
    # A rejection is the terminal review finding and wins when an earlier round
    # also left review-notes.md behind.
    for name, label in (("REJECTED.md", "rejection"), ("review-notes.md", "notes")):
        text = ""
        for base in (os.path.join(worktree, ".harness"), run_dir):
            text = read_text(os.path.join(base, name))
            if text.strip():
                break
        if text.strip():
            steps.append((
                "review:" + label,
                "The reviewer wrote .harness/%s:\n%s" % (name, text.strip()),
            ))
            break

    head = git(worktree, "rev-parse", "HEAD").strip()
    opus_head = read_text(os.path.join(run_dir, "opus-head")).strip()
    if opus_head and head and opus_head != head:
        log = git(worktree, "log", "--stat", "%s..HEAD" % opus_head)
        if log.strip():
            steps.append((
                "review:commits",
                "Commits the reviewer added after the implementer stopped "
                "(git log --stat %s..HEAD):\n%s" % (opus_head[:12], log.strip()),
            ))
    return steps


def branch_diff(worktree, base_ref):
    """The complete diff of this branch against its base, lockfiles excluded.

    This is the evidence four of the five rubric items are judged from — what
    the run actually leaves behind, rather than how it narrated getting there.
    """
    excludes = [":(exclude)%s" % name for name in LOCKFILES]
    return git(worktree, "diff", "%s...HEAD" % base_ref, "--", ".", *excludes).strip()


def final_steps(worktree, base_ref, diff):
    """The observed end state as trajectory steps: the diff, and the verdict."""
    steps = []
    if diff:
        steps.append((
            "final:diff",
            "FINAL STATE — the complete diff of this branch against %s, "
            "lockfiles excluded (git diff %s...HEAD):\n%s"
            % (base_ref, base_ref, diff),
        ))
    header = []
    for line in read_text(os.path.join(worktree, ".harness", "gate-latest.log")).splitlines():
        if line.startswith("=== gate output follows ==="):
            break
        header.append(line)
    if any(line.strip() for line in header):
        steps.append((
            "final:gate",
            "FINAL STATE — the last test gate verdict:\n" + "\n".join(header).strip(),
        ))
    return steps


# --- the trajectory ----------------------------------------------------------

def elide(steps, max_chars):
    """Bring the trajectory under budget by dropping its middle, and say so.

    Head and tail both matter and for different reasons — the head is what the
    agent set out to do, the tail is what it actually left behind — so each
    keeps half the budget and the steps between them become one honest marker.
    """
    total = sum(len(text) for _, text in steps)
    if max_chars <= 0 or total <= max_chars:
        return steps, 0
    # Reserve for the largest count this trajectory can produce, so a run with
    # five-digit step counts cannot exceed max_chars by growing the marker.
    marker_len = len("[%d agent steps elided]" % len(steps))
    budget = max(0, max_chars - marker_len)
    tail_budget, head_budget = budget // 2, budget - budget // 2

    tail, spent = [], 0
    for kind, text in reversed(steps):
        if spent + len(text) > tail_budget:
            break
        tail.insert(0, (kind, text))
        spent += len(text)
    head, spent = [], 0
    for kind, text in steps[: len(steps) - len(tail)]:
        if spent + len(text) > head_budget:
            break
        head.append((kind, text))
        spent += len(text)

    dropped = len(steps) - len(head) - len(tail)
    if dropped <= 0:
        return steps, 0
    return head + [("elided", "[%d agent steps elided]" % dropped)] + tail, dropped


def build_trajectory(run_dir, worktree, base_ref, step_chars, max_chars):
    """Every step of the run, in the order it happened, clipped and anonymised.

    Returns (steps, elided_steps, segments, diff) — segments being how many
    implementer stretches the trajectory spans across every attempt, one per
    result event, which is also what decides whether the resume coherence item
    is asked at all. Never fabricates a step: a run whose implementer left no
    stream has no trajectory, and the caller turns that into a skip rather than
    into a number.

    Anonymisation happens before the budgets are applied, so every count a
    caller can assert on is a count of the text the judge will actually read.
    """
    steps = []
    segments = 0
    for path in stream_files(run_dir):
        file_steps, file_segments = stream_steps(path)
        steps.extend(file_steps)
        segments += file_segments
    if not steps:
        return [], 0, 0, ""
    diff = branch_diff(worktree, base_ref)
    steps.extend(gate_steps(run_dir))
    steps.extend(review_steps(run_dir, worktree))
    steps.extend(final_steps(worktree, base_ref, diff))
    steps = [(kind, clip(anonymize(text), step_chars)) for kind, text in steps]
    steps, elided = elide(steps, max_chars)
    return steps, elided, segments, diff


# --- the rubric --------------------------------------------------------------
# Five items, and only five. Each one is a question a reader of the diff can
# answer on its own, none of them is a proxy for "how much work was this", and
# together they are the vector the headline mean is taken over.
#
# `evidence` says which block the item is shown and, with it, where a citation
# has to come from: `diff` items may only quote the diff, the `trajectory` item
# may only quote a trajectory line.
RUBRIC = (
    {
        "id": "coverage",
        "title": "Brief coverage",
        "evidence": "diff",
        "question":
            "Does this change actually deliver everything the TASK SPEC asked"
            " for? Score 1.0 only when every stated requirement is present in"
            " the diff. Score down for each requirement that is missing, stubbed"
            " or only half-built. Judge the code, not any claim about it.",
    },
    {
        "id": "scope",
        "title": "No unrequested scope",
        "evidence": "diff",
        "question":
            "Does this change stay inside what the TASK SPEC asked for? Score"
            " 1.0 when nothing in the diff is beyond the task. Score down for"
            " each unrequested addition — drive-by refactors, unrelated files,"
            " speculative options nobody asked for, renames the task did not"
            " need.",
    },
    {
        "id": "minimality",
        "title": "Diff minimality and hygiene",
        "evidence": "diff",
        "question":
            "Is this the smallest, cleanest diff the task allows? Score 1.0 for"
            " a change with no dead code, no leftover debugging, no"
            " commented-out blocks, no reformatting churn and no duplication of"
            " something the codebase already has. Score down in proportion to"
            " the bulk the task did not require. A big change that the task"
            " genuinely requires is not a penalty.",
    },
    {
        "id": "tests",
        "title": "Test integrity",
        "evidence": "diff",
        "question":
            "Do the tests in this diff genuinely exercise this change? Judge"
            " from the diff alone. Score 1.0 when a new or changed test would"
            " fail if the change under it were reverted. Score down for tests"
            " that assert nothing, tests weakened, skipped or deleted to make a"
            " suite pass, and for behaviour of this kind left untested"
            " altogether.",
    },
    {
        "id": "resume",
        "title": "Resume coherence",
        "evidence": "trajectory",
        "needs_segments": 2,
        "question":
            "This work stopped and was picked up again at least once; the"
            " boundaries are the steps saying a turn budget ran out or a"
            " segment closed. Did the work after a boundary stay consistent"
            " with the work before it? Score 1.0 when the later segments"
            " continue the earlier ones. Score down for work redone from"
            " scratch, for a decision made earlier and contradicted later, and"
            " for a half-finished change abandoned across the boundary.",
    },
)

# The diff is sent once per diff item (four of them) and the trajectory at most
# once, so they cannot share a budget: the diff gets a quarter of MAX_CHARS,
# which keeps the worst-case bill of a rubric pass below that of the single
# whole-trajectory pass it replaces.
DIFF_SHARE = 4

# A quote shorter than this cannot identify a hunk or a line, and would match
# somewhere in any evidence block by accident — which is the one way a citation
# requirement can be satisfied without citing anything.
MIN_CITATION = 8

# The library's own cap. The answer is one small JSON object; the cap only has
# to be wide enough that a reasoning model reaches it.
ANSWER_TOKENS = 4096

ANSWER_CONTRACT = """ANSWER FORMAT
Reply with ONE JSON object and nothing else, citation first:
{"citation": "<a span copied verbatim out of the EVIDENCE above>", "score": <number from 0.0 to 1.0>}

- The citation is what makes the score checkable. It must appear in EVIDENCE
  character for character; an answer whose quote is not found there scores 0
  whatever number it carries.
- Quote the SMALLEST span that decides the item — one changed line, one hunk
  header, one line of the record. Never quote this instruction block.
- 1.0 is fully satisfied and 0.0 is not satisfied at all. Use the range in
  between; most real work is neither.
- Do not explain, do not add prose around the JSON, do not use markdown."""

PREAMBLE = """You are grading ONE item of a fixed rubric about a finished software change.

Everyone in this record is anonymous and stays that way: IMPLEMENTER wrote the
change and REVIEWER read it afterwards. Judge the evidence in front of you and
nothing about who produced it. Length is not quality: a long record is more to
read, not more to reward."""


def item_prompt(item, spec, evidence):
    """The whole payload for one rubric item, anonymised as it goes out.

    Same skeleton for every item so that only the question and the evidence
    differ between them — an item is a question about a body of evidence, and
    nothing in the framing should vary with which item it is.
    """
    label = ("the complete diff of the finished change"
             if item["evidence"] == "diff"
             else "the ordered record of the run, step by step")
    return anonymize("\n\n".join([
        PREAMBLE,
        "TASK SPEC — written before any of this work started\n" + spec,
        "EVIDENCE — %s\n%s" % (label, evidence),
        "RUBRIC ITEM — %s\n%s" % (item["title"], item["question"]),
        ANSWER_CONTRACT,
    ]))


def brief_sections(run_dir):
    """(title, problem, criteria) from the brief the run was dispatched with."""
    text = read_text(os.path.join(run_dir, "brief.md"))
    title, problem, criteria = "", [], []
    section = ""
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("# ") and not title:
            title = line[2:].strip()
            continue
        if line.startswith("## "):
            if current is not None:
                criteria.append(current)
                current = None
            section = line[3:].strip().lower()
            continue
        if section == "problem":
            problem.append(line)
        elif section == "acceptance criteria":
            stripped = line.strip()
            low = stripped.lower()
            if low.startswith("- [ ]") or low.startswith("- [x]"):
                if current is not None:
                    criteria.append(current)
                current = stripped[5:].strip()
            elif current is not None:
                if stripped:
                    current += " " + stripped
                else:
                    criteria.append(current)
                    current = None
    if current is not None:
        criteria.append(current)
    return title, "\n".join(problem).strip(), [c for c in criteria if c]


def task_spec(title, problem, criteria, limit):
    """The pre-stated spec every item is graded against.

    The acceptance criteria are the spec at its sharpest, which is why they are
    quoted into every item rather than scored one by one: a judge that reads a
    diff against a written contract is a far better false-positive filter than
    one that reads a trajectory and forms its own idea of the task.
    """
    parts = ["Task: " + (title or "(untitled)")]
    if problem:
        parts.append("What the task is about:\n" + clip(problem, limit))
    if criteria:
        parts.append(
            "What the task must deliver:\n"
            + "\n".join("%d. %s" % (i + 1, c) for i, c in enumerate(criteria))
        )
    return "\n\n".join(parts)


# --- the credential ----------------------------------------------------------

def read_credential(path):
    """What the key file actually holds, parsed once and never exported.

    Two shapes are supported, because Vertex needs the second one: a one-line
    API key (DeepSeek, an OpenAI-compatible server, or Vertex express mode), or
    a Google service-account JSON. Returns
    {path, kind: "api_key"|"service_account"|"", text, data}.
    """
    text = read_text(path).strip() if path else ""
    cred = {"path": path, "kind": "", "text": text, "data": {}}
    if not text:
        return cred
    cred["kind"] = "api_key"
    try:
        data = json.loads(text)
    except ValueError:
        return cred  # the ordinary case: a key is not JSON
    if isinstance(data, dict) and data.get("type") == "service_account":
        cred["kind"] = "service_account"
        cred["data"] = data
    return cred


def secret_strings(cred):
    """Every literal that must never reach a log, longest first.

    The file's own text covers an API key. A service account needs more: a
    library that prints the PARSED credential shows a private key whose real
    newlines look nothing like the \\n escapes in the file, so the parsed
    material is redacted in its own right.
    """
    out = [cred.get("text") or ""]
    data = cred.get("data") or {}
    for name in ("private_key", "private_key_id"):
        out.append(str(data.get(name) or "").strip())
    # Eight characters is well below any real credential and well above the
    # substrings ("", "-") that would redact the whole traceback.
    return sorted({s for s in out if len(s) >= 8}, key=len, reverse=True)


def redact(text, cred):
    for secret in secret_strings(cred):
        text = text.replace(secret, "<redacted>")
    return text


# --- the client --------------------------------------------------------------

def vertex_client(cred):
    """A Vertex client authenticated as a service-account principal.

    Verified against the real service: an API key created for aiplatform is
    refused outside express mode, while a service-account JSON with
    roles/aiplatform.user is accepted. Only the PATH goes into the environment —
    GOOGLE_APPLICATION_CREDENTIALS is a filename by contract, and the private
    key never leaves this process.

    Returns (client, location); the location is recorded because where the
    scoring ran is the whole point of pinning an EU region.
    """
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = cred["path"]
    project = env_text("HARNESS_VERIFY_GCP_PROJECT") \
        or str(cred["data"].get("project_id") or "").strip()
    if not project:
        raise SystemExit(
            "verify.py: vertex needs a project — the service-account JSON has no "
            "project_id, so set HARNESS_VERIFY_GCP_PROJECT")
    location = env_text("HARNESS_VERIFY_GCP_LOCATION", "global")
    from google import genai  # noqa: E402  (lazy, like llm_verifier below)
    return genai.Client(vertexai=True, project=project, location=location), location


def make_client(provider, cred, base_url):
    """Import the library and build its client for exactly one backend.

    create_client() reads OPENAI_BASE_URL, then DEEPSEEK_API_KEY, then
    VERTEX_API_KEY, so an ambient variable from the operator's shell could
    otherwise pick a backend the run never asked for: clear all three first.

    Returns (llm_verifier, client, location) — location is empty for every
    backend that is not Vertex.
    """
    key = cred["text"]
    # Keep the unused selectors present-but-empty instead of removing them.
    # llm_verifier calls load_dotenv() while building the client; its
    # setdefault() would otherwise resurrect a backend from the caller's .env
    # after we had cleared it, letting (for example) OPENAI_BASE_URL outrank a
    # requested Vertex client. OPENAI_API_KEY is credential material too: an
    # OpenAI-compatible run must use the key file handed to this process, never
    # an ambient key from the operator's shell or .env.
    for name in ("OPENAI_BASE_URL", "OPENAI_API_KEY", "DEEPSEEK_API_KEY",
                 "VERTEX_API_KEY"):
        os.environ[name] = ""
    location = ""
    if provider == "deepseek":
        os.environ["DEEPSEEK_API_KEY"] = key
    elif provider == "vertex":
        # Express-mode keys keep the library's documented path; a service
        # account cannot use it at all, so that client is built here instead.
        if cred["kind"] != "service_account":
            os.environ["VERTEX_API_KEY"] = key
    elif provider == "openai":
        if not base_url:
            raise SystemExit(
                "verify.py: provider openai needs HARNESS_VERIFY_BASE_URL")
        os.environ["OPENAI_BASE_URL"] = base_url
        if key:
            os.environ["OPENAI_API_KEY"] = key
    else:
        raise SystemExit("verify.py: unknown provider %r" % provider)
    # An empty value is not a valid library setting. Pin its documented default
    # when the harness knob is absent, which also prevents load_dotenv() from
    # silently supplying an unrelated local override.
    os.environ["DEEPSEEK_EFFORT"] = env_text("HARNESS_VERIFY_EFFORT", "high")
    import llm_verifier  # noqa: E402  (lazy on purpose — --dry-run needs none of it)
    if provider == "vertex" and cred["kind"] == "service_account":
        client, location = vertex_client(cred)
    else:
        client = llm_verifier.create_client()
    return llm_verifier, client, location


def is_genai(client):
    """google-genai clients generate; OpenAI-compatible ones chat.

    Both expose `.models`, so the discriminator is the method, not the
    attribute: an OpenAI client's `.models` only lists them.
    """
    return hasattr(getattr(client, "models", None), "generate_content")


def judge_model(lv, client, pinned):
    """The model id these calls will actually name.

    A pinned id always wins. Otherwise the library's own resolution: DeepSeek
    and OpenAI-compatible clients cache what they serve on the client, and a
    server that has not been asked yet is asked once — recording the package's
    global Gemini default for a DeepSeek run would mislabel it in every surface.
    """
    if pinned:
        return pinned
    name = str(getattr(client, "_llm_verifier_model", "") or "")
    if not name and not is_genai(client):
        try:
            name = str(client.models.list().data[0].id)
        except Exception:  # an unlistable server is not worth a failed run
            name = ""
    return name or str(getattr(lv, "DEFAULT_MODEL", "") or "")


def token_counts(response):
    """(input, cached input, output, reasoning) from either response shape."""
    usage = getattr(response, "usage", None)          # OpenAI-compatible
    if usage is not None:
        cached = getattr(getattr(usage, "prompt_tokens_details", None),
                         "cached_tokens", 0) or 0
        if not cached:
            cached = getattr(usage, "prompt_cache_hit_tokens", 0) or 0
        return (
            getattr(usage, "prompt_tokens", 0) or 0,
            cached,
            getattr(usage, "completion_tokens", 0) or 0,
            getattr(getattr(usage, "completion_tokens_details", None),
                    "reasoning_tokens", 0) or 0,
        )
    meta = getattr(response, "usage_metadata", None)  # google-genai
    if meta is not None:
        thoughts = getattr(meta, "thoughts_token_count", 0) or 0
        return (
            getattr(meta, "prompt_token_count", 0) or 0,
            getattr(meta, "cached_content_token_count", 0) or 0,
            (getattr(meta, "candidates_token_count", 0) or 0) + thoughts,
            thoughts,
        )
    return 0, 0, 0, 0


def make_asker(client, model, usage, deepseek_params=None):
    """One prompt in, one answer out, whichever client shape we were handed.

    These are the same two calls the library makes internally — generate_content
    for google-genai, chat.completions.create for OpenAI-compatible — minus the
    logprob machinery, which a rubric answer has no use for: the number is in
    the answer, and the citation beside it is what makes the number checkable.
    Token usage is counted here because these calls are the whole bill.
    """
    genai = is_genai(client)
    deepseek = bool(getattr(client, "_llm_verifier_deepseek", False))

    def openai_request(**kwargs):
        usage["calls"] += 1
        return client.chat.completions.create(**kwargs)

    def ask(prompt):
        if genai:
            usage["calls"] += 1
            response = client.models.generate_content(
                model=model, contents=prompt,
                config={"temperature": 1.0,
                        "max_output_tokens": ANSWER_TOKENS,
                        "thinking_config": {"thinking_budget": 0}})
        else:
            params = {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 1.0,
            }
            if deepseek:
                extra_body, max_tokens = deepseek_params()
                response = openai_request(
                    max_tokens=max_tokens, extra_body=extra_body, **params)
            else:
                params["max_tokens"] = ANSWER_TOKENS
                try:
                    # Preserve the library's vLLM/SGLang fast path. Servers
                    # that do not understand it get the same plain fallback.
                    response = openai_request(
                        extra_body={"chat_template_kwargs": {
                            "enable_thinking": False}}, **params)
                except Exception:
                    response = openai_request(**params)
        got, cached, out, reasoning = token_counts(response)
        usage["input_tokens"] += got
        usage["cached_input_tokens"] += cached
        usage["output_tokens"] += out
        usage["reasoning_tokens"] += reasoning
        if genai:
            try:
                return str(getattr(response, "text", "") or "")
            except (AttributeError, ValueError):
                return ""  # a blocked or empty candidate has no text at all
        choices = getattr(response, "choices", None) or []
        if not choices:
            return ""
        return str(getattr(choices[0].message, "content", "") or "")

    return ask


# --- reading one answer ------------------------------------------------------

def parse_answer(reply):
    """(score, citation) out of whatever the judge actually replied.

    The contract asks for one bare JSON object; models fence it, prefix it or
    trail it anyway, so the outermost brace pair is tried as well. Anything this
    cannot read is an answer with no score and no citation, which the caller
    scores exactly as it scores an invented quote.
    """
    text = (reply or "").strip()
    data = None
    for candidate in (text, text[text.find("{"): text.rfind("}") + 1]):
        if not candidate:
            continue
        try:
            parsed = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            data = parsed
            break
    if data is None:
        return None, ""
    try:
        score = float(data.get("score"))
    except (TypeError, ValueError):
        return None, str(data.get("citation") or "")
    if score != score:  # NaN compares unequal to itself
        return None, str(data.get("citation") or "")
    return min(1.0, max(0.0, score)), str(data.get("citation") or "")


def squeeze(text):
    """Whitespace- and case-insensitive form, for matching a quote to evidence.

    A judge that re-wraps a quoted line or copies it out of a rendered view has
    still cited the line; one that paraphrases it has not.
    """
    return re.sub(r"\s+", " ", text or "").strip().lower()


def sample_item(ask, prompt, haystack):
    """One independent sample of one item: {score, citation, note}.

    The rule the whole design rests on: a sample that cannot point at the span
    deciding it scores 0. Not "is dropped" — an unevidenced judgement is a real
    observation about this sample, and three of them mean the item is 0. Only a
    call that never returned an answer is unknown, and that one is dropped.
    """
    try:
        reply = ask(prompt)
    except Exception as exc:  # noqa: BLE001 — one flaky call is not a verdict
        return {"score": None, "citation": "", "note": "call failed: %s" % exc}
    score, citation = parse_answer(reply)
    quote = squeeze(citation)
    if len(quote) < MIN_CITATION or quote not in haystack:
        return {"score": 0.0, "citation": "",
                "note": "no verifiable citation" if citation else "no citation"}
    if score is None:
        return {"score": 0.0, "citation": citation, "note": "no readable score"}
    return {"score": score, "citation": citation, "note": ""}


def median(values):
    ordered = sorted(values)
    n = len(ordered)
    if n == 0:
        return None
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def aggregate(samples):
    """(median score, the citation behind it, the per-sample vector).

    Median rather than mean, because K is small and one confused sample should
    not drag an item: with the default K=3 the median IS the majority when two
    samples agree. The citation reported is the one from the sample nearest the
    median — the quote that actually backs the number being published.
    """
    vector = [s["score"] for s in samples]
    scored = [v for v in vector if v is not None]
    if not scored:
        return None, "", vector
    middle = median(scored)
    best, distance = "", None
    for sample in samples:
        if sample["score"] is None or not sample["citation"]:
            continue
        gap = abs(sample["score"] - middle)
        if distance is None or gap < distance:
            best, distance = sample["citation"], gap
    return middle, best, vector


def rounded(value):
    return None if value is None else round(float(value), 3)


# --- entry point -------------------------------------------------------------

def usage_line():
    sys.stderr.write("usage: verify.py <run-dir> <worktree> <base-ref> [--dry-run]\n")
    return EXIT_USAGE


def main(argv):
    dry_run = False
    args = []
    for arg in argv:
        if arg == "--dry-run":
            dry_run = True
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return EXIT_OK
        elif arg.startswith("-"):
            return usage_line()
        else:
            args.append(arg)
    if len(args) != 3:
        return usage_line()
    run_dir, worktree, base_ref = args

    step_chars = env_int("HARNESS_VERIFY_STEP_CHARS", 2000, minimum=1)
    max_chars = env_int("HARNESS_VERIFY_MAX_CHARS", 400000, minimum=1)
    samples = env_int("HARNESS_VERIFY_EVALS", 3, minimum=1)
    max_criteria = env_int("HARNESS_VERIFY_MAX_CRITERIA", 8, minimum=0)

    steps, elided, segments, diff = build_trajectory(
        run_dir, worktree, base_ref, step_chars, max_chars)
    if not steps:
        sys.stderr.write("no trajectory: no implementer stream under %s\n" % run_dir)
        return EXIT_SKIP

    title, problem, criteria = brief_sections(run_dir)
    spec = task_spec(title, problem, criteria[:max_criteria], step_chars)
    evidence = {
        "diff": clip(anonymize(diff), max(1, max_chars // DIFF_SHARE)),
        "trajectory": "\n\n".join(
            "=== step %d ===\n%s" % (i + 1, text)
            for i, (_, text) in enumerate(steps)),
    }
    # An item with nothing to read is unknown, not zero: a branch with no diff
    # tells you nothing about test integrity, and inventing a 0 for it would put
    # a number in the corpus that no evidence backs.
    asked = [item for item in RUBRIC
             if evidence[item["evidence"]]
             and segments >= item.get("needs_segments", 0)]

    if dry_run:
        json.dump({
            "run_dir": run_dir,
            "worktree": worktree,
            "base_ref": base_ref,
            "steps": len(steps),
            "segments": segments,
            "labels": [kind for kind, _ in steps],
            "chars": sum(len(text) for _, text in steps),
            "elided_steps": elided,
            "step_chars": step_chars,
            "max_chars": max_chars,
            "diff_chars": len(evidence["diff"]),
            "samples": samples,
            "criteria": criteria[:max_criteria],
            "spec": spec,
            "items": [{
                "id": item["id"],
                "title": item["title"],
                "evidence": item["evidence"],
                "prompt": item_prompt(item, spec, evidence[item["evidence"]]),
            } for item in asked],
            "first": steps[0][1],
            "last": steps[-1][1],
        }, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return EXIT_OK

    if not asked:
        sys.stderr.write("no evidence: nothing under %s to score a rubric item "
                         "against\n" % run_dir)
        return EXIT_SKIP

    key_file = env_text("HARNESS_VERIFY_KEY_FILE")
    cred = read_credential(key_file)
    # An explicit provider always wins; an absent one is read off the credential
    # itself, so a station goes corporate-safe by dropping a service-account
    # JSON in place — no shell export, no config file.
    provider = env_text("HARNESS_VERIFY_PROVIDER") or (
        "vertex" if cred["kind"] == "service_account" else "deepseek")
    base_url = env_text("HARNESS_VERIFY_BASE_URL")
    if not cred["text"] and provider != "openai":
        sys.stderr.write("no key: %s is unreadable or empty\n"
                         % (key_file or "HARNESS_VERIFY_KEY_FILE"))
        return EXIT_SKIP
    try:
        lv, client, location = make_client(provider, cred, base_url)
    except ImportError as exc:
        sys.stderr.write("library missing: %s\n" % exc)
        return EXIT_SKIP

    model = judge_model(lv, client, env_text("HARNESS_VERIFY_MODEL"))
    counts = {"calls": 0, "input_tokens": 0, "cached_input_tokens": 0,
              "output_tokens": 0, "reasoning_tokens": 0}
    deepseek_params = None
    if getattr(client, "_llm_verifier_deepseek", False):
        # Reuse the library's established DeepSeek request configuration: the
        # reasoning effort and its larger shared output budget are provider
        # settings, not part of the logprob scoring machinery we replaced.
        deepseek_params = getattr(lv, "deepseek_reasoning_params", None)
        if deepseek_params is None:
            from llm_verifier.fine_grained_reward import (
                deepseek_reasoning_params)
            deepseek_params = deepseek_reasoning_params
    ask = make_asker(client, model, counts, deepseek_params)
    started = time.time()

    scored = []
    for item in asked:
        body = evidence[item["evidence"]]
        prompt = item_prompt(item, spec, body)
        haystack = squeeze(body)
        drawn = [sample_item(ask, prompt, haystack) for _ in range(samples)]
        score, citation, vector = aggregate(drawn)
        scored.append({"item": item, "score": score, "citation": citation,
                       "samples": vector, "drawn": drawn})

    unscored = [entry for entry in scored if entry["score"] is None]
    if unscored:
        # Publishing a partial vector would silently remove a fixed rubric item
        # from the headline mean, and would put a null where the schema promises
        # an item score. One failed sample is harmless when its siblings answer;
        # an item with no answers makes the verifier attempt a failure.
        notes = [d["note"] for entry in unscored
                 for d in entry["drawn"] if d["note"]]
        detail = redact(notes[0] if notes else "no answers", cred)
        if len(unscored) == len(scored):
            reason = "no rubric item could be scored"
        else:
            reason = "rubric item(s) could not be scored: " + ", ".join(
                entry["item"]["id"] for entry in unscored)
        sys.stderr.write("verify.py: %s (%s)\n" % (reason, detail))
        return EXIT_FAIL

    vector = [entry["score"] for entry in scored]

    document = {
        # The plain mean of the item scores, and nothing else. Every other
        # aggregate a trajectory scorer might use — a weighted sum, a
        # last-checkpoint reading, anything computed over the steps themselves —
        # moves when the trajectory gets longer. This cannot: five bounded
        # answers to five fixed questions, averaged.
        "score": rounded(sum(vector) / len(vector)),
        # Kept for the schema, and null on purpose: the implementer-end
        # checkpoint belonged to the progress curve this rubric replaces, and a
        # rubric is a statement about the finished change, not about a prefix
        # of the run. Every consumer already renders null as "not recorded".
        "at_implementer": None,
        # The legacy per-criterion table, now carrying the rubric by its titles,
        # so a consumer written against the old schema (the PR body's table,
        # status.sh's count) renders the vector without being taught anything.
        "criteria": [{"name": entry["item"]["title"], "score": rounded(entry["score"])}
                     for entry in scored],
        "items": [{
            "id": entry["item"]["id"],
            "score": rounded(entry["score"]),
            "citation": entry["citation"],
            "samples": [rounded(v) for v in entry["samples"]],
        } for entry in scored],
        "model": model,
        "provider": provider,
        "evaluations": samples,
        "steps": len(steps),
        "segments": segments,
        "elided_steps": elided,
        "usage": counts,
        "seconds": round(time.time() - started, 3),
    }
    # Vertex only, and only when a region was actually chosen: where the scoring
    # ran is the whole point of pinning one.
    if location:
        document["location"] = location
    write_json(os.path.join(run_dir, "verify.json"), document)
    sys.stdout.write("verify: score %s (%d rubric items × %d samples, %d steps)\n"
                     % (document["score"], len(scored), samples, len(steps)))
    return EXIT_OK


def write_json(path, document):
    """Temp file plus rename: a reader never sees half a score."""
    directory = os.path.dirname(path) or "."
    handle, tmp = tempfile.mkstemp(dir=directory, prefix=".verify-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as fh:
            json.dump(document, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException:
        # The credential is loaded in this process, so scrub it out of anything
        # that reaches a log: verify.log is world-readable, the key file is 600.
        # A service account is redacted in both of its shapes — the file's text
        # and the parsed private key — because a frame that shows the parsed
        # dict shows real newlines where the file has \n escapes.
        import traceback
        sys.stderr.write(redact(traceback.format_exc(),
                                read_credential(env_text("HARNESS_VERIFY_KEY_FILE"))))
        sys.exit(EXIT_FAIL)
