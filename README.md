<div align="center">

# Girasol

**YouTube Music and YouTube for iOS 14, built on Linux.**

A music player first, a video app second, and no Shorts anywhere.

![iOS 14](https://img.shields.io/badge/iOS-14-lightgrey?logo=apple)
![Built on Linux](https://img.shields.io/badge/built%20on-Linux-blue?logo=linux&logoColor=white)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

<!-- Screenshots: drop the images into screenshots/ under these names. -->
<img src="screenshots/music-home.png" width="24%" alt="Music home">
<img src="screenshots/music-player.png" width="24%" alt="Music player with lyrics">
<img src="screenshots/music-album.png" width="24%" alt="Album">
<img src="screenshots/video-player.png" width="24%" alt="Video player">

</div>

Girasol is a fork of [Opaline](https://github.com/verback2308/Opaline), a native YouTube
client for older iPhones and iPads. It keeps Opaline's video app and adds a complete
YouTube Music–style app beside it, one tap away. It drops what pulls you into scrolling:
there is no Shorts feed. It also leaves Apple's toolchain behind: the whole app builds with
`make` on a Linux machine, with no Mac, no Xcode and no developer account.

It is made for one target, iOS 14, and is tested on iOS 14.3 (iPhone XR).

## Music

The 🎬|🎵 switch on every top bar turns the app into a music player of its own: Home,
Search, Library, a now-playing bar and a full-screen player with queue, shuffle and repeat.

**Listening**
- **Gapless playback**: the next song is loaded before the current one ends; albums play
  as they were made.
- **It keeps playing**: when an album or playlist ends, a mix built from what you played
  lately carries on (or YouTube Music's own recommendations, with the optional sign-in).
- **Songs, not music videos**: where YouTube Music lists a song's music video, which can be a
  different edit, the album version plays instead, using YouTube's own pairing.
- **Same volume for every song**: loud masters are turned down to YouTube's loudness target.
- **Crossfade** (optional, 3–12 s; albums stay gapless) and a **sleep timer** (15–90 minutes
  with a slow fade, end of the song, or end of the album or playlist).
- **Switch modes without stopping**: a song keeps playing as a bar in video mode, a video as a
  small picture in music mode.
- **Picks up where you left off**: queue, album or playlist, and position survive a relaunch.

**Lyrics**
- **Synced lyrics** from YouTube Music, LRCLIB and NetEase, with strict matching (no lyrics
  is better than another song's), tap a line to seek, a per-song timing nudge, and kept for
  offline.
- **Japanese names as written**: Japanese songs, artists and albums keep their original
  names instead of YouTube Music's romanizations (a setting, on by default).

**Offline and data**
- **Downloads** of songs, albums and playlists (audio only), playable offline. Downloaded
  playlists pick up new songs on Wi-Fi, and an interrupted album download finishes by itself.
- **Songs kept as they play**: what you play is saved as it streams (512 MB by default,
  adjustable or off), so a song played again starts at once, uses no data and plays offline.
  The songs you play most stay longest.
- **Easy on mobile data**: extras such as full-size artwork and finishing half-played songs
  wait for Wi-Fi.
- A **Storage** screen shows what downloads and the cache take.

**Your library**
- **Playlists**: create, rename, delete, reorder, add and remove songs (the exact copy, even
  when a song is in a playlist twice); share any playlist or album; see at a glance which
  playlists are public, link-only or private.
- **Spotify playlists**: copy a Spotify playlist link and open it in the app. Every track is
  matched to YouTube Music, again strictly: a version YouTube Music doesn't have shows as
  missing rather than as a near miss. Play it as it is, or import it as a YouTube Music
  playlist.
- **Speed dial and Listen again** on Home, ranked from what you play.
- **Optional YouTube Music sign-in**: your personal Home, library, history and playlist
  editing. Without it every other feature works.

## Video

Opaline's video app, minus the distractions:
- Home, Subscriptions, channels, search with filters, playlists and watch history synced with
  YouTube.
- Up to 1080p, background audio, Picture in Picture, subtitles, switching between a video's
  audio tracks.
- SponsorBlock, comments, autoplay, downloads for offline viewing.
- **No Shorts**: no Shorts tab and no swipe feed. Shorts from channels you subscribe to appear
  only on their channel pages and in Subscriptions, as ordinary videos.
- No upstream update nags, no background feed refreshing, an English-only interface.

## Install

Girasol is distributed as an ad-hoc signed IPA for **TrollStore** (or AppSync). Build it
yourself (below), then open the `.ipa` in TrollStore. `make publish` also serves an install
page on your LAN, so you can install from the iPhone with one tap.

## Build (Linux)

Girasol builds entirely on Linux. You need:

- a [theos](https://theos.dev) tree with the Swift 5.8 iOS toolchain at
  `~/theos/toolchain/swift-5.8/linux/iphone` (swiftc, clang, ldid);
- an **iPhoneOS 14 SDK** in `~/theos/sdks/` (a newer SDK binds Swift symbols iOS 14 lacks);
- `make`, `python3` and `zip`.

```bash
make ipa                # → build/Opaline_<version>.ipa
make publish            # the same, plus an install page in $(PUBLISH_ROOT)/opaline
make ipa WMO=1          # whole-module build (slower; incremental is the default)
make ipa JOBS=8         # compiler threads and parallel jobs (default 16)
```

Swift builds incrementally: a change to one file rebuilds in a few seconds, a clean build
takes about a minute. Objective-C sources compile with clang beside it. There is no Xcode
project. Asset catalogs ship as loose images and the Info.plist is generated by
`scripts/linux_info_plist.py`.

## Privacy: who the app talks to

- **YouTube and YouTube Music**: everything you browse and play. It works without an account;
  the optional TV sign-in and YouTube Music sign-in are kept in the iOS Keychain and only sent
  to Google.
- **Lyrics**: LRCLIB and NetEase receive the title and artist of the song you are playing.
- **Spotify**: only when you open a Spotify playlist link, to read that playlist.
- **SponsorBlock**: the ID of the video you watch, when SponsorBlock is on.
- **Opaline's solver server**: only on the `tv.sabr` playback fallback, which receives
  YouTube's player URL and a challenge string, nothing about you. Normal playback never uses
  it.

No analytics, no ads, no tracking of its own.

## Reporting problems

Settings → Debug → **Share log** exports a timestamped log of playback, network and cache
events. It is the fastest way to tell what went wrong.

## Credits

- [Opaline](https://github.com/verback2308/Opaline) by verback2308: the app this one is built
  on.
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and its [EJS](https://github.com/yt-dlp/ejs)
  solver, the reference for how YouTube playback works.
- [ytmusicapi](https://github.com/sigma67/ytmusicapi): the reference for YouTube Music's web
  API.
- [LRCLIB](https://lrclib.net) and NetEase Cloud Music: lyrics.
- [SponsorBlock](https://sponsor.ajay.app): crowdsourced sponsor segments.

## Legal

For personal and educational use. Not affiliated with, endorsed by, or connected to Google,
YouTube or Spotify.

## License

[GNU General Public License v3.0](LICENSE), as Opaline is. Any derivative work must also be
released under GPLv3 with its full source code.
