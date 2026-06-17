"""Shared record shapes for the distiller's JSON-backed state.

These ``TypedDict``s describe the structures the distiller owns and persists:
distilled items (``Item``), per-session outcome records (``SessionRecord``),
normalized model verdicts (``Verdict``), and the per-(user, project) state file
(``State``). They are ``total=False`` where keys accrue across runs (provenance
stamps, optional metadata) so partial dicts still type-check while still naming
every field a reader may touch.

Raw model output -- the ``operations`` and ``session_outcomes`` lists returned
by ``claude -p`` -- is intentionally left as ``dict[str, object]`` (see
``distill.py``): it is untrusted external JSON, validated key-by-key at the
merge boundary rather than trusted to match a fixed shape.
"""

from __future__ import annotations

from typing import TypedDict


class Item(TypedDict, total=False):
    """One distilled ReasoningBank-style lesson, persisted across runs."""

    id: str
    title: str
    body: str
    outcome: str  # success | failure | mixed
    scope: str  # user | shared
    sessions: list[str]
    first_seen: float
    last_updated: float
    # Provenance stamps derived from session metadata; absent until an item has
    # at least one timestamped evidence session.
    evidence_from: float
    evidence_to: float


class SessionRecord(TypedDict, total=False):
    """One judged session's persisted outcome record (``session_outcomes``)."""

    label: str
    reason: str
    goal: str | None
    turns: int
    duration_s: int
    models: list[str]
    errors: int
    corrections: int
    last_ts: float | None


class Verdict(TypedDict):
    """Normalized per-session verdict: a closed label plus a one-line reason."""

    label: str
    reason: str


class Row(TypedDict):
    """One row of the 9-column corpus parquet contract (see ``corpus.py``)."""

    external_id: str
    source: str
    content_hash: str
    title: str | None
    url: str | None
    host: str | None
    timestamp: int | None
    body: str
    meta_json: str


class State(TypedDict):
    """Per-(user, project) distillation state persisted as JSON."""

    project: str | None
    items: list[Item]
    # session id -> fingerprint of the last-distilled revision of that session.
    distilled_sessions: dict[str, str]
    session_outcomes: dict[str, SessionRecord]
