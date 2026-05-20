#!/usr/bin/env python3
"""Re-prefetch the ix CLI binaries and bump the locked hashes.

The ix.dev CLI endpoints serve mutable URLs (no versioned path), so
`nix flake check` fails as soon as a newer binary is published. Run
this when that happens; the only changes land in `packages/ix/default.nix`.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

URLS = {
    "x86_64-linux": "https://ix.dev/cli/linux-x86_64/ix",
    "aarch64-darwin": "https://ix.dev/cli/darwin-arm64/ix",
    "x86_64-darwin": "https://ix.dev/cli/darwin-x86_64/ix",
}


def prefetch(url: str) -> str:
    result = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--hash-type", "sha256", url],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)["hash"]


def patch(contents: str, url: str, sri: str) -> tuple[str, bool]:
    pattern = re.compile(
        r'(url = "' + re.escape(url) + r'";\s*\n\s*hash = ")[^"]+(";)',
    )
    new, count = pattern.subn(rf"\g<1>{sri}\g<2>", contents, count=1)
    if count != 1:
        raise SystemExit(f"expected one match for {url}, found {count}")
    return new, new != contents


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Re-prefetch the ix CLI binaries and bump the locked hashes.",
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=Path("packages/ix/default.nix"),
        help="Path to the ix CLI Nix package (default: packages/ix/default.nix).",
    )
    args = parser.parse_args()

    contents = args.target.read_text()
    bumped = []
    for system, url in URLS.items():
        print(f"prefetching {system}: {url}", file=sys.stderr)
        sri = prefetch(url)
        contents, changed = patch(contents, url, sri)
        if changed:
            bumped.append(system)

    args.target.write_text(contents)
    if bumped:
        print(f"updated {args.target} ({', '.join(bumped)})", file=sys.stderr)
    else:
        print(f"{args.target} already up to date", file=sys.stderr)


if __name__ == "__main__":
    main()
