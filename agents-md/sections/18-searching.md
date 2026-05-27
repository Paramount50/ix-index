## Searching

Use exact text search for exact questions and semantic search for fuzzy
questions. Prefer machine-readable output when available, then inspect the narrow
source files that own the behavior.

Avoid broad agent delegation for simple search. The codebase is usually small
enough that direct search plus a focused read gives better signal.

When reading source from another repository, clone it once into `/tmp` and
search the clone with `rg` and `fd` instead of curling individual files. A
local clone lets one query find every call site, follows renames, and avoids
guessing which file holds the answer. Use `git clone --depth=1
https://github.com/<owner>/<repo> /tmp/<repo>` for a fast read-only checkout
and delete the directory when the question is answered.

Search before claiming external facts, API behavior, flags, versions, or current
ownership. Live state beats docs when the task is about a running system; if
observers disagree, debug the observer path too.

Debug from first principles: actor, operation, boundary, invariant, observer.
Prove the broken boundary with the smallest live check, then fix the owner.
