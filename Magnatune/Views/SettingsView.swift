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
    @AppStorage("audio.cache.enabled") private var audioCacheEnabled = true
    @AppStorage("crossfade.enabled") private var crossfadeEnabled = true

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

            Section("Playback") {
                Toggle("Crossfade between songs", isOn: $crossfadeEnabled)
                Text("Smoothly fades the end of each track into the next.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Streaming") {
                Toggle("Cache streamed music on device", isOn: $audioCacheEnabled)
                Text("Tracks stream as 128 kbps MP3. When caching is on, tracks you play are saved so they don't re-download next time (and the next track is prefetched to remove gaps). Up to 1 GB.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Downloads") {
                Toggle("Auto-download favorites", isOn: Binding(
                    get: { model.autoDownloadFavorites },
                    set: { model.setAutoDownloadFavorites($0); refreshCacheSize() }))
                Text("Automatically downloads every song, album, and artist you favorite so they're available offline — no extra steps. When you're offline, the app shows only your downloaded music.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Downloaded music", value: downloadsText)
                Button("Clear Downloads", role: .destructive) {
                    DownloadStore.shared.clear()
                    model.refreshDownloadedSets()
                    refreshCacheSize()
                }
            }

            Section("Catalog") {
                LabeledContent("Status", value: model.catalogReady ? "Ready" : "Loading")
                Button {
                    Task { await model.refreshCatalog(force: true) }
                } label: {
                    HStack {
                        Text("Refresh Catalog Now")
                        if model.isRefreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isRefreshing)
                Text("The catalog auto-updates at most once per day when magnatune.com reports changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Cached art & photos", value: cacheText)
                Button("Clear Image Cache", role: .destructive) {
                    KingfisherManager.shared.cache.clearMemoryCache()
                    KingfisherManager.shared.cache.clearDiskCache { refreshCacheSize() }
                }
                LabeledContent("Cached music", value: audioCacheText)
                Button("Clear Music Cache", role: .destructive) {
                    AudioCache.shared.clear(); refreshCacheSize()
                }
                Text("Album art, artist photos, and played tracks are stored on this device so they don't reload over the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "Magnatune Player 0.1")
                Text("Music licensed Creative Commons by Magnatune (magnatune.com).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { username = creds.username; refreshCacheSize() }
    }

    private func refreshCacheSize() {
        KingfisherManager.shared.cache.calculateDiskStorageSize { result in
            switch result {
            case .success(let bytes):
                cacheText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            case .failure:
                cacheText = "—"
            }
        }
        let bytes = AudioCache.shared.totalSize()
        audioCacheText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let dl = DownloadStore.shared.totalSize()
        let n = DownloadStore.shared.count()
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
