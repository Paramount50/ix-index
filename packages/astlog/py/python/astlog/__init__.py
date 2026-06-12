"""Datalog over tree-sitter ASTs: query relations, join them, apply rewrites.

A rules program turns tree-sitter query matches into relations (one row per
match, columns named by ``@capture``), joins them with Datalog rules
(structurally via ``ancestor``/``parent``/``same-file``, by value via
``text``/``same-text``/``kind``, or recursively), and turns derived rows into
edits with ``(rewrite ...)`` templates::

    import astlog

    RULES = '''
    (rule (unwrap-call call e)
      (match rust "
        (call_expression
          function: (field_expression value: (_) @e field: (field_identifier) @m)
          arguments: (arguments)) @call")
      (text m "unwrap"))

    (rule (result-fn f)
      (match rust "
        (function_item return_type: (generic_type type: (type_identifier) @r)) @f")
      (text r "Result"))

    (rule (fixable call e)
      (unwrap-call call e)
      (result-fn f)
      (ancestor f call))

    (rewrite unwrap-to-try (fixable call e)
      (replace call "{e}?"))
    '''

    rows = astlog.query(RULES, ["src/"])          # {relation: [{column: value}]}
    edits = astlog.fixes(RULES, ["src/"])         # [{path, start, end, replacement}]
    print(astlog.fix(RULES, ["src/"]))            # unified diff (write=True applies)

A node value is a dict with ``path``, ``kind``, ``start``/``end`` (bytes),
``line``/``column`` (1-based), and ``text``; derived text values are plain
strings. Directories are walked gitignore-aware; the language of each file is
detected from its extension. The same engine backs the ``astlog`` CLI.
"""

from __future__ import annotations

from ._astlog import __version__, fix, fixes, query

__all__ = ["__version__", "fix", "fixes", "query"]
