# Spotify Sanitizer — macOS app

A self-contained native SwiftUI front-end for the sanitizer. The whole engine
(OAuth PKCE, Spotify Web API, the dedup/curation analyzer) is ported to Swift in
`SanitizerKit`, so the app needs no Ruby at runtime — it shares only the on-disk
token cache (`~/.config/spotify-sanitizer`) with the CLI.

## Layout

```
Sources/
  SanitizerKit/        the engine (Config, Auth, Client, Library, Track, Analyzer, Apply, Engine)
  SpotifySanitizer/    the SwiftUI app (App, AppModel, ContentView)
  sanitizer-verify/    headless runner: --selftest, or a live scan
```

`Engine` is the only public surface; the UI and runner talk to it and nothing else.

## Build & run

Requires the Swift toolchain (Command Line Tools is enough — no full Xcode).

```sh
swift run SpotifySanitizer          # run the app directly
./build-app.sh                      # build a double-clickable SpotifySanitizer.app
open SpotifySanitizer.app
```

First-run auth: if you've already used the Ruby CLI's `login`, the app reuses
those tokens. Otherwise press **Log in** — it opens Spotify in your browser and
catches the redirect on `127.0.0.1:8888`, same as the CLI. A Client ID must be
configured (via the CLI `login --client-id=…` or `SPOTIFY_CLIENT_ID`).

## Verify the engine

```sh
swift run sanitizer-verify --selftest    # pure analyzer checks (mirrors test_analyzer.rb)
swift run sanitizer-verify               # live scan; prints plan stats
```

The same two-phase safety model holds: scanning is read-only; **Apply** is the
only step that changes your library, and it writes a reversal log so **Undo**
works (interoperable with the CLI's `undo`).
