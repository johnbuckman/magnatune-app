import SwiftUI
import Kingfisher

/// True when the UI is in the compact (iPhone) layout. Set once by RootView (driven by
/// width / size class) and read by shared components so they can adapt — notably to
/// shrink album covers and the player on iPhone without touching the iPad layout.
private struct PhoneLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isPhoneLayout: Bool {
        get { self[PhoneLayoutKey.self] }
        set { self[PhoneLayoutKey.self] = newValue }
    }
}

/// Album-cover display dimension: 30% smaller in the iPhone layout, unchanged elsewhere.
func coverDim(_ base: CGFloat, phone: Bool) -> CGFloat { phone ? base * 0.7 : base }

extension Color {
    /// Thin, light hairline around artist circles and (non-full-size) album covers (~#D9D9D9).
    static let artworkBorder = Color(white: 0.85)
}
/// Width of the artwork hairline border (≈ 1px on retina).
let artworkBorderWidth: CGFloat = 0.5

/// Loads a bundled PNG (loose resource) by name.
struct BrandImage: View {
    let name: String
    var body: some View {
        if let ui = UIImage(named: name) ?? BrandImage.fromBundle(name) {
            Image(uiImage: ui).resizable().interpolation(.high)
        } else {
            Color.clear
        }
    }
    static func fromBundle(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct CoverImage: View {
    @Environment(\.displayScale) private var displayScale
    let artistName: String
    let albumName: String
    /// The dimension this cover is displayed at, in points. The actual download
    /// size is the smallest Magnatune tier that covers points × screen scale.
    var points: CGFloat
    var corner: CGFloat = 6

    // Available cover_N.jpg sizes; inline use is capped at 600 (1400 is reserved
    // for the full-screen viewer) so we never over-fetch. The finer tiers let small
    // displays (mini-player, rows) fetch a smaller file.
    private static let tiers = [50, 75, 100, 150, 200, 300, 400, 600]

    private var pixelSize: Int {
        let needed = points * displayScale
        return CoverImage.tiers.first { CGFloat($0) >= needed } ?? CoverImage.tiers.last!
    }

    var body: some View {
        KFImage(URLBuilder.coverURL(artistName: artistName, albumName: albumName, size: pixelSize))
            .resizable()
            .placeholder { placeholder }
            .fade(duration: 0.2)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary))
    }
}

struct ArtistPhoto: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    let artist: Artist
    /// Display dimension in points; the smallest artist tier covering points × scale
    /// is fetched from one of the artist's album directories.
    var points: CGFloat = 80

    // Sized artist_N.jpg thumbnails available on the server.
    private static let tiers = [50, 200, 420, 840]
    /// Index into `candidates` — advances on a 404 so a missing tier falls back to an
    /// available one instead of showing the placeholder.
    @State private var attempt = 0

    private var pixelSize: Int {
        let needed = points * displayScale
        return ArtistPhoto.tiers.first { CGFloat($0) >= needed } ?? ArtistPhoto.tiers.last!
    }

    /// Ordered fallback chain: the ideal tier first, then larger tiers, then smaller ones,
    /// and finally the full-resolution original. Not every album directory has every sized
    /// `artist_<N>.jpg` generated (some have only a subset), so requesting a single tier
    /// 404s for those artists — we try the others before giving up. Tiers already known to
    /// be missing (a previous 404, remembered across launches) are skipped, so after the
    /// first resolve we go straight to an available size — which Kingfisher has cached on
    /// disk — with no repeated 404 round-trip or placeholder flash.
    private var candidates: [URL] {
        var urls: [URL] = []
        if let album = model.catalog?.firstAlbumName(forArtist: artist.id) {
            let ideal = pixelSize
            let larger = ArtistPhoto.tiers.filter { $0 > ideal }            // ascending
            let smaller = ArtistPhoto.tiers.filter { $0 < ideal }.sorted(by: >)
            for sz in [ideal] + larger + smaller {
                if let u = URLBuilder.artistPhotoURL(artistName: artist.name, albumName: album, size: sz) {
                    urls.append(u)
                }
            }
        }
        if let original = URLBuilder.artistPhotoURL(artist) { urls.append(original) }
        let live = urls.filter { !ArtistPhotoCache.shared.isMissing($0) }
        return live.isEmpty ? urls : live
    }

    var body: some View {
        let list = candidates
        let url = attempt < list.count ? list[attempt] : nil
        KFImage(url)
            .resizable()
            .onFailure { err in
                if let url, ArtistPhotoCache.isPermanentlyMissing(err) {
                    ArtistPhotoCache.shared.markMissing(url)   // remember the 404, don't retry it
                }
                if attempt + 1 < list.count { attempt += 1 }
            }
            .placeholder {
                Circle().fill(.quaternary)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            }
            .aspectRatio(contentMode: .fill)
            .id(url)                                  // reload when the fallback URL changes
            .onChange(of: artist.id) { _, _ in attempt = 0 }   // reset when the row is reused
    }
}

