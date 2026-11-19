# Contributing to AIS Scoops

Thanks for helping the Scoops grow! 🐣 Bug reports, docs, translations and code are all welcome. Small pull requests
that do one thing are the easiest to review.

## Before you start

- **Bugs:** open an [issue](../../issues/new/choose) with steps to reproduce, versions and logs (remove private data).
- **Bigger changes:** open an issue or a discussion first, so we can agree on the approach before you spend a weekend
  on it.
- **Security problems:** never in public. See [SECURITY.md](SECURITY.md).

## Project layout

| Part | Folder | Run the tests |
|---|---|---|
| Server (Python 3.12, uv) | `Server/` | `Server/bin/test` (all) or `Server/bin/test sharing` (one file) |
| Apps (SwiftUI, XcodeGen) | `App/` | `xcodebuild test -scheme WatchLogicTests -destination 'platform=macOS'` |
| Cloud (Convex, TypeScript) | `Cloud/` | `npm test` and `npm run typecheck` |

The tests need no network and no real keys. Fakes for the AI programs and MCP servers live in `Server/tests/`.
`Server/tests/probelauf.py` is a longer end-to-end run against a live server with real models. You don't need it for
a pull request.

## Development setup

```sh
# Server
cd Server && uv sync
AISBOT_EDITION=standard AISBOT_HOME="$PWD/.dev" uv run aisbot serve

# Apps
cd App && xcodegen generate && open AISBot.xcodeproj
# launch argument -mock: demo data, no server needed

# Cloud
cd Cloud && npm install && npm test
```

Use `AISBOT_EDITION=standard`. The default `personal` edition contains integrations that only exist on the
maintainer's machines (phone assistant, team app, coding agents) and switches them on.

For signing, set your own `DEVELOPMENT_TEAM` and bundle IDs in `App/project.yml` and run `xcodegen generate` again.
Please don't commit those changes.

## Conventions

- **Language.** The product, the prompts, most comments and the docs are German, because that's where Scoops started.
  New code may use English or German. Stay consistent within a file. User-facing text must work in both languages
  in the long run, so new strings should be easy to localize.
- **Python:** type hints, small functions, standard library first. Every behavior change gets a check in
  `Server/tests/`.
- **Swift:** Swift 6 with strict concurrency, SwiftUI first, no third-party UI libraries. Keep previews and the
  `-mock` demo data working when you change views.
- **Safety first.** Anything that acts outside the server (sending, posting, paying, deleting, running commands)
  must go through the existing approval flow. Never log, print or store secrets, subscription logins or tokens.
  `Server/tests/test_abos.py` checks parts of this automatically.
- **API changes** go into `docs/API.md` in the same pull request.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Make your change and add tests.
3. Run the tests for the parts you touched.
4. Open the pull request and fill in the template. Screenshots or a short video help a lot for UI changes.

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), as described
in section 5 of the license. There's no extra CLA.
