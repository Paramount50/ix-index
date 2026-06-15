"""Entry point: python -m nox_autotriage --report <path>

Environment variables:
    DRY_RUN               Default "1" (safe). Set to "0" to write to Linear.
    SYMPHONY_OUTPUT_FILE  If set, the JSON result dict is also written here
                          (Symphony picks this up as the step output).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

from nox_autotriage import run


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m nox_autotriage",
        description="Triage a nox conformance report to Linear issues.",
    )
    parser.add_argument(
        "--report",
        required=True,
        metavar="PATH",
        help="Path to the nox conformance JSON report file.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)
    dry_run = os.environ.get("DRY_RUN", "1") != "0"

    result = asyncio.run(run(args.report, dry_run=dry_run))

    output = json.dumps(result)
    print(output)

    out_file = os.environ.get("SYMPHONY_OUTPUT_FILE", "")
    if out_file:
        with open(out_file, "w") as fh:
            fh.write(output)


if __name__ == "__main__":
    sys.exit(main())
