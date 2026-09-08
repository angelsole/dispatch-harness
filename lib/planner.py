"""Shared planner defaults and startup instructions for local and Mini sessions."""
import argparse
import os
from pathlib import Path

DEFAULT_MODELS = {"codex": "gpt-6-astra", "claude": "fable"}


def prompt(runtime, task="", *, no_publish=False, hands_off=False):
    protocol = runtime / "planner-skills/dispatch/SKILL.md"
    if not protocol.is_file():
        protocol = runtime / "skills/dispatch/SKILL.md"
    if not protocol.is_file():
        raise FileNotFoundError("Dispatch planner instructions are missing; update this harness installation")
    text = (
        "You are the Dispatch planner for this conversation. First read the dispatch skill at "
        + str(protocol) + ". Use it for the user's coding tasks and run recovery. "
        "The user chooses the planner and describes the task; you own repository setup, briefing, "
        "submission, observation, routine recovery, and assessing the reviewed result. "
        "Use the current directory locally unless the user explicitly selected another execution host. "
        "Keep the selected account. Choose routine execution settings from repository policy and "
        "harness defaults; do not ask the user to select workers, reviewers, browser tools, or retry commands. "
        "For frontend changes, plan screenshots and video when useful, prepare capture prerequisites, "
        "and assess the resulting media. Correct routine setup or storyboard problems within scope "
        "and recover them yourself. After submission, follow the task through to a reviewed result "
        "or a concrete blocker; do not finish by handing the user monitoring commands. "
        "Use dispatch resume RUN-ID to recover a stopped run or missing frontend evidence. "
        "Return the outcome, PR or local branch, verification, and relevant media. "
        "Before submitting a free-text task, ask once whether to use a tracker ticket or run ad hoc, "
        "unless the user already specified that choice or supplied an existing ticket. "
        "Hands-off mode does not choose tracking. Ask about unresolved product decisions and "
        "account-holder sign-in when necessary. Keep the user's authorized scope. "
        "Answer questions about the harness directly; they are not automatically coding tasks."
    )
    if hands_off:
        text += " Proceed without routine confirmation within this task's authorized scope."
    if no_publish:
        text += " Use dispatch run --no-publish; keep a reviewed local branch without pushing or opening a PR."
    if task:
        text += "\n\nTask: " + task
    else:
        text += "\n\nNo task has been supplied yet. Ask what the user wants to work on, then wait for their description."
    return text


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("model", "prompt"))
    parser.add_argument("value")
    parser.add_argument("--hands-off", action="store_true")
    args = parser.parse_args()
    if args.action == "model":
        if args.value not in DEFAULT_MODELS:
            parser.error("unknown planner")
        print(DEFAULT_MODELS[args.value])
    else:
        print(prompt(Path(args.value), no_publish=os.environ.get("HARNESS_PUBLISH") == "0",
                     hands_off=args.hands_off))
