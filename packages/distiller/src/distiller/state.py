"""Per-(user, project) distillation state: items + which sessions were seen.

State lives under ``<out>/state/<user>/<project_slug>.json`` and is what makes
the run incremental: items carry stable ids across runs, and a session is
re-distilled only when its fingerprint (message count + last timestamp)
changed since the previous run.
"""

from __future__ import annotations

import json
from pathlib import Path


def state_path(out_dir: Path, user: str, slug: str) -> Path:
    return out_dir / "state" / user / f"{slug}.json"


def load(out_dir: Path, user: str, slug: str) -> dict:
    path = state_path(out_dir, user, slug)
    if not path.is_file():
        return {"project": None, "items": [], "distilled_sessions": {}}
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {"project": None, "items": [], "distilled_sessions": {}}
    data.setdefault("items", [])
    data.setdefault("distilled_sessions", {})
    return data


def save(out_dir: Path, user: str, slug: str, state: dict) -> Path:
    path = state_path(out_dir, user, slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    tmp.replace(path)  # atomic like the indexer's cursor write
    return path
