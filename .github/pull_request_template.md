## Why

<!-- The problem this solves, for whom, and what happened before it (an error, a wrong result, a slow query). -->

Fixes #<!-- the issue; needed only for bigger changes, see CONTRIBUTING.md -->

## What

<!-- The change, in a few lines. -->

## How it was tested

<!-- The tests added, the databases they ran on, and what you ran by hand. -->

## Checklist

- [ ] One change: anything unrelated is in its own pull request.
- [ ] A bug fix has a test that fails on `main` and passes here.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` and `mix dialyzer` pass.
- [ ] `mix test` passes with PostgreSQL, MySQL and SQLite (`docker compose up -d`), and `mix test --only cluster` for a change to caching.
- [ ] The guides and the `[Unreleased]` section of `CHANGELOG.md` are updated, for a change a user can see.
- [ ] Says so here if it changes the public API or what Lotus does today.
- [ ] No changes to the version or to benchmark numbers (the maintainers keep those).
