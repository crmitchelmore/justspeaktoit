# Principles

- Prefer reusable helpers, explicit ownership boundaries, and behavioural verification over clever one-offs.
- Require a believable test or verification story for anything user-facing or operationally important.
- Push for explicit handling of escaping, edge cases, and failure modes when correctness bugs are common.
- Reuse the repository's existing utilities and patterns instead of spreading similar logic across new places.
- When another role raises a new constraint, translate it into the cleanest maintainable implementation shape.
