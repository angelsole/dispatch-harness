"""Score a finished run's trajectory with a third-vendor verifier.

The harness records plenty about how a run BEHAVED — turns, tokens, gate rounds,
commit counts, +/- lines — and nothing about how well it satisfied its brief.
This adapter turns the artefacts a run already leaves on disk into the input
[llm-as-a-verifier](https://github.com/llm-as-a-verifier/llm-as-a-verifier)
wants — a problem statement plus an ordered list of agent steps, each one an
action WITH its observed output — and records the score it returns.

The verifier is a third vendor on purpose. Its reward is the expectation over
the logprobs of a 20-letter score token, and neither Claude nor the ChatGPT
subscription this pipeline runs on exposes logprobs; that it is nobody's own
homework being graded is the second reason. `llm_verifier.create_client()` picks
the backend from OPENAI_BASE_URL, DEEPSEEK_API_KEY or VERTEX_API_KEY, in that
order, so this process sets exactly one of them and clears the rest.

Vertex is the exception, and the corporate-safe backend: outside express mode it
refuses API keys outright (`401 UNAUTHENTICATED: API keys are not supported by
this API. Expected OAuth2 access token or other authentication credentials that
assert a principal`), so a service-account JSON in the key file is authenticated
as a principal instead — GOOGLE_APPLICATION_CREDENTIALS gets the PATH, and the
`google.genai` client this file builds is handed straight to `track()`.

The score is ADVISORY. Nothing in run-task.sh branches on it: a run that scores
0.1 ships exactly like one that scores 0.9, and the only thing the number is for
is sorting a corpus by "how well did this actually satisfy its brief".

Usage: verify.py <run-dir> <worktree> <base-ref> [--dry-run]

  --dry-run  build the steps and the criteria, print them as JSON, and stop —
             without importing llm_verifier and without reading the key. This is
             the whole adapter minus the network, which is what the test suite
             drives on a machine that has neither.

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
  HARNESS_VERIFY_EVALS        K repeats per checkpoint (default 3)
  HARNESS_VERIFY_MAX_CRITERIA cap on scored acceptance criteria (default 8;
                              0 = the overall score only)
  HARNESS_VERIFY_STEP_CHARS   per-step clip (default 2000)
  HARNESS_VERIFY_MAX_CHARS    whole-trajectory clip (default 400000)
  HARNESS_VERIFY_EFFORT       passed through as DEEPSEEK_EFFORT

Exit codes: 0 scored (or dry-run ok) · 2 usage · 3 skipped, one line on stderr
(no trajectory, no key, library missing) · 1 anything else, traceback on stderr.
"""
import json
import os
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

# Which part of the run a step came from. The order of this tuple IS the order
# of the trajectory, and the `impl:` prefix is what marks the steps the
# implementer itself produced — the "score at implementer end" checkpoint is the
# last of those.
KIND_IMPLEMENTER = "impl:"


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
    output" step, which is the shape the verifier's prompt is written for: it is
    told to distrust the narration and read the output. `system` events carry no
    work.

    A `result` event is a segment boundary, not the end of the file: the
    implementer's stream is append-only within an invocation, so a turn-ceiling
    resume leaves its whole segment in the same file behind the exhausted one.
    Each result event therefore becomes a step of its own, in place — the resume
    marker for a turn budget that ran out, the closing message for the segment
    that ended the attempt — so the trajectory reads as the continuous piece of
    work it was rather than jumping from the first segment's last tool call to
    the last segment's first one.
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


