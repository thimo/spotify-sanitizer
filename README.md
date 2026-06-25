# spotify-sanitizer

Obsessively tidy your Spotify "Liked Songs" library.

Over the years a liked-songs library accumulates cruft: the same song liked
twice, the clean version *and* the explicit one, a track from the album *and*
the same track from a greatest-hits compilation, songs that have gone
unplayable in your country. `spotify-sanitizer` finds that mess and proposes a
fix — but never touches your library until you've reviewed the plan.

## What it does

- **Dedup** — collapses "same recording, different release" down to one copy.
  When it has to choose which copy to keep, it prefers, in order:
  1. playable over unplayable
  2. **explicit over clean**
  3. album over single over compilation
  4. (tie-break) the copy you liked first
- **Drop unplayable tracks** — the greyed-out ones that no longer play in your market.
- **Complete albums** — if you already like most of an album, it suggests liking
  the rest *as a proposal*, so your library trends toward whole albums instead of
  scattered cherry-picks.
  - **Skits are respected.** Short tracks and ones titled *skit / interlude /
    intro / outro / …* are excluded from the "is this album complete?" math and
    are never suggested for adding — so deliberately dropping the junk doesn't
    trigger a nag, and "complete" means "every track you'd actually want."

Everything is a **suggestion in a reviewable plan**. The heuristics will
occasionally be wrong about a song you deliberately dropped — you see and edit
the plan before anything happens.

## Safety model

1. `scan` is **read-only**. It writes a `plan.json` (+ readable `.txt`) and changes nothing.
2. You **review** the plan. Delete any entry you disagree with from the JSON.
3. `apply` executes the reviewed plan and writes a **reversal log**.
4. `undo` reverts any applied run from its log.

## Setup

Requires Ruby ≥ 3.0 (standard library only — no gems needed to run).

1. Create a free app at <https://developer.spotify.com/dashboard>.
2. In the app settings, add this Redirect URI:
   ```
   http://127.0.0.1:8888/callback
   ```
3. Save your Client ID and authorize:
   ```sh
   bin/spotify-sanitizer login --client-id=YOUR_CLIENT_ID
   ```
   A browser opens; approve the `user-library-read` + `user-library-modify` scopes.

Config and tokens are stored under `~/.config/spotify-sanitizer/`
(override with `SPOTIFY_SANITIZER_HOME`). Tokens never leave your machine.

## Usage

```sh
# Build a cleanup plan (read-only)
bin/spotify-sanitizer scan

# Tune the heuristics
bin/spotify-sanitizer scan --threshold=0.8 --skit-seconds=45 --no-complete-albums

# Review the printed plan / the files in ./plans, then:
bin/spotify-sanitizer apply plans/20260625-120000.plan.json

# Changed your mind:
bin/spotify-sanitizer undo ~/.config/spotify-sanitizer/logs/apply-20260625-120500.json
```

## How dedup decides two tracks are "the same"

Spotify track IDs are always unique, so a naïve "same ID" check finds nothing.
Instead, tracks are clustered by a fuzzy key: normalized primary-artist + title
(with remaster/version/live cruft stripped) + a coarse duration bucket. That
collapses an album cut, its single release, and its remaster into one cluster,
while keeping genuinely different songs apart. Within each cluster, the keeper
is chosen by the preference rules above.

This is a heuristic. That's exactly why `scan` and `apply` are separate steps.

## License

MIT © Thimo Jansen
