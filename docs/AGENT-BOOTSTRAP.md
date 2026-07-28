# Magnatune iOS — Agent Bootstrap

Read this **first** before touching audio/streaming in the Magnatune iOS/Catalyst app. It is
written so a future agent (or human) can cold‑start and restore full context. It is weighted
toward the **audio / Opus** subsystem, which is where the most recent and most subtle work
lives, but also covers the app basics, build/run, verification, and gotchas.

Last substantive update: **2026‑07‑21** (Opus streaming migration). Facts about the server
were verified against live `magnatune.com` on 2026‑07‑20/21.

---

## 0. TL;DR — current audio state

- The app **streams Ogg Opus** for members. Two picker tiers: **Normal = 96 kbps Opus**
  (`<stem>.opus`) and **High = 192 kbps Opus** (`<stem>_hi.opus`). Default = **Normal**.
- **AAC is only a fallback**, applied automatically if an Opus stream fails to *play* on the
  device. It is not a menu choice.
- Non‑members stream the free `<stem>_spoken.m4a` advert (unchanged).
- **Auto‑downloaded favorites are also Opus** (`<songID>.opus`), so offline favorites match.
- **Now Playing** shows the live format under the album name, e.g. `Opus · 192 kbps`.
- **Key correction:** AVFoundation on **macOS 26.2 (Catalyst)** *does* decode & HTTP‑stream
  Ogg Opus. The long‑standing "AVFoundation can't play Ogg Opus" belief is **false** on this
  OS. **Scope of all of the above = Mac/Catalyst.** Real iOS/iPadOS device is **NOT yet
  verified** (see §9).

---

## 1. The app at a glance

- **Repo:** `johnbuckman/magnatune-app` (PRIVATE). Working tree: `~/Documents/magnatune-ios`.
  Branch `main` (trunk‑based — commit straight to main, no feature branches in history).
  Git identity is set repo‑locally to `John Buckman <john@magnatune.com>`; `gh` account is
  `johnbuckman`.
- **Stack:** SwiftUI, **Mac Catalyst‑first** for fast desktop iteration; also builds/installs
  to iPad/iPhone. **XcodeGen** project (`project.yml` → `xcodegen generate`; regen only when
  files are added/removed). SPM deps: GRDB, Kingfisher, ZIPFoundation. Swift 5 mode, iOS 17
  deployment target, bundle id `com.magnatune.player`.
- **Catalog:** one bundled/refreshed SQLite (artists/albums/songs/genres/collections/
  playlists). Read‑only catalog DB + read‑write user DB (favorites/playlists/history/
  downloads), both GRDB, so a catalog refresh never wipes user data.
- **Playback:** dual‑`AVPlayer` engine for crossfade + next‑track prefetch; `AVAudioSession`
  `.playback`; MPNowPlayingInfoCenter / MPRemoteCommandCenter (lock screen / media keys);
  background audio; AirPlay. LAN peer sync (`_magnatune._tcp`) exists as a separate subsystem.

### Build / run (Catalyst — validates fast)
```bash
cd ~/Documents/magnatune-ios
xcodebuild -project Magnatune.xcodeproj -scheme Magnatune \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  -allowProvisioningUpdates build
# Relaunch the freshly-built copy (mind the bundle-id collision below):
pkill -9 -f 'Magnatune.app/Contents/MacOS/Magnatune'
open build/Build/Products/Debug-maccatalyst/Magnatune.app
```
**Bundle‑id collision gotcha:** several `Magnatune.app` copies share `com.magnatune.player`
(`build/`, `~/Desktop`, `/Applications/AI Apps`). `open` may launch the wrong (old) one.
Always `pkill` first and confirm the running binary path with
`pgrep -fl 'Magnatune.app/Contents/MacOS/Magnatune'`.

I generally **cannot GUI‑test** this app via computer‑use — John has declined the macOS
automation prompt for `com.magnatune.player`. Verify headlessly (see §6) and have John eyeball.

---

## 2. Server media contract (`magnatune.com`, verified 2026‑07‑20/21)