/// Remembers which sized `artist_<N>.jpg` URLs returned 404 so `ArtistPhoto` skips them on
/// future loads instead of re-requesting a tier that doesn't exist. Persisted in
/// UserDefaults, so the avoid-list survives relaunches and the available (Kingfisher-cached)
/// tier loads immediately. Main-thread only (driven from SwiftUI body/onFailure).
@MainActor
final class ArtistPhotoCache {
    static let shared = ArtistPhotoCache()
    private let key = "artistphoto.missing"
    private var missing: Set<String>

    private init() { missing = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func isMissing(_ url: URL) -> Bool { missing.contains(url.absoluteString) }

    func markMissing(_ url: URL) {
        guard missing.insert(url.absoluteString).inserted else { return }
        UserDefaults.standard.set(Array(missing), forKey: key)
    }

    /// True only for a permanent (4xx) HTTP failure — transient/network errors are NOT
    /// remembered, so a tier isn't blacklisted just because the network blipped.
    static func isPermanentlyMissing(_ error: KingfisherError) -> Bool {
        if case .responseError(let reason) = error,
           case .invalidHTTPStatusCode(let response) = reason {
            return (400...499).contains(response.statusCode)
        }
        return false
    }
}

/// Tappable full-screen, pinch-zoomable image viewer (album art / artist photos).
/// Shows the already-cached lower-res image immediately, then swaps in the
/// high-res version in place once it finishes downloading.
struct FullScreenImage: View {
    let url: URL?                       // high-res
    var placeholderURL: URL? = nil      // already-cached lower-res, shown instantly
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Base layer: the already-cached lower-res image, shown instantly (no delay).
            if let placeholderURL {
                KFImage(placeholderURL)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
            }
            // Top layer: the high-res image, transparent until downloaded, then fades in
            // over the cached one.
            KFImage(url)
                .placeholder { Color.clear }
                .fade(duration: 0.25)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, $0) }
                        .onEnded { _ in withAnimation { if scale < 1.05 { scale = 1 } } }
                )
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain).padding()
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}

/// Inline search box, used in place of the navigation-bar `.searchable` so the
/// top bar can be hidden for more vertical space.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    /// Optional external focus binding so a parent can auto-focus the field.
    var focused: FocusState<Bool>.Binding? = nil
    /// Bumped on Clear to force a fresh TextField instance (see the clear button).
    @State private var fieldGen = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // .id(fieldGen): only changes on Clear, so normal typing keeps the same field
            // (and its focus). On Clear we bump it to rebuild the field — see below.
            field.id(fieldGen)
            if !text.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Mac Catalyst won't visually clear a FOCUSED TextField from a programmatic
                        // reset to "" (manual edits work, code-set doesn't; bouncing first-responder
                        // also failed). Bumping .id() discards the stale field and builds a fresh one
                        // bound to the now-empty text, then we re-focus it for continued typing.
                        text = ""
                        fieldGen += 1
                        DispatchQueue.main.async { focused?.wrappedValue = true }
                    }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        if let focused { base.focused(focused) } else { base }
    }
}

struct FavoriteButton: View {
    @EnvironmentObject var user: UserStore
    let kind: String
    let id: Int64
    var body: some View {
        // The dislike (broken-heart) control always sits just to the right of the heart.
        let on = user.isFavorite(kind: kind, id: id)
        HStack(spacing: 12) {
            Button {
                user.toggleFavorite(kind: kind, id: id)
            } label: {
                // Solid heart when favorited, light outline when not — same cropped-to-bounds
                // sizing as the dislike icon beside it.
                Image(on ? "HeartSolid" : "HeartLight")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(on ? Color.pink : Color.secondary)
                    .frame(width: 20, height: 16)
            }
            .buttonStyle(.borderless)
            DislikeButton(kind: kind, id: id)
        }
    }
}

