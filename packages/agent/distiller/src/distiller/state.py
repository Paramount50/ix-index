"""Per-(user, project) distillation state: items, session verdicts, seen set.

State lives under ``<out>/state/<user>/<project_slug>.json`` and is what makes
the run incremental: items carry stable ids across runs, and a session is
re-distilled only when its fingerprint (message count + last timestamp)
changed since the previous run.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import cast

from .types import State


def state_path(out_dir: Path, user: str, slug: str) -> Path:
    return out_dir / "state" / user / f"{slug}.json"


def _empty() -> State:
    return {"project": None, "items": [], "distilled_sessions": {}, "session_outcomes": {}}


def load(out_dir: Path, user: str, slug: str) -> State:
    path = state_path(out_dir, user, slug)
    if not path.is_file():
        return _empty()
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    # The file is external (a prior run's output, possibly hand-edited); fill in
    # any keys an older schema omitted before trusting the State shape.
    data.setdefault("project", None)
    data.setdefault("items", [])
    data.setdefault("distilled_sessions", {})
    data.setdefault("session_outcomes", {})
    return cast(State, data)


def save(out_dir: Path, user: str, slug: str, state: State) -> Path:
    path = state_path(out_dir, user, slug)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    tmp.replace(path)  # atomic like the indexer's cursor write
    return path