Same‑origin HTTPS on `magnatune.com` (navim4 / NaviServer 5.1). TLS 1.3, valid cert — satisfies
Apple ATS defaults, **no ATS exception needed** (the old one was removed). The retired hosts
`he3.magnatune.com` / `download.magnatune.com` are gone.

**Media path:** `/music/<Artist>/<Album>/<file>`. The **stem** = the catalog `mp3` field with
its extension dropped (e.g. `01-Title-artist.mp3` → `01-Title-artist`).

**Per‑track files (all six exist catalog‑wide, sampled & spot‑verified):**

| File | What | Access |
|---|---|---|
| `<stem>_spoken.m4a` | AAC advert (end‑of‑track announcement) | **free** |
| `<stem>_spoken.opus` | 40 kbps Opus advert | **free** |
| `<stem>.m4a` | **185 kbps AAC** | member |
| `<stem>.opus` | **96 kbps Opus** ← "Normal" | member |
| `<stem>_256.m4a` | **256 kbps AAC‑LC** | member |
| `<stem>_hi.opus` | **192 kbps Opus** ← "High" | member |

`.opus` / `_hi.opus` serve `Content-Type: audio/ogg`.

**Auth:** HTTP **Basic**, realm exactly `Magnatune Membership`. The `401` challenge is
suppressed when `Sec-Fetch-Dest` is present (browsers), but native clients (AVPlayer) get the
real `WWW-Authenticate`. **File existence is checked before auth**, so a `401` (not `404`)
proves the file exists.

**Test member creds:** use your own magnatune.com member login (a paid membership).

Covers: `cover_<N>.jpg` (50,75,100,150,200,300,400,600,800,1400; webp for a subset). Artist
photos: `artist_<N>.jpg` per album dir. Catalog: `/info/sqlite_normalized.sql.gz`, version
CRC `/info/changed.txt`. Membership check: `POST /membership/check.php` (`user=`/`pw=` →
`{"ok":true|false}`). Album zip: `/membership/download3?sku=&format=`.

---

## 3. Audio pipeline — how the code works now

All streaming decisions funnel through a few well‑defined pieces. **There is no HEAD/existence
probe** — that was tried and removed (see §5, bug 1).

### `StreamQuality` (`Services/URLBuilder.swift`)
Two Opus tiers. Raw values `"normal"`/`"high"` (persisted under `stream.quality`).
- `.normal` → `memberFile` = `("", "opus")` → `<stem>.opus` (96 kbps)
- `.high` → `memberFile` = `("_hi", "opus")` → `<stem>_hi.opus` (192 kbps)
- `aacFallbackFile` = the AAC file streamed **only** when Opus can't decode
  (`.normal`→`("", "m4a")` 185k, `.high`→`("_256", "m4a")` 256k). *Not* used for downloads.
- `freeFile` = `("_spoken", "m4a")` (non‑member).
- `label`/`detail` drive the Settings picker ("Normal — 96 kbps Opus", "High — 192 kbps Opus").
- **Default = Normal.** `current` maps `"high"`/legacy `"lossless"` → `.high`, everything
  else (incl. unset) → `.normal`. `SettingsView`'s `@AppStorage` default is also `.normal` so
  picker and player agree. Legacy `"lossless"` is migrated to `"high"` once in `AudioPlayer.init`.

### `resolvedStreamURL(...)` (`URLBuilder`) — synchronous, no probe
- member + `allowOpus` → `memberFile` (Opus)
- member + `!allowOpus` → `aacFallbackFile` (AAC) — set after an Opus decode failure
- non‑member → `freeFile`

### `downloadStreamURL(...)` (`URLBuilder`)
Returns the **Opus** file (`memberFile`) for permanent downloads.

### `formatLabel(forStreamURL:)` (`URLBuilder`)
Maps a resolved URL → the Now Playing label: `_hi.opus`→"Opus · 192 kbps",
`.opus`→"Opus · 96 kbps", `_256.m4a`→"AAC · 256 kbps", `.m4a`→"AAC · 185 kbps",
`_spoken.*`→"… · preview".