/// "I dislike this" control — a broken-heart icon shown beside every heart. Tapping it
/// marks the song/album/artist as disliked (which the app then hides while "Hide things I
/// dislike" is on); tapping again un-dislikes it. A disliked item shows the SOLID broken
/// heart (only visible when "Hide things I dislike" is off); otherwise the light outline.
struct DislikeButton: View {
    @EnvironmentObject var user: UserStore
    let kind: String
    let id: Int64
    var body: some View {
        let disliked = user.isDisliked(kind: kind, id: id)
        Button {
            user.toggleDislike(kind: kind, id: id)
        } label: {
            // The asset's viewBox is cropped to the heart outline, so it fills this frame —
            // sized to match the favorite heart's height beside it.
            Image(disliked ? "HeartCrackSolid" : "HeartCrackLight")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(disliked ? Color(red: 0.72, green: 0.25, blue: 0.27) : Color.secondary)
                .frame(width: 20, height: 16)
        }
        .buttonStyle(.borderless)
        .help(disliked ? "Disliked — tap to undo" : "I dislike this (hide it)")
    }
}

/// Button (shown beside the heart) that opens an "Add to Playlist" sheet for the
/// given songs. `songIDs` is resolved lazily when tapped.
struct AddToPlaylistButton: View {
    @EnvironmentObject var user: UserStore
    let songIDs: () -> [Int64]
    @State private var show = false
    var body: some View {
        // Add/remove toggle: the minus variant (already on a playlist) removes the songs
        // from all playlists; the plus variant opens the add sheet.
        let ids = songIDs()
        let onPlaylist = ids.contains { user.isOnAnyPlaylist($0) }
        Button {
            if onPlaylist { user.removeSongsFromAllPlaylists(ids) }
            else { show = true }
        } label: {
            Image(onPlaylist ? "PlaylistMinus" : "PlaylistPlus")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Color.secondary)
                .frame(width: 21, height: 18)
        }
        .buttonStyle(.borderless)
        .help(onPlaylist ? "Remove from playlist" : "Add to playlist")
        .sheet(isPresented: $show) { AddToPlaylistSheet(songIDs: ids) }
    }
}

