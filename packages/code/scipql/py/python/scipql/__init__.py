"""Soufflé datalog + find/replace over a SCIP semantic index.

Unlike ``astlog`` (datalog over tree-sitter syntax), the facts here are keyed by
SCIP *monikers*, so a query distinguishes two same-named symbols in different
modules and a rename touches only the real definition and its references::

    import scipql

    scipql.index("/path/to/crate", "index.scip")     # run rust-analyzer scip
    f = scipql.facts("index.scip")                    # {relation: pl.DataFrame}

    # Arbitrary Soufflé over the facts (occurrence/symbol_info/document/
    # relationship are in scope); returns one DataFrame per `.output` relation.
    RULES = '''
    .decl dead(sym:symbol, path:symbol)
    .output dead
    dead(s, p) :- occurrence(s, p, _, _, "definition"), !occurrence(s, _, _, _, "reference").
    '''
    out = scipql.query("index.scip", RULES)           # {"dead": pl.DataFrame}

    # A `fix` program emits edit(path, start, end, replacement); dry-run by
    # default, write=True applies. `rename` is a built-in fix.
    print(scipql.rename("index.scip", "net/Socket#", "Stream"))         # diff
    scipql.rename("index.scip", "net/Socket#", "Stream", write=True)    # apply

Results come back as polars DataFrames, like every other bundled kernel module.
``index``/``fix``/``rename`` return plain ``str`` (a path, or a unified diff).
The same engine backs the ``scipql`` CLI.
"""

from __future__ import annotations

import polars as pl

from ._scipql import __version__, index
from ._scipql import facts as _facts
from ._scipql import fix as _fix
from ._scipql import query as _query
from ._scipql import rename as _rename

__all__ = ["__version__", "facts", "fix", "index", "query", "rename"]

# A polars dtype as `pl.DataFrame(schema=...)` accepts it: the class (`pl.Utf8`)
# or an instance. The schema tables below hold the classes.
_DType = type[pl.DataType] | pl.DataType

# Column dtypes for each fact relation; byte offsets are integers, everything
# else is a moniker/identifier string.
_FACT_SCHEMAS: dict[str, dict[str, _DType]] = {
    "occurrence": {
        "symbol": pl.Utf8,
        "path": pl.Utf8,
        "start": pl.Int64,
        "end": pl.Int64,
        "role": pl.Utf8,
    },
    "symbol_info": {"symbol": pl.Utf8, "kind": pl.Utf8, "display_name": pl.Utf8},
    "document": {"path": pl.Utf8},
    "relationship": {"symbol": pl.Utf8, "related": pl.Utf8, "kind": pl.Utf8},
}


def facts(index_path: str, root: str | None = None) -> dict[str, pl.DataFrame]:
    """Lower a SCIP index into one DataFrame per fact relation.

    ``root`` resolves relative document paths for byte offsets; it defaults to
    the index's project root.
    """
    raw = _facts(index_path, root)
    # Pair each relation's row list (typed per-key on the `Facts` TypedDict) with
    # its schema. Listed explicitly rather than indexed by a dynamic name so the
    # rows keep their precise row-dict type instead of widening to `object`.
    relations: dict[str, list[dict[str, object]]] = {
        "occurrence": [dict(row) for row in raw["occurrence"]],
        "symbol_info": [dict(row) for row in raw["symbol_info"]],
        "document": [dict(row) for row in raw["document"]],
        "relationship": [dict(row) for row in raw["relationship"]],
    }
    return {
        name: pl.DataFrame(relations[name], schema=schema)
        for name, schema in _FACT_SCHEMAS.items()
    }


def query(index_path: str, program: str, root: str | None = None) -> dict[str, pl.DataFrame]:
    """Run a Soufflé ``program`` and return one DataFrame per output relation.

    Every cell is a string (Soufflé output is untyped text); the column names
    come from the relation's ``.decl``.
    """
    out: dict[str, pl.DataFrame] = {}
    for name, relation in _query(index_path, program, root).items():
        columns = relation["columns"]
        out[name] = pl.DataFrame(
            relation["rows"],
            schema=dict.fromkeys(columns, pl.Utf8),
        )
    return out


def fix(
    index_path: str,
    program: str,
    root: str | None = None,
    *,
    write: bool = False,
) -> str:
    """Apply a ``fix`` program's ``edit`` relation; return the unified diff.

    Dry-run by default; ``write=True`` rewrites the files on disk.
    """
    return _fix(index_path, program, root, write)


def rename(
    index_path: str,
    selector: str,
    new_name: str,
    root: str | None = None,
    *,
    write: bool = False,
) -> str:
    """Rename every occurrence whose moniker ends with ``selector``.

    Dry-run by default; ``write=True`` applies it.
    """
    return _rename(index_path, selector, new_name, root, write)
