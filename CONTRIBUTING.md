# Contributing to Lotus

Thank you for helping. This page says what to open (an issue, a pull
request, or a security report), what a pull request needs, and what the
maintainers keep for themselves. How to set up Lotus, start its databases
and find your way around the code is in the
[contribution guide](guides/contributing.md).

## Questions, bugs and ideas

- **A bug.** Open an issue with the bug report form. The smallest query,
  data source and configuration that show it are the most useful thing
  you can give.
- **An idea or a change of behaviour.** Open an issue with the feature
  request form, and say the problem before the solution.
- **A security problem.** Do not open an issue. See
  [SECURITY.md](SECURITY.md).

Search the open and closed issues first: the idea may already be planned,
or turned down for a reason given there.

## When a pull request needs an issue first

Open an issue, and agree on the change there, before a pull request that:

- adds a feature, an option, a callback or a source adapter;
- changes what Lotus does, or its public API;
- adds a dependency;
- touches many files, or needs a design decision.

A pull request does not need an issue when it is small and its reason is
plain from the diff: a typo, a broken link, a wrong sentence in a guide,
or a bug fix with a test that fails without it. When in doubt, open the
issue: a short discussion costs less than a pull request that is not
merged.

A pull request with an issue says so: `Fixes #123` or `Closes #123`.

## A pull request

- **One change.** A fix, the guides for an unrelated case and a README
  edit are three pull requests. Each is reviewed, reverted and released
  on its own.
- **Why, not only what.** The description says the problem the change
  solves, for whom, and what happened before it: an error, a wrong
  result, a slow query.
- **Tests.** A bug fix has a test that fails on `main` and passes with
  the fix. A feature has tests of what it does, and of its errors. A
  change to SQL handling is tested on PostgreSQL, MySQL and SQLite.
- **Docs.** A change a user can see updates the guide it belongs to and
  an `## [Unreleased]` section at the top of [CHANGELOG.md](CHANGELOG.md)
  (add the heading if it is not there yet).
- **The checks pass.** CI runs them on Elixir 1.18, 1.19 and 1.20, with
  PostgreSQL and MySQL running; run them first:

  ```sh
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix credo --strict
  mix test.setup
  mix test
  mix test --only cluster   # needs epmd: epmd -daemon
  mix dialyzer
  ```

  `docker compose up -d` starts the databases the tests expect; the
  [contribution guide](guides/contributing.md#database-services) has the
  ports and credentials.

Commit messages and pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/), as the
guide describes. The pull request template has these as a checklist.

## What the maintainers keep

- **Benchmarks.** Numbers from the scripts in `bench/` depend on the
  machine they ran on, so a pull request does not add or change published
  numbers. If a change is about speed, put your own numbers in its
  description, with your machine and the script you ran.
- **Releases.** The version in `mix.exs`, the release headings of the
  changelog and the tags are changed by the maintainers, at a release.

## Style

Match the code around your change: its naming, its comments and the way
its guides are written. `mix format` and `mix credo --strict` settle the
rest.

## License

By contributing, you agree that your contribution is released under the
MIT License of the project (see [LICENSE](https://github.com/elixir-lotus/lotus/blob/main/LICENSE)).
