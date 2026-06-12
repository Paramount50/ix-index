# astlog

Datalog over tree-sitter syntax trees: tree-sitter query matches become
relations, Datalog rules join them, and rewrites turn derived rows into edits.

Pattern tools (ast-grep, Semgrep, tree-sitter queries) answer "does this node
match this shape". The questions that actually need answering during a
migration or audit are joins: *an `unwrap()` call **inside a function whose
return type is `Result`***, or *a call passing a variable **that was assigned
from `getenv`***. The first is a join on tree position, the second a join on
identifier text across two unrelated subtrees. astlog makes both one rule.

## The language

A rules file is S-expressions, three forms:

```lisp
;; tree-sitter query matches become relations: one row per match,
;; one column per @capture
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

;; the join: shared variables across body atoms, exactly like columns
;; shared across SQL tables; `ancestor` is a structural builtin
(rule (fixable call e)
  (unwrap-call call e)
  (result-fn f)
  (ancestor f call))

;; derived rows become edits: replace the target node with a template
;; splicing bound variables
(rewrite unwrap-to-try (fixable call e)
  (replace call "{e}?"))
```

Rules may be recursive (`(rule (up x z) (up y z) (parent x y))`); every value
is a syntax node or text derived from one, so the universe is finite and
naive fixpoint iteration terminates. Builtins: `ancestor`, `parent` (tree
position), `text`, `kind`, `same-text` (values), `same-file`. Negation and
aggregates are deliberately absent in v0.

Because patterns are verbatim tree-sitter queries, `Query::new` validates
node kinds and field names against the grammar at load: a misspelled node
kind is a hard error with a position, never a silently empty result. `#`
predicates (`#eq?` etc.) are rejected with guidance to use builtins, which
the Datalog layer subsumes.

## Surfaces

- **Library**: `astlog-core` (this directory's `core/`), the only place with
  logic.
- **CLI**: `astlog query rules.astlog src/ [--relation r] [--json] [--deny r]`
  and `astlog fix rules.astlog src/ [--write]`. `--deny` exits nonzero when a
  relation derived rows, which turns a rules file into a CI lint gate.
- **Python**: `import astlog` in the ix kernel (bundled like `search`/`tui`);
  `astlog.query(rules, paths)`, `astlog.fixes(...)`, `astlog.fix(...,
  write=True)`. Bindings are conversion-only.

Languages come from `ast-merge-langs`: every grammar that crate registers
(Rust, Python, TypeScript, Go, Nix, ...) works here, detected by file
extension, named in `(match <lang> ...)` by profile name or extension.

## Prior art

This composes ideas that each exist somewhere, but not together:

| Project | What it has | What it lacks for this use |
| --- | --- | --- |
| [treeedb](https://github.com/langston-barrett/treeedb) | tree-sitter ASTs as Soufflé Datalog relations | selection only, no rewriting; Soufflé toolchain; unmaintained since ~2022 |
| [Logifix](https://github.com/lyxell/logifix) | Datalog-driven rewriting (the closest in spirit) | Java only; rules compiled with Soufflé, not loaded at runtime |
| [ql-grep](https://github.com/travitch/ql-grep) | CodeQL syntax over tree-sitter | selection only, no rewriting |
| [CodeQL](https://codeql.github.com) | the relational model done at depth (real dataflow) | heavyweight extraction per language; not embeddable; no rewriting |
| [ast-grep](https://ast-grep.github.io) | patterns-as-code + rewrites, `inside`/`has` constraints | constraints are structural-only: no value joins, no recursion, no cross-pattern joins |
| [GritQL](https://github.com/biomejs/gritql) | pattern language with `where` clauses + rewrites | same: no general relational layer |
| [Semgrep](https://semgrep.dev) / [Coccinelle](https://coccinelle.gitlabpages.inria.fr/website/) | metavariable patterns; Coccinelle's diff-style patches | per-language engines; constraint layer is ad hoc, not Datalog |
| [weggli](https://github.com/weggli-rs/weggli) | C/C++ sketches over tree-sitter | C/C++ only, selection only |
| [Glean](https://glean.software) (Angle) | code facts queried relationally at scale | an indexing service, not an embeddable rewriter |

The gap astlog fills: **tree-sitter patterns as relations + runtime Datalog
joins (positional, by value, recursive) + rewriting, embeddable as a library
with CLI and Python bindings.**

## Built from scratch vs reused

Deliberately reused, because rebuilding any of these is the classic trap:

- **Parsing and grammars**: tree-sitter plus the ~28 grammar crates already
  in this workspace via `ast-merge-langs`, including language detection.
- **Matching**: tree-sitter's own `Query` engine is the pattern matcher;
  astlog never walks trees to match shapes. Grammar-validated queries
  (typo = load error) come free with it.
- **Plumbing**: `ignore` (gitignore-aware walking), `similar` (diffs),
  `clap`, `snafu`, pyo3, and the repo's cargo-unit/Nix/kernel-bundling
  infrastructure.

Deliberately written here, after evaluating the alternatives:

- **The Datalog evaluator** (~300 lines, naive fixpoint, nested-loop joins).
  `ascent`/`crepe` fix rules at Rust compile time (ours load from a file at
  runtime); `datafrog` wants statically-typed tuple relations and
  hand-written join plans, so the dynamic binding layer would have to be
  written anyway; Soufflé is an external C++ codegen toolchain, the wrong
  shape for an embedded library; `cozo` would work but imposes CozoScript as
  the user language plus a database's worth of dependency for features
  (persistence, vectors) this never uses. At single-repo scale the engine is
  trivial; the DSL boundary is the part worth owning. If rule sets outgrow
  naive evaluation, swapping datafrog or cozo underneath does not change the
  language.
- **The relation boundary and builtins**: captures → rows, `ancestor`/
  `parent`/`text`/`kind`/`same-text`/`same-file`, template splicing. This
  glue is the product; nothing ships it.
- **The S-expr reader** (~150 lines): `lexpr` exists, but per-form line
  numbers drive every diagnostic here and the reader is trivial.

## v0 limitations (deliberate)

- Naive (not semi-naive) fixpoint; fine at repo scale, measured before
  optimized.
- No negation, no aggregates, no stratification to get wrong.
- A quantified capture (`+`/`*`) contributes its first node per match.
- `ancestor`/`parent` need their lower argument bound by atoms to their left
  (left-to-right evaluation), and report exactly that when violated.

## Planned

- Port the repo's ast-grep lint rules (`ast-grep/nix/rules/*.yml`) to astlog
  rules and gate them in `nix run .#lint` via `astlog query --deny`, replacing
  the ast-grep scanner with one expressed in this relational model.
- A concrete-syntax pattern front end (`$X.unwrap()` style, likely via
  `ast-grep-core`) compiling into the same relations, so simple rules need no
  tree-sitter query vocabulary.
