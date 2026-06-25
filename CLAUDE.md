# spotify-sanitizer — project guide for Claude Code

A native macOS app (MIT, Thimo Jansen) that tidies a Spotify "Liked Songs"
library: dedup, drop unplayable tracks, and suggest completing partially-liked
albums. Self-contained SwiftUI + Swift Package Manager, no Xcode required to
build. Started 2026-06-25; ported from a Ruby CLI to native Swift on 2026-06-26.

This is a **public repo**. Code, comments, and commits are world-readable —
keep them clean and free of personal data or secrets.

## Golden rule: scan is read-only, apply mutates

The whole safety model is the two-phase split. Do not blur it.

- **Scan** only reads the library and builds a reviewable `Plan` in memory.
- **Apply** is the *only* path that mutates the library, and it always writes a
  reversal log so **Undo** can revert it.

If you add a feature, decide which side of that line it sits on and keep it there.

## Architecture

```
Package.swift                Swift Package Manager manifest (3 targets)
Sources/
  SanitizerKit/              the engine — no UI. Only `Engine` is public.
    Config.swift             ~/.config/spotify-sanitizer — client_id + token cache
    Auth.swift               OAuth Authorization Code + PKCE; NWListener loopback catcher; refresh
    Client.swift             Web API over URLSession: bearer, pagination, 429 fail-fast
    Library.swift            fetch liked tracks + album tracklists + ISRC search
    Track.swift              flattened track; skit?; fuzzyKey for dedup; artwork + spotify url
    Analyzer.swift           THE BRAIN — turns tracks into a Plan. Tunable knobs in Options.
    Apply.swift              executes a plan; writes reversal log; undo inverts it
    Plan.swift               the reviewable artifact + Card (display record)
    Engine.swift             public façade: login / scan / apply / undo
    Concurrency.swift        boundedMap — bounded-parallel fetch helper
    Progress.swift           ScanProgress for the UI
    Log.swift                file logging to logs/app.log (+ os.Logger), self-trimming
    SelfTest.swift           in-Kit analyzer tests (XCTest needs full Xcode, absent)
  SpotifySanitizer/          the SwiftUI app — thin front-end over Engine
    App.swift, AppModel.swift, ContentView.swift
  sanitizer-verify/          headless runner: --selftest, or a live scan
build-app.sh                 assembles a double-clickable .app around the release binary
```

Data flow: `Engine.scan` → `Library` → `[Track]` → `Analyzer.buildPlan` → `Plan`
→ (user reviews/unticks in the UI) → `Engine.apply`.

## The heuristics live in one place

`Analyzer.Options` and the keeper-preference logic in `Analyzer.rankKey` /
`duplicateReason` are the only "opinionated" code. When tuning behavior, that's
where to look.

- **Keeper preference**: playable > explicit > album-type (album>single>compilation)
  > earliest `addedAt`.
- **Dedup clustering**: `Track.fuzzyKey` — normalized artist + title (remaster/
  version cruft stripped) + coarse duration bucket. Track IDs are always unique,
  so clustering is the point.
- **Skits**: `Track.isSkit` — short or titled skit/interlude/etc. Excluded from
  album-completion math, never proposed for addition.
- **Album completion** is always a suggestion, never automatic.
- **ISRC alternatives** (`Library.findAlternative`, opt-in): match on ISRC **and**
  duration (±3s) — Spotify's catalog has recycled ISRCs, so duration guards them.

## Spotify gotchas (learned the hard way against the live API)

- **Bring-your-own Client ID is mandatory.** Spotify caps a shared app at 5
  manually-allowlisted users unless you're a 250k-MAU business (Extended Quota,
  ~6-week review). So each user registers their own free app.
- **Search `limit` max is 10**, not the documented 50 (>10 → 400).
- **`market=from_token` on /search needs the `user-read-private` scope** (it works
  on /me/tracks without it). All three scopes are requested at login.
- **429 Retry-After is in seconds and can be hours.** Don't sleep on long ones —
  `Client` auto-retries cool-downs ≤90s and throws `rateLimited` otherwise.
  Avoid hammering the API with repeated full scans while developing.

## Tests

```sh
swift run sanitizer-verify --selftest   # pure analyzer checks, no network
swift run sanitizer-verify              # live scan; prints plan stats + timing
```

Self-tests live in `SelfTest.swift` (not XCTest — XCTest needs full Xcode, which
isn't installed here). Keep logic testable by pushing decisions into
`Analyzer`/`Track` (pure) and out of the network layer; the analyzer takes a
`LibraryProviding` so the library can be stubbed.

## Conventions

- Swift toolchain only (Command Line Tools is enough). SwiftUI + Foundation +
  Network + CryptoKit + OSLog from the SDK; no third-party packages.
- `Engine` is the only public type in `SanitizerKit`; keep the rest internal.
- Commit author `thimo@defrog.nl`, no `Co-Authored-By` trailer. Commit only when
  asked; **never push** — Thimo controls all pushes.
- Never commit anything containing the user's library data (`.gitignore` excludes
  `plans/`, `logs/`).
- Build/verify after changes: `swift build` and `sanitizer-verify --selftest`.
  Don't run live scans gratuitously — see the 429 note above.

## Status / next steps

- Native Swift port complete; engine verified at parity with the old Ruby output
  (3331 tracks → 166 dup, 53 unplayable, 145 additions, 1139 albums).
- Open polish: app icon + code signing (currently generic icon, unsigned);
  offset-based parallel library fetch (the page-by-page liked-songs fetch is the
  remaining sequential floor) — but test it gently to avoid rate limits.
