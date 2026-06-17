"""Type stub for the PyO3 extension module backing `scipql`.

Hand-maintained to mirror packages/code/scipql/py/src/lib.rs. Keep in sync when
changing the binding. The public `scipql` API (`__init__.py`) lowers these dict
shapes into polars DataFrames.
"""

from typing import TypedDict

__version__: str


class Occurrence(TypedDict):
    """One `occurrence` fact: a symbol use site with its byte range and role."""

    symbol: str
    path: str
    start: int
    end: int
    role: str


class SymbolInfo(TypedDict):
    """One `symbol_info` fact: a symbol's kind and display name."""

    symbol: str
    kind: str
    display_name: str


class Document(TypedDict):
    """One `document` fact: an indexed source path."""

    path: str


class Relationship(TypedDict):
    """One `relationship` fact: a typed edge between two symbols."""

    symbol: str
    related: str
    kind: str


class Facts(TypedDict):
    """The four fact relations a SCIP index lowers into."""

    occurrence: list[Occurrence]
    symbol_info: list[SymbolInfo]
    document: list[Document]
    relationship: list[Relationship]


class Relation(TypedDict):
    """One Soufflé `.output` relation: its column names and untyped string rows."""

    columns: list[str]
    rows: list[dict[str, str]]


def index(project: str, output: str = ...) -> str:
    """Run rust-analyzer's SCIP indexer over ``project``; return the output path."""
    ...


def facts(index_path: str, root: str | None = ...) -> Facts:
    """Lower a SCIP index into its four fact relations (see ``scipql.facts``)."""
    ...


def query(index_path: str, program: str, root: str | None = ...) -> dict[str, Relation]:
    """Run a Soufflé ``program``; return one relation per ``.output`` declaration."""
    ...


def fix(index_path: str, program: str, root: str | None = ..., write: bool = ...) -> str:
    """Apply a ``fix`` program's ``edit`` relation; return the unified diff."""
    ...


def rename(
    index_path: str,
    selector: str,
    new_name: str,
    root: str | None = ...,
    write: bool = ...,
) -> str:
    """Rename every occurrence whose moniker ends with ``selector``; return the diff."""
    ...
