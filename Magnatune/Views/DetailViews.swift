import SwiftUI
import UIKit

struct ArtistDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.isPhoneLayout) private var isPhone
    private let passedArtist: Artist
    @State private var resolvedArtist: Artist?
    /// The artist as it is in the current catalog (see `CatalogStore.current`).
    private var artist: Artist { resolvedArtist ?? passedArtist }
    init(artist: Artist) { passedArtist = artist }
    @State private var albums: [Album] = []
    @State private var tracks: [PlayableTrack] = []
    @State private var recommended: [Artist] = []
    @State private var genres: [Genre] = []
    @State private var tags: [Tag] = []
    @State private var showPhoto = false
    private var cols: [GridItem] { [GridItem(.adaptive(minimum: coverDim(150, phone: isPhone)), spacing: 16)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    ArtistPhoto(artist: artist, points: 120)
                        .frame(width: 120, height: 120).clipShape(Circle())
                        .overlay(Circle().stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
                        .onTapGesture { showPhoto = true }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist.name).font(.largeTitle.bold())
                        // "Based in" line (city/state/country) — restored from the catalog,
                        // matching the web player. Shows nothing when the dump carries no location.
                        if let loc = artist.locationText {
                            Label(loc, systemImage: "location.fill")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            let shown = model.visibleTracks(tracks)
                            let nowPlaying = audio.isPlaying && audio.current?.album.artistId == artist.id
                            Button {
                                audio.play(tracks: shown, startAt: 0)   // all songs across this artist's albums
                            } label: {
                                if isPhone { Image(systemName: nowPlaying ? "speaker.wave.2.fill" : "play.fill") }
                                else { Label(nowPlaying ? "Now Playing" : "Play", systemImage: nowPlaying ? "speaker.wave.2.fill" : "play.fill").frame(minWidth: 120) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(shown.isEmpty)
                            FavoriteButton(kind: "artist", id: artist.id)
                            AddToPlaylistButton { model.catalog?.songs(forArtist: artist.id).map { $0.id } ?? [] }
                        }
                    }
                    Spacer()
                }
                DownloadSummaryLabel(songIDs: tracks.map { $0.song.id })
                if let bio = artist.bio ?? artist.description, !bio.isEmpty {
                    ExpandableText(text: bio)
                }
                if !genres.isEmpty || !tags.isEmpty {
                    WrapChips(spacing: 8) {
                        ForEach(genres) { g in
                            NavLink(value: g) { ChipLabel(text: g.name, prominent: true) }
                                .buttonStyle(.plain)
                        }
                        ForEach(tags) { tag in
                            NavLink(value: tag) { ChipLabel(text: tag.name) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                Text("Albums").font(.title2.bold())
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(model.visibleAlbums(albums)) { album in
                        AlbumCell(album: album, artistName: artist.name)
                    }
                }
                let recArtists = model.visibleArtists(recommended)
                if !recArtists.isEmpty {
                    Divider()
                    Text("You might also like").font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(recArtists) { other in
                                ArtistGridCell(artist: other)
                                    .frame(width: coverDim(105, phone: isPhone))   // ~30% smaller than album recs (150)
                            }
                        }
                        .padding(.bottom, 14)
                        .mouseDraggableScroll()   // click-drag to scroll on Mac
                    }
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .navBar(hidden: false)
        .fullScreenCover(isPresented: $showPhoto) {
            // Sized thumbnail (artist_840, a few KB) with a smaller one shown instantly;
            // falls back to the full-resolution original if the artist has no album.
            FullScreenImage(
                url: albums.first.flatMap { URLBuilder.artistPhotoURL(artistName: artist.name, albumName: $0.name, size: 840) }
                    ?? URLBuilder.artistPhotoURL(artist),
                placeholderURL: albums.first.flatMap { URLBuilder.artistPhotoURL(artistName: artist.name, albumName: $0.name, size: 200) })
        }
        .task { load() }
        .onChange(of: model.catalogGeneration) { _ in load() }
    }

    private func load() {
        guard let c = model.catalog else { return }
        let a = c.current(passedArtist)
        resolvedArtist = a
        albums = c.albums(forArtist: a.id)
        tracks = c.makePlayable(songs: c.songs(forArtist: a.id))
        recommended = c.recommendedArtists(forArtist: a.id)
        let gt = c.genresAndTags(forArtist: a.id)
        genres = gt.genres
        tags = gt.tags
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.isPhoneLayout) private var isPhone
    private let passedAlbum: Album
    @State private var resolvedAlbum: Album?
    /// The album as it is in the current catalog (see `CatalogStore.current`).
    private var album: Album { resolvedAlbum ?? passedAlbum }
    /// When set (arriving from a search result), scroll to this song and briefly highlight it.
    var highlightSongID: Int64? = nil
    init(album: Album, highlightSongID: Int64? = nil) {
        passedAlbum = album
        self.highlightSongID = highlightSongID
    }
    @State private var tracks: [PlayableTrack] = []
    @State private var artist: Artist?
    @State private var artistName: String = ""
    @State private var genres: [Genre] = []
    @State private var tags: [Tag] = []
    @State private var recommended: [Album] = []
    @State private var recommendedNames: [Int64: String] = [:]
    @State private var showCover = false
    @State private var highlightedID: Int64?
    @State private var width: CGFloat = 1000
    /// Buttons on their own line under the cover: always on a phone, and in any column too
    /// narrow for them beside it (they'd widen the page past the screen edges).
    private var stackButtons: Bool { isPhone || width < 760 }

    var body: some View {
        let shown = model.visibleTracks(tracks)
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(artistName: artistName, albumName: album.name, points: 200)
                        .frame(width: coverDim(200, phone: isPhone), height: coverDim(200, phone: isPhone))
                        .onTapGesture { showCover = true }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.name).font(.largeTitle.bold())
                        if let artist {
                            NavLink(value: artist) {
                                Text(artistName).font(.title3).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(artistName).font(.title3).foregroundStyle(.secondary)
                        }
                        if let d = album.releaseDateValue {
                            Text(d.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DownloadSummaryLabel(songIDs: tracks.map { $0.song.id })
                        if !stackButtons { actionButtons(shown) }
                    }
                    Spacer(minLength: 0)
                }
                // On a phone (or a narrow column) the buttons don't fit beside the cover: the row
                // made the page wider than the screen, so it was centred off both edges.
                if stackButtons { actionButtons(shown) }
                VStack(alignment: .leading, spacing: 6) {
                    if let desc = album.description, !desc.isEmpty {
                        ExpandableText(text: desc)
                    }
                    if !genres.isEmpty || !tags.isEmpty {
                        WrapChips(spacing: 8) {
                            ForEach(genres) { g in
                                NavLink(value: g) { ChipLabel(text: g.name, prominent: true) }
                                    .buttonStyle(.plain)
                            }
                            ForEach(tags) { tag in
                                NavLink(value: tag) { ChipLabel(text: tag.name) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Divider()
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, track in
                    SongRow(track: track, isHighlighted: highlightedID == track.id) { audio.play(tracks: shown, startAt: idx) }
                        .id(track.id)
                    Divider()
                }
                let recAlbums = model.visibleAlbums(recommended)
                if !recAlbums.isEmpty {
                    Text("You might also like").font(.title2.bold())
                        .padding(.top, 16)   // extra space above the heading (matches the web <br>)
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(recAlbums) { rec in
                                AlbumCell(album: rec, artistName: recommendedNames[rec.artistId] ?? "")
                                    .frame(width: coverDim(150, phone: isPhone))
                            }
                        }
                        .padding(.bottom, 14)
                        .mouseDraggableScroll()   // click-drag to scroll on Mac
                    }
                }
            }
            .padding()
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = $0 }
        })
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .navBar(hidden: false)
        .fullScreenCover(isPresented: $showCover) {
            FullScreenImage(
                url: URLBuilder.coverURL(artistName: artistName, albumName: album.name, size: 1400),
                placeholderURL: URLBuilder.coverURL(artistName: artistName, albumName: album.name, size: 600))
        }
        .task {
            load()
            // Deep-linked from a search result: scroll the song into view and flash-highlight
            // it. Does NOT auto-play. Brief delay so the song rows have laid out first.
            guard let h = highlightSongID else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation { proxy.scrollTo(h, anchor: .center) }
            withAnimation { highlightedID = h }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation { highlightedID = nil }
        }
        .onChange(of: model.catalogGeneration) { _ in load() }
        }
    }

    @ViewBuilder private func actionButtons(_ shown: [PlayableTrack]) -> some View {
        HStack {
            let nowPlaying = audio.isPlaying && audio.current?.album.id == album.id
            Button {
                audio.play(tracks: shown, startAt: 0)
            } label: {
                if isPhone { Image(systemName: nowPlaying ? "speaker.wave.2.fill" : "play.fill") }
                else { Label(nowPlaying ? "Now Playing" : "Play", systemImage: nowPlaying ? "speaker.wave.2.fill" : "play.fill").frame(minWidth: 120) }
            }
                .buttonStyle(.borderedProminent)
                .disabled(shown.isEmpty)
            FavoriteButton(kind: "album", id: album.id)
            AlbumDownloadButton(sku: album.sku)
            AlbumBuyButton(sku: album.sku, compact: isPhone)
            AddToPlaylistButton { shown.map { $0.song.id } }
        }
    }

    private func load() {
        guard let c = model.catalog else { return }
        let al = c.current(passedAlbum)
        resolvedAlbum = al
        artist = c.artist(id: al.artistId)
        artistName = artist?.name ?? ""
        tracks = c.makePlayable(songs: c.songs(forAlbum: al.id))
        let gt = c.genresAndTags(forAlbum: al.id)
        genres = gt.genres
        tags = gt.tags
        recommended = c.recommendedAlbums(forAlbum: al.id)
        recommendedNames = c.artistNames()
    }
}

/// Secondary body text clamped to `lineLimit` lines with a "Show more"/"Show less" toggle
/// that appears ONLY when the text is actually longer than the limit. Mirrors the web
/// app's click-to-expand artist bio / album description.
struct ExpandableText: View {
    let text: String
    var lineLimit: Int = 4
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            guard geo.size.width > 1 else { return }
                            let fullH = (text as NSString).boundingRect(
                                with: CGSize(width: geo.size.width, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
                                context: nil).height
                            if fullH > geo.size.height + 1 { truncated = true }
                        }
                    }
                )
            if truncated {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }
        }
    }
}
