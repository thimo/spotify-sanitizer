# spotify-sanitizer — project guide for Claude Code

Public CLI (MIT, Thimo Jansen) that tidies a Spotify "Liked Songs" library:
dedup, drop unplayable tracks, and suggest completing partially-liked albums.
Ruby, **standard library only** — no runtime gems. Started 2026-06-25.

This is a **public repo**. Code, comments, and commits are world-readable —
keep them clean and free of personal data or secrets.

## Golden rule: scan is read-only, apply mutates

The whole safety model is the two-phase split. Do not blur it.

- `scan` **must never** write to Spotify. It only reads the library and emits a
  reviewable plan (`.plan.json` + `.plan.txt`).
- `apply` is the *only* path that mutates the library, and it must always write a
  reversal log so `undo` can revert it.

If you add a feature, decide which side of that line it sits on and keep it there.

## Architecture

```
bin/spotify-sanitizer        entry point → CLI.start
lib/spotify_sanitizer/
  cli.rb        subcommand dispatch + option parsing (login/scan/apply/undo/status)
  config.rb     ~/.config/spotify-sanitizer/ — client_id + token cache, paths
  auth.rb       OAuth Authorization Code + PKCE; loopback redirect catcher; refresh
  client.rb     Web API over net/http: bearer, pagination (each_page), 429 backoff
  library.rb    fetch liked tracks + album tracklists → Track objects
  track.rb      flattened track; skit? heuristic; fuzzy_key for dedup clustering
  analyzer.rb   THE BRAIN — turns tracks into a Plan. Tunable knobs in DEFAULTS.
  plan.rb       the reviewable artifact: to_h/save_json + to_text
  apply.rb      executes a plan; writes reversal log; undo inverts it
```

Data flow: `Library` → `[Track]` → `Analyzer#build_plan` → `Plan` →
(user reviews) → `Apply#run`.

## The heuristics live in one place

`Analyzer::DEFAULTS` and the keeper-preference logic in `Analyzer#rank` /
`#compare_versions` are the only "opinionated" code. When tuning behavior, that's
where to look — not scattered across modules.

- **Keeper preference** (which copy of a duplicate to keep): playable > explicit >
  album-type (album > single > compilation) > earliest `added_at`.
- **Dedup clustering**: `Track#fuzzy_key` — normalized artist + title (remaster/
  version cruft stripped) + coarse duration bucket. Spotify track IDs are always
  unique, so naïve ID-matching finds nothing; clustering is the point.
- **Skits**: `Track#skit?` — short or titled skit/interlude/intro/outro/etc.
  Excluded from album-completion math, never proposed for addition. This is what
  makes "deliberately dropped the junk" not trigger a nag.
- **Album completion** is always a *suggestion* in the plan, never automatic —
  the user may have dropped a full-length song on purpose.

These are first-guess values. Expect to tune them against a real library.

## Tests

```sh
ruby test/test_analyzer.rb        # pure analyzer logic, no network
```

Analyzer tests use `Factory.saved(...)` to build API-shaped hashes — extend that
factory rather than mocking HTTP. Auth/Client/Library are network-bound; keep
logic testable by pushing decisions into `Analyzer`/`Track` (pure) and out of the
network layer.

## Conventions

- Ruby stdlib only at runtime (`net/http`, `json`, `socket`, `securerandom`,
  `digest`, `set`). Don't add a runtime gem dependency without a real reason.
- `# frozen_string_literal: true` on every file.
- Commit author `thimo@defrog.nl`, no `Co-Authored-By` trailer. Commit only when
  asked; **never push** — Thimo controls all pushes.
- Never commit a plan/log or anything containing the user's library data
  (`.gitignore` already excludes `plans/`, `logs/`, `*.plan.*`).

## Status / next steps

- Scaffold complete, analyzer tests green, CLI runs.
- Not yet run against a real library — needs a Spotify app (Client ID) +
  `login`. First real `scan` is the moment to validate the heuristic knobs.
- Reachable but unproven against the live API: `auth.rb`, `client.rb`,
  `library.rb`, `apply.rb`. The PKCE flow and pagination are written but
  untested end-to-end.
