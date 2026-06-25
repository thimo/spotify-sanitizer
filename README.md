# spotify-sanitizer

A native macOS app to obsessively tidy your Spotify "Liked Songs" library.

Over the years a liked-songs library accumulates cruft: the same song liked
twice, the clean version *and* the explicit one, a track from the album *and*
the same track from a greatest-hits compilation, songs that have gone
unplayable in your country. `spotify-sanitizer` finds that mess and proposes a
fix — but never touches your library until you've reviewed and approved it.

It's a self-contained SwiftUI app (Swift Package Manager, no Xcode required to
build). The whole engine — OAuth, the Spotify Web API, and the analyzer — is
native Swift; nothing else is needed at runtime.

## What it does

- **Dedup** — collapses "same recording, different release" down to one copy.
  When it has to choose which copy to keep, it prefers, in order:
  1. playable over unplayable
  2. **explicit over clean**
  3. album over single over compilation
  4. (tie-break) the copy you liked first
- **Drop unplayable tracks** — the greyed-out ones that no longer play in your market.
  - With **Find alternatives**, instead of just dropping a dead track it looks up
    the *same recording* (matched by ISRC **and** track length) on a release that
    still plays in your market, and proposes swapping it in.
- **Complete albums** — if you already like most of an album, it suggests liking
  the rest. Short tracks and ones titled *skit / interlude / intro / outro / …*
  are excluded from the "is this album complete?" math and never suggested.

Everything is a **proposal you review** — tick/untick each row before anything happens.

## Safety model

1. **Scan** is read-only. It fetches your library and builds a plan; it changes nothing.
2. You review the plan in the app and untick anything you disagree with.
3. **Apply** executes the approved changes and writes a reversal log.
4. **Undo** reverts the last apply from that log.

## Setup

You need your own free Spotify app (a Client ID). This isn't optional friction:
Spotify only lets a shared app serve >5 users if you're a registered business
with 250k+ monthly active users, so every user brings their own — it works
immediately for you alone, with no review.

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add this Redirect URI: `http://127.0.0.1:8888/callback`
3. Launch the app, paste your Client ID when prompted, and press **Log in**.

Tokens are cached under `~/.config/spotify-sanitizer/` and never leave your machine.

## Build & run

Requires the Swift toolchain (Command Line Tools is enough — no full Xcode).

```sh
swift run SpotifySanitizer     # run the app
./build-app.sh                 # build a double-clickable SpotifySanitizer.app
open SpotifySanitizer.app
```

## How dedup decides two tracks are "the same"

Spotify track IDs are always unique, so a naïve "same ID" check finds nothing.
Instead, tracks are clustered by a fuzzy key: normalized primary-artist + title
(with remaster/version/live cruft stripped) + a coarse duration bucket. That
collapses an album cut, its single release, and its remaster into one cluster,
while keeping genuinely different songs apart. Within each cluster, the keeper
is chosen by the preference rules above.

This is a heuristic — which is exactly why scan and apply are separate steps.

## Layout

```
Sources/
  SanitizerKit/        the engine (Config, Auth, Client, Library, Track, Analyzer, Apply, Engine)
  SpotifySanitizer/    the SwiftUI app (App, AppModel, ContentView)
  sanitizer-verify/    headless runner: --selftest, or a live scan
```

`Engine` is the only public surface; the UI and runner talk to it and nothing else.

```sh
swift run sanitizer-verify --selftest   # pure analyzer checks, no network
swift run sanitizer-verify              # live scan; prints plan stats
```

## License

MIT © Thimo Jansen