def final_steps(run_dir, worktree, base_ref):
    """The observed end state: the whole diff, and the standing gate verdict.

    This is the evidence the score is really about — everything above is how the
    run got here, and this is what it actually leaves behind.
    """
    steps = []
    excludes = [":(exclude)%s" % name for name in LOCKFILES]
    diff = git(worktree, "diff", "%s...HEAD" % base_ref, "--", ".", *excludes)
    if diff.strip():
        steps.append((
            "final:diff",
            "FINAL STATE — the complete diff of this branch against %s, "
            "lockfiles excluded (git diff %s...HEAD):\n%s"
            % (base_ref, base_ref, diff.strip()),
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
    """Every step of the run, in the order it happened, clipped to budget.

    Returns (steps, elided_steps, segments) — segments being how many
    implementer stretches the trajectory spans across every attempt, one per
    result event, so a score can be read against the shape of the run that
    produced it. Never fabricates a step: a run whose implementer left no stream
    at all has no trajectory to score, and the caller turns that into a skip
    rather than into a number.
    """
    steps = []
    segments = 0
    for path in stream_files(run_dir):
        file_steps, file_segments = stream_steps(path)
        steps.extend(file_steps)
        segments += file_segments
    if not steps:
        return [], 0, 0
    steps.extend(gate_steps(run_dir))
    steps.extend(review_steps(run_dir, worktree))
    steps.extend(final_steps(run_dir, worktree, base_ref))
    steps = [(kind, clip(text, step_chars)) for kind, text in steps]
    steps, elided = elide(steps, max_chars)
    return steps, elided, segments


def last_implementer_step(steps):
    """1-based index of the last step the implementer itself produced.

    The library numbers steps `=== Agent Step k ===` from 1, and the overall
    call checkpoints here and at the end, so the curve reads "what the
    implementer alone was worth" then "what shipped".
    """
    for i in range(len(steps) - 1, -1, -1):
        if steps[i][0].startswith(KIND_IMPLEMENTER):
            return i + 1
    return len(steps)


# --- the rubric --------------------------------------------------------------

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


def overall_problem(title, problem, criteria, limit):
    parts = ["Task: " + (title or "(untitled)")]
    if problem:
        parts.append("What the task is about:\n" + clip(problem, limit))
    if criteria:
        parts.append(
            "The hidden grader checks every one of these:\n"
            + "\n".join("%d. %s" % (i + 1, c) for i, c in enumerate(criteria))
        )
    return "\n\n".join(parts)


def criterion_problem(title, problem, criterion, limit):
    parts = [
        "Task: " + (title or "(untitled)"),
        "The hidden grader checks exactly one thing: " + criterion,
    ]
    if problem:
        parts.append("Context for that check:\n" + clip(problem, limit))
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


# --- scoring -----------------------------------------------------------------

def vertex_client(cred):
    """A Vertex client authenticated as a service-account principal.

    Verified against the real service: an API key created for aiplatform is
    refused outside express mode, while a service-account JSON with
    roles/aiplatform.user returns logprobs. Only the PATH goes into the
    environment — GOOGLE_APPLICATION_CREDENTIALS is a filename by contract, and
    the private key never leaves this process.

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


def score_of(result):
    """The absolute score a ProgressResult ends on, and the curve behind it."""
    scores = list(getattr(result, "scores", None) or [])
    final = getattr(result, "final", None)
    if final is None and scores:
        final = scores[-1]
    return final, scores


def rounded(value):
    return None if value is None else round(float(value), 3)


# --- entry point -------------------------------------------------------------

def usage():
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
            return usage()
        else:
            args.append(arg)
    if len(args) != 3:
        return usage()
    run_dir, worktree, base_ref = args

    step_chars = env_int("HARNESS_VERIFY_STEP_CHARS", 2000, minimum=1)
    max_chars = env_int("HARNESS_VERIFY_MAX_CHARS", 400000, minimum=1)
    evals = env_int("HARNESS_VERIFY_EVALS", 3, minimum=1)
    max_criteria = env_int("HARNESS_VERIFY_MAX_CRITERIA", 8, minimum=0)

    steps, elided, segments = build_trajectory(
        run_dir, worktree, base_ref, step_chars, max_chars)
    if not steps:
        sys.stderr.write("no trajectory: no implementer stream under %s\n" % run_dir)
        return EXIT_SKIP

    title, problem, all_criteria = brief_sections(run_dir)
    # The cap controls the extra per-criterion calls only. The overall verifier
    # always receives the full rubric; MAX_CRITERIA=0 means "overall only", not
    # "discard the acceptance criteria from the overall question".
    criteria = all_criteria[:max_criteria]
    texts = [text for _, text in steps]
    implementer_end = last_implementer_step(steps)
    checkpoints = [implementer_end, len(steps)]
    if checkpoints[0] == checkpoints[1]:
        checkpoints = [len(steps)]

    if dry_run:
        json.dump({
            "run_dir": run_dir,
            "worktree": worktree,
            "base_ref": base_ref,
            "steps": len(steps),
            "segments": segments,
            "labels": [kind for kind, _ in steps],
            "chars": sum(len(text) for text in texts),
            "elided_steps": elided,
            "step_chars": step_chars,
            "max_chars": max_chars,
            "checkpoints": checkpoints,
            "criteria": criteria,
            "first": texts[0],
            "last": texts[-1],
        }, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return EXIT_OK

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

    model = env_text("HARNESS_VERIFY_MODEL")
    started = time.time()

    def track(problem_text, checkpoint_steps):
        kwargs = {
            "checkpoint_steps": checkpoint_steps,
            "n_evaluations": evals,
            "client": client,
        }
        if model:
            kwargs["model"] = model
        return lv.track(problem_text, texts, **kwargs)

    result = track(overall_problem(title, problem, all_criteria, step_chars), checkpoints)
    final, curve = score_of(result)
    at_implementer = curve[0] if len(curve) > 1 else None

    scored = []
    for criterion in criteria:
        one, _ = score_of(track(
            criterion_problem(title, problem, criterion, step_chars), [len(steps)]))
        scored.append({"name": criterion, "score": rounded(one)})

    usage_counts = {}
    try:
        raw = lv.token_usage() or {}
        for name in ("calls", "input_tokens", "cached_input_tokens",
                     "output_tokens", "reasoning_tokens"):
            if name in raw:
                usage_counts[name] = raw[name]
    except Exception:  # a usage counter is never worth losing the score over
        usage_counts = {}

    document = {
        "score": rounded(final),
        "at_implementer": rounded(at_implementer),
        "criteria": scored,
        # DeepSeek and OpenAI-compatible clients resolve the package's global
        # Gemini default to the model the client actually serves, and cache that
        # answer on the client. Record that resolved model, not DEFAULT_MODEL,
        # or a default DeepSeek run is mislabeled as Gemini in every surface.
        "model": (model or getattr(client, "_llm_verifier_model", "")
                  or getattr(result, "model", "")
                  or getattr(lv, "DEFAULT_MODEL", "")),
        "provider": provider,
        "evaluations": evals,
        "steps": len(steps),
        "segments": segments,
        "elided_steps": elided,
        "usage": usage_counts,
        "seconds": round(time.time() - started, 3),
    }
    # Vertex only, and only when a region was actually chosen: where the scoring
    # ran is the whole point of pinning one.
    if location:
        document["location"] = location
    write_json(os.path.join(run_dir, "verify.json"), document)
    sys.stdout.write("verify: score %s (%d steps, %d criteria)\n"
                     % (document["score"], len(steps), len(scored)))
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
