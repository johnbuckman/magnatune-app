import SwiftUI
import Kingfisher

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var creds: Credentials
    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var result: SignInResult?
    @State private var cacheText = "Calculating…"
    @State private var audioCacheText = "Calculating…"
    @State private var downloadsText = "Calculating…"
    @State private var imageCacheBytes: Int64 = 0   // raw size; trash shown only when > 0
    @State private var audioCacheBytes: Int64 = 0
    @State private var downloadsBytes: Int64 = 0
    @State private var showWhyNotEvil = false
    @State private var showFoundersRant = false
    @AppStorage("audio.cache.enabled") private var audioCacheEnabled = true
    @AppStorage("crossfade.enabled") private var crossfadeEnabled = true
    @AppStorage("crossfade.duration") private var crossfadeDuration = 6.0
    @AppStorage(StreamQuality.defaultsKey) private var streamQualityRaw = StreamQuality.normal.rawValue
    @AppStorage("download.album.format") private var dlAlbumFormat = "vbr"
    @AppStorage("download.song.format") private var dlSongFormat = "mp3"
    private let albumDownloadFormats: [(String, String)] = [("vbr", "MP3 — high quality VBR (~88MB)"), ("mp3", "MP3 — 128k (smaller)"), ("aac", "AAC — for iTunes / iPod"), ("alac", "ALAC — Apple Lossless"), ("flac", "FLAC — lossless, open"), ("ogg", "OGG — high quality, open"), ("wav", "WAV — lossless, exact copy")]
    private let songDownloadFormats: [(String, String)] = [("mp3", "MP3 — high quality"), ("ogg", "OGG"), ("flac", "FLAC — lossless"), ("wav", "WAV — lossless")]

    enum SignInResult { case success, failure }

    var body: some View {
        Form {
            Section("Magnatune Membership") {
                if creds.isMember {
                    Label("Signed in as \(creds.username)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Sign Out", role: .destructive) {
                        creds.clear(); username = ""; password = ""; result = nil
                    }
                    Text("Member streams play in higher quality with no spoken interruption at the end of tracks.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                    Button {
                        signIn()
                    } label: {
                        HStack {
                            Text("Sign In & Verify")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || checking)

                    switch result {
                    case .success:
                        Label("Credentials verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure:
                        Label("Login failed — check your username and password", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    case nil:
                        Text("Without a membership, tracks stream for free but include a spoken announcement at the end of each track.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            groupDivider

            Section {
                Toggle("Crossfade between songs", isOn: $crossfadeEnabled)
                if crossfadeEnabled {
                    HStack(spacing: 12) {
                        Text("Duration")
                        Slider(value: $crossfadeDuration, in: 1...10, step: 1)
                        Text("\(Int(crossfadeDuration))s")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            } header: { Text("Playback") } footer: {
                Text("Smoothly fades the end of each track into the next, over the chosen duration (1–10 seconds).")
            }

            groupDivider

            Section {
                if creds.isMember {
                    Picker("Audio quality", selection: $streamQualityRaw) {
                        ForEach(StreamQuality.allCases) { q in
                            Text("\(q.label) — \(q.detail)").tag(q.rawValue)
                        }
                    }
                }
                Toggle("Cache streamed music on device", isOn: $audioCacheEnabled)
            } header: { Text("Streaming") } footer: {
                Text(creds.isMember
                     ? "Members can stream at Normal (~160 kbps AAC) or Lossless (256 kbps AAC-LC). When caching is on, tracks you play are saved so they don't re-download next time (and the next track is prefetched to remove gaps). Up to 1 GB."
                     : "Tracks stream as AAC (.m4a). When caching is on, tracks you play are saved so they don't re-download next time (and the next track is prefetched to remove gaps). Up to 1 GB.")
            }

            groupDivider

            if creds.isMember {
                Section {
                    Picker("Album", selection: $dlAlbumFormat) {
                        ForEach(albumDownloadFormats, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Songs", selection: $dlSongFormat) {
                        ForEach(songDownloadFormats, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: { Text("Download formats") } footer: {
                    Text("The format used when you tap the download button on an album or a single song. Downloads open in your browser.")
                }

                groupDivider
            }

            Section {
                Toggle("Auto-download favorites", isOn: Binding(
                    get: { model.autoDownloadFavorites },
                    set: { model.setAutoDownloadFavorites($0); refreshCacheSize() }))
                LabeledContent("Downloaded music") {
                    HStack(spacing: 12) {
                        Text(downloadsText).foregroundStyle(.secondary)
                        if downloadsBytes > 0 {
                            Button(role: .destructive) {
                                DownloadStore.shared.clear()
                                model.refreshDownloadedSets()
                                refreshCacheSize()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Downloads") } footer: {
                Text(creds.isMember
                     ? "Automatically downloads every song, album, and artist you favorite so they're available offline — no extra steps. When you're offline, the app shows only your downloaded music."
                     : "Requires a Magnatune membership. Sign in above to download your favorites for offline listening.")
            }

            groupDivider

            Section {
                Toggle("Share & control on local network", isOn: Binding(
                    get: { model.peerSharingEnabled },
                    set: { model.setPeerSharingEnabled($0) }))
                if model.peerSharingEnabled && !model.localNetworkGranted {
                    Button { model.requestLocalNetworkAccess() } label: {
                        Label("Requires device permission", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if model.peerSharingEnabled {
                    Toggle("Auto-stop other music", isOn: Binding(
                        get: { model.autoStopOtherMusic },
                        set: { model.setAutoStopOtherMusic($0) }))
                }
            } header: { Text("Local Network") } footer: {
                Text("Lets this app see other Magnatune apps on your Wi-Fi. When you're not playing here, the player shows what's playing on another device and its buttons control it. Auto-stop other music pauses other Magnatune apps when you start playing here (both devices must have it on).")
            }

            groupDivider

            Section {
                Toggle("Hide things I dislike", isOn: Binding(
                    get: { model.hideDislikes },
                    set: { model.setHideDislikes($0) }))
            } header: { Text("Dislikes") } footer: {
                Text("Tap the broken-heart icon next to the heart on any song, album, or artist to dislike it. While this is on, disliked things are hidden everywhere. Turn it off to see them again and tap the broken-heart icon to un-dislike.")
            }

            groupDivider

            Section {
                if !model.catalogReady {
                    LabeledContent("Status", value: "Loading…")
                } else if model.isRefreshing {
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            Text("Updating…").foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    LabeledContent("Status", value: "Up to date")
                }
            } header: { Text("Catalog") } footer: {
                Text("New catalog versions from magnatune.com download automatically in the background.")
            }

            groupDivider

            Section {
                LabeledContent("Cached art & photos") {
                    HStack(spacing: 12) {
                        Text(cacheText).foregroundStyle(.secondary)
                        if imageCacheBytes > 0 {
                            Button(role: .destructive) {
                                KingfisherManager.shared.cache.clearMemoryCache()
                                KingfisherManager.shared.cache.clearDiskCache { refreshCacheSize() }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                LabeledContent("Cached music") {
                    HStack(spacing: 12) {
                        Text(audioCacheText).foregroundStyle(.secondary)
                        if audioCacheBytes > 0 {
                            Button(role: .destructive) {
                                AudioCache.shared.clear(); refreshCacheSize()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Storage") } footer: {
                Text("Album art, artist photos, and played tracks are stored on this device so they don't reload over the network.")
            }

            groupDivider

            Section("About") {
                LabeledContent("App", value: "Magnatune Player 0.1")
                Text("Music licensed Creative Commons by Magnatune (magnatune.com).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Why we are not evil") { showWhyNotEvil = true }
                Button("Founder's Rant") { showFoundersRant = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { username = creds.username; refreshCacheSize(); model.refreshLocalNetworkStatus() }
        .task { await model.checkCatalogUpdate() }
        .sheet(isPresented: $showWhyNotEvil) {
            InfoSheet(title: "Why we are not evil") {
                Text("Why Magnatune is not evil").font(.title3.bold())
                ForEach(whyNotEvilPoints, id: \.self) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").bold()
                        Text(point)
                    }
                }
            }
        }
        .sheet(isPresented: $showFoundersRant) {
            InfoSheet(title: "Founder's Rant") {
                Text(foundersRantText)
            }
        }
    }

    /// A thick full-width rule shown between settings groups.
    private var groupDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.55))
            .frame(height: 3)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    private func refreshCacheSize() {
        KingfisherManager.shared.cache.calculateDiskStorageSize { result in
            switch result {
            case .success(let bytes):
                imageCacheBytes = Int64(bytes)
                cacheText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            case .failure:
                imageCacheBytes = 0
                cacheText = "—"
            }
        }
        let bytes = AudioCache.shared.totalSize()
        audioCacheBytes = bytes
        audioCacheText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let dl = DownloadStore.shared.totalSize()
        let n = DownloadStore.shared.count()
        downloadsBytes = dl
        downloadsText = n == 0 ? "None" : "\(ByteCountFormatter.string(fromByteCount: dl, countStyle: .file)) · \(n) tracks"
    }

    private func signIn() {
        checking = true
        result = nil
        Task {
            let ok = await Credentials.verify(username: username, password: password)
            await MainActor.run {
                checking = false
                if ok {
                    creds.save(username: username, password: password)
                    result = .success
                } else {
                    result = .failure
                }
            }
        }
    }
}

// MARK: - Info sheets (content from magnatune.com/info/whynotevil and /info/why)

/// A scrollable, dismissible sheet with a title — used for the About info pages.
struct InfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

let whyNotEvilPoints: [String] = [
    "Fantastic music: we work with artists directly, not with record labels, and all our music is hand-picked. On average, we accept 3% of submissions.",
    "Perfect audio quality: our music is available in both lossless and smaller-size \"lossy\" formats.",
    "Many audio formats: albums download as WAV, super-high-quality VBR MP3, AAC, Apple Lossless (ALAC), and open-source-friendly FLAC, OGG and OPUS.",
    "Listen to everything: all our albums can be heard in their entirety before you buy.",
    "Download everything: once you've paid, download anything from our entire catalog — no limits.",
    "Musicians get paid: 50% of your purchase price goes directly to the musician, not to labels and their lawyers.",
    "Name your price: you choose how much to pay, and 50% of your choice goes to the artist.",
    "Give to your friends: we encourage you to give 3 copies of any music from your membership to your friends.",
    "Creative Commons: our 128k MP3s are some-rights-reserved Creative Commons licensed.",
    "Remix friendly: tons of our music, acapellas and samples are available for remixing at CC Mixter.",
    "100% legal: Magnatune is completely legal all over the world.",
    "Licensing: all our music can be licensed for commercial use instantly and online, with no additional permissions.",
    "Artists direct: we sign contracts directly with musicians — no middlemen in the way of the artist's royalties.",
    "Podcast-legal: non-commercial podcasters can use our music for free.",
    "No major labels: we have nothing to do with major labels, their lawyers or the RIAA.",
    "Supports Open Source: we financially support open source projects such as Amarok and Rhythmbox.",
    "No DRM: no copy protection, so you can do what you like with your music.",
]

let foundersRantText = """
by John Buckman, founder/owner

Magnatune was born out of some observations I'd gathered about the music industry, along with personal experiences from my wife releasing her CD on an Indie record label.

Personal experience:

When my wife was signed to an Indie record label, we were really excited. In the end, she sold close to 1000 CDs, lost all rights to her music for 8 years (even though the CD had been out of print for several years), and earned a little over $100 in royalties (no one is really sure), some of which was paid to her as CD copies of her own CD which she then gave away for promotion.

The record label that signed her wasn't evil: they were one of the good guys, and gave her a 70/30 split of the profits (of which there were few). The label got screwed at every turn: distributors refused to carry their CDs unless they spent thousands on useless print ads, or they didn't pay for the CDs sold, etc. In general, all forces colluded to prevent this small, progressive label from succeeding.

She was one of the lucky ones. We knew several musicians, signed to various labels, who were also frustrated, who received no money ever and who lost the rights to their music forever.

Industry observations:

Radio is boring: everyone I know is into interesting music, yet good music is rarely played on the air. I'm into everything from Ambient, Industrial, Goth and Metal to Renaissance, Baroque, Tango, Indian Classical and New Age — and so are many of my friends. Yet these genres are barely visible in record stores, and totally absent from the airwaves.

CDs cost too much, and artists only get 20 cents to a dollar for each CD sold — if they're lucky. And most CDs quickly go out of print.

Online sales often cost the artist 50% of their already-pathetic royalty (due to a common record-contract provision). International sales and mark-downs often net the artist no royalties.

Record labels lock their artists into legal agreements that hold them for a decade or more. If it's not working out, labels don't print the band's recordings but nonetheless keep them locked into the contract. Even hugely successful artists often end up owing their record label money.

Peer-to-peer software has proven there's a huge, continuing demand for music, and people want to share it. Clearly there's a huge public demand for Open Music.

Using the Internet to listen to music is usually tedious: too many ads, too many clicks, and the sound quality is usually bad. A well-run Internet radio station solves that, but the entrenched record industry wants to kill that too, using extremely high fees as the weapon.

My solution:

I thought: why not make a record label that has a clue? One that helps artists get exposure, make at least as much money as they would with traditional labels, and helps them get fans and concerts.

Magnatune is my project. The goal is to find a way to run a record label in the Internet reality: file trading, Internet radio, musicians' rights, the whole nine yards.

If you think Magnatune is a worthy goal, please support it. There are powerful forces who want it to fail, so I need your help if this is going to work.

Magnatune was founded in April 2003, and is located in the People's Republic of Berkeley, California.
"""
