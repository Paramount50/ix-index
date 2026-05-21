#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


DEFAULT_TASK = """Find one part of this repository that is not living up to AGENTS.md: subpar prose, awkward naming, brittle implementation, non-idiomatic structure, or a real quality problem. Make a substantive improvement that materially improves the repo. Prefer behavior, maintainability, correctness, or operator ergonomics over performative churn.

If you discover that AGENTS.md itself is wrong, stale, or biasing you toward a bad change, fix that durable instruction instead of working around it. Remove or narrow rules that encode an incorrect model of the repo; add a short invariant only when the same mistake would plausibly recur.

Work directly in the checkout. Do not commit or push; leave the working tree changes for the outer loop to check, commit, and push."""


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True)


def output(args: list[str]) -> str:
    return subprocess.check_output(args, text=True).strip()


def changed_paths() -> list[str]:
    tracked = output(["git", "diff", "--name-only", "--diff-filter=ACMRTUXB"]).splitlines()
    deleted = output(["git", "diff", "--name-only", "--diff-filter=D"]).splitlines()
    staged = output(["git", "diff", "--cached", "--name-only"]).splitlines()
    untracked = output(["git", "ls-files", "--others", "--exclude-standard"]).splitlines()
    return sorted({path for path in tracked + deleted + staged + untracked if path})


def is_clean() -> bool:
    return output(["git", "status", "--porcelain"]) == ""


def current_branch() -> str:
    return output(["git", "branch", "--show-current"])


def fast_forward(branch: str) -> None:
    run(["git", "fetch", "origin", branch])
    run(["git", "merge", "--ff-only", f"origin/{branch}"])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Codex in a commit-and-push loop for repo-quality improvements."
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=0,
        help="Number of iterations to run. 0 means forever.",
    )
    parser.add_argument(
        "--sleep-secs",
        type=int,
        default=30,
        help="Seconds to sleep between successful iterations.",
    )
    parser.add_argument(
        "--task",
        default=os.environ.get("CODEX_LOOP_TASK", DEFAULT_TASK),
        help="Prompt passed to `codex exec` each iteration.",
    )
    parser.add_argument(
        "--commit-message",
        default="loop: improve repo quality",
        help="Commit subject used for each loop-produced change.",
    )
    parser.add_argument(
        "--lint-program",
        default=os.environ.get("CODEX_LOOP_LINT"),
        help="Check command to run before committing.",
    )
    parser.add_argument(
        "--branch",
        default="development",
        help="Branch to require and push to.",
    )
    parser.add_argument(
        "--codex-model",
        default=os.environ.get("CODEX_LOOP_MODEL"),
        help="Optional model name passed to `codex exec --model`.",
    )
    parser.add_argument(
        "--reasoning-effort",
        default=os.environ.get("CODEX_LOOP_REASONING_EFFORT", "xhigh"),
        help="Reasoning effort passed through Codex config.",
    )
    parser.add_argument(
        "--bypass-sandbox",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Pass Codex --dangerously-bypass-approvals-and-sandbox.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single iteration.",
    )
    return parser.parse_args()


def build_codex_command(args: argparse.Namespace) -> list[str]:
    command = [
        "codex",
        "exec",
        "--cd",
        str(Path.cwd()),
        "-c",
        f'model_reasoning_effort="{args.reasoning_effort}"',
    ]
    if args.codex_model:
        command.extend(["--model", args.codex_model])
    if args.bypass_sandbox:
        command.append("--dangerously-bypass-approvals-and-sandbox")
    command.append(args.task)
    return command


def run_iteration(args: argparse.Namespace, lint_program: str, index: int) -> bool:
    print(f"loop: iteration {index}", flush=True)
    if current_branch() != args.branch:
        raise SystemExit(f"loop: expected branch {args.branch}, found {current_branch()}")
    if not is_clean():
        raise SystemExit("loop: working tree is dirty before Codex starts; refusing to mix changes")

    fast_forward(args.branch)
    run(build_codex_command(args))

    paths = changed_paths()
    if not paths:
        print("loop: Codex left no changes; nothing to commit", flush=True)
        return False

    run([lint_program])
    run(["git", "commit", "-m", args.commit_message, "--", *paths])
    run(["git", "push", "origin", f"HEAD:{args.branch}"])
    return True


def main() -> int:
    args = parse_args()
    if args.lint_program is None:
        raise SystemExit("loop: --lint-program is required")
    limit = 1 if args.once else args.iterations
    index = 1

    while limit == 0 or index <= limit:
        changed = run_iteration(args, args.lint_program, index)
        if limit == 1:
            return 0
        index += 1
        if changed and args.sleep_secs > 0:
            time.sleep(args.sleep_secs)

    return 0


if __name__ == "__main__":
    sys.exit(main())
