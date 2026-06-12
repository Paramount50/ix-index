from typing import TypedDict

__version__: str

class Node(TypedDict):
    path: str
    kind: str
    start: int
    end: int
    line: int
    column: int
    text: str

class Edit(TypedDict):
    path: str
    start: int
    end: int
    replacement: str

def query(
    rules: str,
    paths: list[str],
    relation: str | None = None,
) -> dict[str, list[dict[str, Node | str]]]: ...
def fixes(rules: str, paths: list[str]) -> list[Edit]: ...
def fix(rules: str, paths: list[str], write: bool = False) -> str: ...
