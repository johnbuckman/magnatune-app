# Magnatune

A native SwiftUI music player for [magnatune.com](https://magnatune.com), built **Mac
Catalyst-first** (Optimized for Mac) and also running on iPad. Browse the full Magnatune
catalog, stream or download tracks, build playlists, and listen offline.

## Features

- **Browse** — Popular (per-genre rows), Artists, Albums, Genres, Tags (collections),
  Featured (curated playlists), and Songs (search).
- **Search** across artists, albums, and songs.
- **Favorites** — heart any song, album, or artist; play-all per section; remove inline.
- **User playlists** — create, add, reorder, delete; add a song / whole album / whole artist.
- **Playback** — dual-`AVPlayer` engine with 6 s **crossfade**, next-track prefetch, lock-screen
  / media-key control (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`), background audio,
  and an AirPlay output picker.
- **Offline** — optional **auto-download of favorites** to permanent on-device storage; when the
  network drops, the UI hides everything not downloaded and greys the browse sections, restoring
  automatically when back online. Plus a 1 GB LRU cache of streamed tracks.
- **Caching** — persistent on-disk image cache (Kingfisher) and audio cache, with sizes/clear in
  Settings.
- **Mac-like UI** — floating rounded-rectangle sidebar, a docked player bar confined to the
  content column, a native menu bar (Controls: ⌘P play/pause, ⌘] / ⌘[ next/prev), and a clean
  window title bar.

## Requirements

- Xcode 16+ (the project targets the macOS 26.x / iOS SDKs).
- [XcodeGen](https://github.com/yonsei/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is
  generated from `project.yml` and is **not** checked in.
- Runtime: **macOS 14 Sonoma+** (Catalyst) or **iPadOS 17+**.

## Setup

```bash
brew install xcodegen        # once
xcodegen generate            # regenerate Magnatune.xcodeproj from project.yml
```

Re-run `xcodegen generate` only when files are **added or removed** (editing existing files or
overwriting a same-named resource does not need it).

## Build & run

**Mac Catalyst (fast desktop iteration):**

```bash
xcodebuild -project Magnatune.xcodeproj -scheme Magnatune \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  -allowProvisioningUpdates build
open build/Build/Products/Debug-maccatalyst/Magnatune.app
```

**iPad device:**

```bash
xcodebuild -project Magnatune.xcodeproj -scheme Magnatune \
  -destination 'platform=iOS,id=<YOUR_DEVICE_UDID>' \
  -derivedDataPath build-ios -clonedSourcePackagesDirPath build/SourcePackages \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <YOUR_DEVICE_ID> \
  build-ios/Build/Products/Debug-iphoneos/Magnatune.app
```

**Distributable macOS app** (`build-osx-dmg.sh`) — builds a Release universal (arm64 + x86_64)
Catalyst app, re-signs with a Developer ID, optionally notarizes/staples, and drops
`Magnatune.app` + a DMG on the Desktop:

```bash
./build-osx-dmg.sh                 # signed + notarized
MAG_NO_NOTARIZE=1 ./build-osx-dmg.sh   # signed only (skip the notary round-trip)
```

Override the signing identity / notary profile with `MAG_SIGN_ID` and `MAG_NOTARY_PROFILE`.

## Architecture

- **Two SQLite databases** (both via [GRDB](https://github.com/groue/GRDB.swift)):
  - a **read-only catalog** downloaded from Magnatune, replaced wholesale on refresh; a seed copy
    (`Magnatune/Resources/magnatune.db`) ships in the bundle.
  - a **read-write user database** in Application Support (favorites, playlists, play history,
    downloads) — so a catalog refresh never touches personal data.
- **Services** — `AppModel` (owns stores + connectivity + offline filters + auto-download),
  `CatalogStore`, `UserStore`, `AudioPlayer`, `AudioCache` (LRU), `DownloadStore` (permanent),
  `CatalogSync`, `Credentials` (Keychain), `URLBuilder`.
- **Dependencies** (SPM): GRDB, [Kingfisher](https://github.com/onevcat/Kingfisher),
  [ZIPFoundation](https://github.com/weichsel/ZIPFoundation).

```
Magnatune/
  App/        MagnatuneApp, Info.plist, entitlements
  Database/   CatalogStore, UserStore
  Models/     record types
  Services/   AppModel, AudioPlayer, AudioCache, DownloadStore, CatalogSync, Credentials, URLBuilder
  Views/      RootView, BrowseViews, DetailViews, LibraryExtras, PlayerViews, SettingsView, Components, MacSupport
  Resources/  seed catalog db, logo, mascot, app icon
```

## Magnatune endpoints

All endpoints are plain HTTP (an ATS exception for `magnatune.com` + subdomains ships in
`Info.plist`).

- **Catalog** — one SQLite file at `http://he3.magnatune.com/info/sqlite_normalized.db`.
  Version check: `http://magnatune.com/info/changed.txt` (a CRC int); polled ≤ 24 h.
- **Stream** (128 kbps MP3) — members: `http://download.magnatune.com/all/<name>_nospeech.mp3`
  (no end-of-track announcement); free: `http://he3.magnatune.com/all/<mp3>`. HTTP Basic auth.
- **Login check** — `GET http://download.magnatune.com/buy/membership_free_dl_xml` with Basic
  auth → 200 = valid.
- **Cover art** — `http://he3.magnatune.com/music/<Artist>/<Album>/cover_<N>.jpg`,
  N ∈ {50,100,200,300,600,1400} (no auth).
- **Album download** (zip per format) —
  `http://download.magnatune.com/music/<Artist>/<Album>/<sku>-<fmt>.zip`, fmt ∈ mp3/ogg/flac/wav/aac.

Membership credentials are stored in the Keychain, never in source.

## License

Music on Magnatune is licensed Creative Commons by the artists. This app is a private project
for magnatune.com.