### `AudioPlayer.makeAsset(for:)` (`Services/AudioPlayer.swift`)
Returns `PreparedAsset { asset, format }`.
1. **Download preferred** (offline + saves bandwidth): if `DownloadStore.localURL(songID)`
   exists → play it. *Skipped* if `opusDisabledThisSession && ext=="opus"` (so a decode‑
   incapable device streams AAC instead of looping on an unplayable local file). Format label
   = codec from the file's extension ("Opus"/"AAC", no bitrate — the on‑disk name is
   `<songID>.opus` and doesn't carry the tier).
2. Else `resolvedStreamURL(...)` → build `AVURLAsset` with
   `options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": <basic>]`.
   ⚠️ **This explicit header is the ONLY working auth for AVPlayer.** `URLCredentialStorage`
   does **not** work — CoreMedia loads media out‑of‑process and never consults the app's
   credential store (fails with `CoreMediaErrorDomain -16840 "HTTP 401"`).
3. `AudioCache` may substitute a cached local file (keyed by the resolved URL — see §7).
4. Sets `@Published currentFormat`.

### Playback‑failure fallback (`AudioPlayer.handleItemFailure`)
This is the **only** Opus→AAC fallback mechanism.
- `observe(item:for:)` attaches a KVO observer on `AVPlayerItem.status` (plus the end‑of‑track
  notification) at every site that makes an item current: `loadCurrent`, `beginCrossfade`,
  `cancelCrossfade`. `beginCrossfade` also bails to the fallback if the buffered incoming item
  is already `.failed`.
- On `status == .failed` for a **`.opus`** item: set session flag `opusDisabledThisSession`,
  `NSLog("Magnatune: Opus stream failed …")`, and reload the track as AAC
  (`resolvedStreamURL(..., allowOpus:false)`). Session‑scoped (re‑tries Opus next launch).
- The `.opus`‑extension guard stops an AAC/auth failure from pointlessly disabling Opus; the
  flag makes it one‑shot (no loop).