/// Member-only download control. Opens the system browser to download the media in the
/// format chosen in Settings. Renders nothing for non-members.
struct AlbumDownloadButton: View {
    @EnvironmentObject var credentials: Credentials
    @Environment(\.openURL) private var openURL
    let sku: String
    @AppStorage("download.album.format") private var format = "vbr"
    var body: some View {
        if credentials.isMember, !sku.isEmpty {
            Button {
                if let url = URLBuilder.albumMembershipDownloadURL(sku: sku, format: format) { openURL(url) }
            } label: {
                Image("Download").resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(Color.secondary).frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Download album")
        }
    }
}

struct SongDownloadButton: View {
    @EnvironmentObject var credentials: Credentials
    @Environment(\.openURL) private var openURL
    let track: PlayableTrack
    @AppStorage("download.song.format") private var format = "mp3"
    var body: some View {
        if credentials.isMember {
            Button {
                if let url = URLBuilder.songDownloadURL(artistName: track.artistName, albumName: track.album.name, song: track.song, ext: format) { openURL(url) }
            } label: {
                Image("Download").resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(Color.secondary).frame(width: 19, height: 17)
            }
            .buttonStyle(.borderless)
            .help("Download song")
        }
    }
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject var user: UserStore
    @Environment(\.dismiss) private var dismiss
    let songIDs: [Int64]
    @State private var newName = ""
    @State private var rows: [UserStore.PlaylistRow] = []
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Create playlist:") {
                    HStack {
                        TextField("New playlist name", text: $newName)
                            .focused($nameFocused)
                            .textInputAutocapitalization(.words)
                        Button("Create") {
                            let id = user.createPlaylist(name: newName.trimmingCharacters(in: .whitespaces))
                            add(to: id)
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Your playlists") {
                    if rows.isEmpty {
                        Text("No playlists yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { pl in
                            Button { add(to: pl.id) } label: {
                                HStack {
                                    Label(pl.name, systemImage: "music.note.list")
                                    Spacer()
                                    Text("\(pl.count)").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(songIDs.count == 1 ? "Add to Playlist" : "Add \(songIDs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                rows = user.playlists()
                // Brief delay so the sheet is fully presented before we focus (otherwise
                // the focus/keyboard doesn't reliably take on first appearance).
                try? await Task.sleep(nanoseconds: 350_000_000)
                nameFocused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlistID: Int64) {
        for s in songIDs { user.addSong(s, toPlaylist: playlistID) }
        dismiss()
    }
}

/// Row for a song with track number, title, duration, favorite + context menu.
/// Highlights itself when it is the track currently playing.
struct SongRow: View {
    @EnvironmentObject var user: UserStore
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.isPhoneLayout) private var isPhone
    let track: PlayableTrack
    var showArtwork = false
    var hPad: CGFloat = 6     // horizontal inset (0 in search so artwork aligns with the list rows)
    /// Briefly flash-highlighted (e.g. the song just deep-linked from search).
    var isHighlighted = false
    /// Search-nav mode: when set, tapping the artwork / song name / album chip navigates to
    /// the album with this song highlighted (instead of playing the row inline).
    var albumSong: AlbumSong? = nil
    /// Artist for the search-row artist chip (links to the artist page).
    var artistForChip: Artist? = nil
    var onPlay: () -> Void

    private var isCurrent: Bool { audio.current?.id == track.id }
    private var navMode: Bool { albumSong != nil }

    var body: some View {
        let row = HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                if let target = albumSong {
                    NavigationLink(value: target) { songName }.buttonStyle(.plain)
                } else {
                    songName
                }
                if showArtwork {
                    if navMode {
                        // Tappable chips under the song name: artist → artist page,
                        // album → album page (with this song highlighted). Web parity.
                        HStack(spacing: 6) {
                            if let a = artistForChip {
                                NavigationLink(value: a) { chip(a.name, "person") }.buttonStyle(.plain)
                            }
                            if let target = albumSong {
                                NavigationLink(value: target) { chip(track.album.name, "opticaldisc") }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        Text("\(track.artistName) — \(track.album.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Text(track.song.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            FavoriteButton(kind: "song", id: track.song.id)
            SongDownloadButton(track: track)
            AddToPlaylistButton { [track.song.id] }
        }
        .padding(.vertical, 3).padding(.horizontal, hPad)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowFill))
        .contentShape(Rectangle())
        .contextMenu { AddToPlaylistMenu(songID: track.song.id) }
        // Only the play-on-tap rows (album page, favorites, playlists) get the tap gesture;
        // in search-nav mode the artwork / name / chips are their own NavigationLinks.
        if navMode { row } else { row.onTapGesture(perform: onPlay) }
    }

    private var rowFill: Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if isHighlighted { return Color.accentColor.opacity(0.28) }
        return .clear
    }

    private var songName: some View {
        Text(track.song.name).lineLimit(1)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var leading: some View {
        let art = coverDim(40, phone: isPhone)
        if isCurrent {
            Image(systemName: audio.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: showArtwork ? art : 26)
        } else if showArtwork {
            let cover = CoverImage(artistName: track.artistName, albumName: track.album.name, points: 40)
                .frame(width: art, height: art)
            if let target = albumSong {
                NavigationLink(value: target) { cover }.buttonStyle(.plain)
            } else {
                cover
            }
        } else if let n = track.song.trackNo {
            Text("\(n)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        } else {
            Color.clear.frame(width: 26)
        }
    }
}

/// Simple wrapping layout for chips/tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ChipLabel: View {
    let text: String
    var prominent = false
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
    }
}

struct AddToPlaylistMenu: View {
    @EnvironmentObject var user: UserStore
    let songID: Int64
    var body: some View {
        Menu("Add to Playlist") {
            ForEach(user.playlists()) { pl in
                Button(pl.name) { user.addSong(songID, toPlaylist: pl.id) }
            }
            if user.playlists().isEmpty { Text("No playlists yet").foregroundStyle(.secondary) }
        }
    }
}
