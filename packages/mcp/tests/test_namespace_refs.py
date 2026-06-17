"""Namespace reference tracking: which runs assigned/used each variable.

The runtime records, per finished job, the names its *source* binds and references
(``runtime._record_refs`` -> ``introspect.binding_names``) into ``_name_refs``, and
``_namespace_snapshot`` hands that registry to ``introspect.namespace_rows`` so the
dashboard's namespace pane can link a variable back to the runs behind it. These
tests pin the accumulation contract: dedup, recency order, the per-name cap, and
that source-based attribution is what reaches the rows (so it stays correct even
when many background jobs share one namespace concurrently — no after-the-fact
namespace diff that would misattribute one job's writes to another).
"""

from __future__ import annotations

import types

from ix_notebook_mcp import introspect, runtime


def _job(job_id: str, code: str, status: str = "done") -> types.SimpleNamespace:
    """A minimal stand-in for a finished Job: _record_refs reads id, code, status."""
    return types.SimpleNamespace(id=job_id, code=code, status=status)


def _reset() -> None:
    runtime._name_refs.clear()


def test_record_refs_splits_assigned_and_used() -> None:
    _reset()
    runtime._record_refs(_job("j1", "x = a + 1"))
    assert runtime._name_refs["x"]["assigned_in"] == ["j1"]
    assert runtime._name_refs["a"]["used_in"] == ["j1"]
    # `a` was only read, `x` only written.
    assert runtime._name_refs["a"]["assigned_in"] == []
    assert runtime._name_refs["x"]["used_in"] == []


def test_refs_accumulate_across_runs_deduped_and_recency_ordered() -> None:
    _reset()
    runtime._record_refs(_job("j1", "x = 1"))
    runtime._record_refs(_job("j2", "x = 2"))
    runtime._record_refs(_job("j1", "x = 3"))  # j1 again: moves to most-recent
    # Deduped, most-recent-last.
    assert runtime._name_refs["x"]["assigned_in"] == ["j2", "j1"]


def test_per_name_cap_keeps_most_recent() -> None:
    _reset()
    cap = runtime._MAX_REFS_PER_NAME
    for i in range(cap + 5):
        runtime._record_refs(_job(f"j{i}", "x = 1"))
    got = runtime._name_refs["x"]["assigned_in"]
    assert len(got) == cap
    # The oldest were dropped; the most-recent cap ids survive, in order.
    assert got == [f"j{i}" for i in range(5, cap + 5)]


def test_refs_reach_namespace_rows() -> None:
    _reset()
    runtime._record_refs(_job("j1", "total = base"))
    runtime._record_refs(_job("j2", "print(total)"))
    rows = introspect.namespace_rows({"total": 42}, refs=runtime._name_refs)
    row = {r["name"]: r for r in rows}["total"]
    assert row["assigned_in"] == ["j1"]
    assert row["used_in"] == ["j2"]


def test_unparseable_run_records_nothing() -> None:
    _reset()
    runtime._record_refs(_job("j1", "def ((("))
    assert runtime._name_refs == {}


def test_failed_run_is_not_credited() -> None:
    # A run that errors may never have reached its bindings (`x = undefined()`
    # raises before binding x), so a non-"done" run contributes no references — we
    # under-attribute rather than claim a failed run set a value it did not.
    _reset()
    runtime._record_refs(_job("ok", "x = 1"))
    runtime._record_refs(_job("boom", "x = undefined_func()", status="error"))
    runtime._record_refs(_job("killed", "x = slow()", status="cancelled"))
    # Only the clean run is credited.
    assert runtime._name_refs["x"]["assigned_in"] == ["ok"]


if __name__ == "__main__":
    # Runnable without pytest (the suite is not yet wired into a pytest check).
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
    print(f"{len(fns)} passed")