- **Verified:** an undecodable `.opus` yields `AVFoundationErrorDomain -11849` → `.failed`, so
  the trigger fires (doesn't hang). On Catalyst Opus always decodes, so the flag never trips.

### Downloads (`Services/DownloadStore.swift`)
Permanent, never‑evicted, keyed by **song id**, stored as **`<songID>.opus`**. Purges legacy
`.m4a`/`.mp3` on launch → `AppModel.syncAutoDownloads` (members‑only, favorites) re‑fetches
them as Opus. Distinct from the LRU `AudioCache`.

### Streamed cache (`Services/AudioCache.swift`)
1 GB LRU of streamed files, keyed by **`SHA256(remote.absoluteString) + ext`**. Because the
key includes the full URL, an Opus URL can never collide with a stale AAC entry — old `.m4a`
cache files are just orphaned and evict on their own.

### UI
- **Now Playing** (`Views/PlayerViews.swift`, `NowPlayingView`): a `.caption`/`.tertiary` line
  under the album name shows `audio.currentFormat`, local playback only (`remote == nil`).
- **Settings** (`Views/SettingsView.swift`): "Audio quality" picker (Normal/High Opus), caption,
  `@AppStorage(StreamQuality.defaultsKey)` default `.normal`.

---

## 4. The migration story & the key finding

The web player and Android client moved to Opus; iOS had stayed on AAC on the belief that
**"AVFoundation can't play Ogg Opus."** This session tested that belief and it is **false on
macOS 26.2 / Catalyst‑family AVFoundation**: `AVPlayer` decodes and HTTP‑range‑streams the
server's Ogg `.opus` / `_hi.opus` files, with ~0.75 s local / ~2.25 s production startup, and
correct seeking. (A CAF‑Opus re‑encode path was considered and **rejected** — it needs a
catalog‑wide server encode and showed an intermittent ~14 s cold‑parse; the existing Ogg
files are better.) So iOS was switched to stream the existing Opus files directly — **zero
server work.**

**Scope caveat:** the CLI/harness and Catalyst both use *macOS* AVFoundation. **Real
iOS/iPadOS is the historically stricter platform and is NOT verified.** The AAC
playback‑failure fallback (§3) is the safety net if an actual device can't decode Opus.

---

## 5. Bugs found & fixed this session

**Bug 1 — "plays AAC even though Opus is selected."** An earlier design added a pre‑flight
`StreamProbe` HEAD request to check `_hi.opus` existed before playing, falling back to AAC if
not 200. `StreamProbe` cached results **per‑URL, not per‑auth‑state**. A probe that ran at
launch **before sign‑in (nil auth header)** got a `401` → cached `false` → **every** track was
demoted to AAC for the whole session, even after auth became available. Diagnosis: the server
answers `HEAD` `200`; a standalone `URLSession` HEAD *with* auth returns `200`; and
`isMember==true` already guarantees `basicAuthHeader()` is valid — so the mechanism and
playback auth were fine, it was the probe's cache/auth‑timing. **Fix: deleted the probe.**
Request Opus directly (the production harness already proved AVPlayer streams it with the auth
header) and rely solely on the playback‑failure fallback — more reliable, zero latency, and
immune to an auth/transport blip demoting everything.

**Bug 2 — "previously‑played (favorited) albums keep playing AAC."** Auto‑download‑favorites
had saved tracks as AAC `.m4a`, and `makeAsset` prefers a local download, so favorited albums
played AAC forever, even online. (The tell: the Now Playing label read bare **"AAC"** with no
bitrate — that string only comes from the download path.) The LRU `AudioCache` was ruled out
(full‑URL keying). **Fix: downloads are now Opus** (`downloadStreamURL`→`memberFile`,
`DownloadStore` stores `.opus`, purges legacy `.m4a`/`.mp3` on launch → re‑download as Opus).

**Do not reintroduce a pre‑flight HEAD/existence probe for tier selection.** It is redundant
with the playback‑failure fallback and caused Bug 1.

---

## 6. Verifying headlessly (no GUI needed)

**curl the server (member entitlement + real Opus payload):**
```bash
U=your_member_user P=your_member_pass   # your own magnatune.com member login
BASE='https://magnatune.com/music/1KUB/French%20Kiss/02-Bless%20Us-1kub'   # a known real track
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -r 0-0 "$BASE_hi.opus"          # noauth → 401
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -u "$U:$P" -r 0-0 "${BASE}_hi.opus"   # auth → 206 audio/ogg
curl -s -u "$U:$P" -r 0-131071 "${BASE}_hi.opus" -o /tmp/x.opus && file /tmp/x.opus     # "Ogg data, Opus audio"
```

**Standalone AVFoundation harness** (the decisive test that AVPlayer really plays/streams
Opus). It is not committed — it lived in the session scratchpad. To recreate: a `swiftc`
command‑line tool linking `AVFoundation`/`CoreMedia` that builds an `AVPlayer`, KVO‑observes
`AVPlayerItem.status`, plays N seconds and confirms `currentTime` advanced (real decode), with
optional seek and optional `AUTH_USERPASS` env → Basic header via `AVURLAssetHTTPHeaderFieldsKey`.
Point it at `file://` local files (isolates decode) or a production URL (tests streaming+auth).
Results proven this session: local `.opus`/`.caf`/`.m4a` all PASS; production `_hi.opus` with
member auth PASS+SEEK; same URL without auth → `NSURLErrorDomain -1013` (401). Build one CAF
with `afconvert -f caff -d opus in.wav out.caf`; a real Ogg‑Opus with
`ffmpeg -i in.wav -c:a libopus out.opus` (afconvert's Ogg writer is broken → `'pck?'`).

**Catalyst container** (`~/Library/Containers/com.magnatune.player/Data`):
- downloads: `Application Support/Downloads/<songID>.opus`
- streamed cache: `Library/Caches/.../AudioCache/<sha>.opus`
- quality setting: `defaults read com.magnatune.player stream.quality`
- Opus playback failures log `Magnatune: Opus stream failed …` (Console / `log show`).

---

## 7. Gotchas (each cost real time at some point)

- **`URLCredentialStorage` does NOT authenticate `AVPlayer`.** Use the explicit
  `AVURLAssetHTTPHeaderFieldsKey` Authorization header.
- **No pre‑flight HEAD probe for tiers** (Bug 1). Use the playback‑failure fallback.
- **Downloads must store the file's real extension** — AVFoundation trusts the extension;
  Opus bytes in a `.m4a` file won't play.
- **`isMember==true` ⟹ `basicAuthHeader()` is valid** (every path that sets `isMember` first
  reads a non‑nil password). So if member audio 401s, it's not the header.
- **Bundle‑id collision** on relaunch (§1). Confirm the running binary path.
- **AVFoundation‑can't‑play‑Ogg‑Opus is false on macOS 26.2** but **unverified on real iOS**.

---

## 8. File map (audio subsystem)

| File | Responsibility |
|---|---|
| `Services/URLBuilder.swift` | `StreamQuality` (tiers, `memberFile`/`aacFallbackFile`/`freeFile`), URL building, `resolvedStreamURL` (sync, no probe), `downloadStreamURL`, `formatLabel`. |
| `Services/AudioPlayer.swift` | Dual‑AVPlayer engine, `makeAsset`→`PreparedAsset`, auth header, `opusDisabledThisSession` + `handleItemFailure`, `currentFormat`, crossfade/prefetch. |
| `Services/DownloadStore.swift` | Permanent Opus downloads (`<songID>.opus`), legacy purge. |
| `Services/AudioCache.swift` | LRU streamed cache, `SHA256(full URL)+ext` key. |
| `Services/Credentials.swift` | Basic auth (`basicAuthHeader`), keychain + in‑memory password, membership check. |
| `Services/AppModel.swift` | Auto‑download‑favorites (`syncAutoDownloads`, uses `downloadStreamURL`). |
| `Views/PlayerViews.swift` | `NowPlayingView` (format line), `MiniPlayer`, `SeekBar`. |
| `Views/SettingsView.swift` | Audio‑quality picker + caption. |

---

## 9. Open items / TODO

- **Verify Opus on a real iOS/iPadOS device.** Everything above is proven on Mac/Catalyst
  only. If shipping to iPad/iPhone: confirm Ogg‑Opus decode on‑device (older iOS may lack it →
  the AAC playback‑failure fallback covers it; consider an OS‑version gate). Devices/creds are
  in the `magnatune_ios_app` memory note.
- **Correct the navim4 contract doc** `~/navim4/docs/magnatune-clients-and-media-contract.md`
  — it still asserts "iOS cannot [use Opus] because AVFoundation won't play Ogg Opus," now
  known false (Catalyst).
- **Download format label** shows codec only ("Opus"), not bitrate, because `<songID>.opus`
  doesn't encode the tier. Could name downloads with the tier suffix (and parse the leading
  song id) if the exact rate matters.
- ✅ **Released as v0.2.0** (2026-07-21): notarized universal DMG + zipped .app on the GitHub
  release, and the DMG is served at `magnatune.com/downloads/magnatune-osx.dmg` (committed to
  navim4 `downloads/`, gitignore-whitelisted) and linked from the web player's Settings → Apps
  ("Magnatune for OSX"). **Release recipe:** bump `MARKETING_VERSION` in `project.yml` →
  `xcodegen generate` → `./build-osx-dmg.sh` (Developer ID "Vid Tadel", notary profile
  `bping-notary`; drops `~/Desktop/Magnatune-v<V>.dmg` + `.app`, Gatekeeper "Notarized
  Developer ID") → `gh release create` with the DMG + a `ditto`-zipped .app → copy the DMG into
  `~/navim4/downloads/` and bump the `app/index.html` `?v=`. ⚠️ navim4 is pushed but **prod
  needs a `git pull`** to serve the new DMG/settings (no ssh to prod from this Mac).

---

*Companion notes:* the private memory note `magnatune_ios_app` (agent memory) is the session‑
level index and points here. The system‑wide media/auth contract for all three clients lives
in `navim4/docs/magnatune-clients-and-media-contract.md`.
