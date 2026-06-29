import SwiftUI

// MARK: - Popular (albums by popularity)

struct PopularView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isPhoneLayout) private var isPhone
    @State private var sections: [(genre: Genre, albums: [Album])] = []
    @State private var names: [Int64: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(sections, id: \.genre.id) { section in
                    let albums = model.visibleAlbums(section.albums)
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.genre.name).font(.title2.bold())
                            ScrollView(.horizontal, showsIndicators: true) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(albums) { album in
                                        AlbumCell(album: album, artistName: names[album.artistId] ?? "")
                                            .frame(width: coverDim(150, phone: isPhone))
                                    }
                                }
                                .padding(.bottom, 14)
                                .mouseDraggableScroll()   // click-drag to scroll on Mac
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Popular")
        .task { load() }
    }

    private func load() {
        guard sections.isEmpty, let c = model.catalog else { return }
        names = c.artistNames()
        // albums(forGenre:) is already ordered most-popular first.
        sections = c.allGenres().map { genre in
            (genre, c.albums(forGenre: genre.id))
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @EnvironmentObject var model: AppModel
    @State private var artists: [Artist] = []
    @State private var query = ""

    var filtered: [Artist] {
        let base = query.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return model.visibleArtists(base)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Filter artists")
            List(filtered) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 12) {
                        ArtistPhoto(artist: artist, points: 44).frame(width: 44, height: 44).clipShape(Circle())
                            .overlay(Circle().stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
                        Text(artist.name)
                        Spacer()
                        FavoriteButton(kind: "artist", id: artist.id)
                        AddToPlaylistButton { model.catalog?.songs(forArtist: artist.id).map { $0.id } ?? [] }
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .task { if artists.isEmpty { artists = model.catalog?.allArtists() ?? [] } }
    }
}

// MARK: - Albums

struct AlbumCell: View {
    let album: Album
    let artistName: String
    var body: some View {
        NavigationLink(value: album) {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(artistName: artistName, albumName: album.name, points: 150)
                Text(album.name).font(.callout).lineLimit(1)
                Text(artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Grid cell for an artist (circular photo + name), mirroring `AlbumCell`. Used by the
/// artist-page "You might also like" recommendations. The Color.clear overlay trick gives a
/// square that fills the grid column width regardless of the photo's native aspect ratio.
struct ArtistGridCell: View {
    let artist: Artist
    var body: some View {
        NavigationLink(value: artist) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(ArtistPhoto(artist: artist, points: 150))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
                Text(artist.name).font(.callout).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AlbumsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isPhoneLayout) private var isPhone
    @State private var albums: [Album] = []
    @State private var names: [Int64: String] = [:]
    @State private var query = ""

    private var cols: [GridItem] { [GridItem(.adaptive(minimum: coverDim(150, phone: isPhone)), spacing: 16)] }

    var filtered: [Album] {
        let base = query.isEmpty ? albums : albums.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return model.visibleAlbums(base)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Filter albums")
            ScrollView {
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(filtered) { album in
                        AlbumCell(album: album, artistName: names[album.artistId] ?? "")
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Albums")
        .task {
            guard albums.isEmpty, let c = model.catalog else { return }
            names = c.artistNames()
            albums = c.allAlbums()
        }
    }
}

// MARK: - Songs (search-first; full list is large)

struct SongsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var results: [PlayableTrack] = []

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search songs")
            if query.isEmpty {
                // Vertically centered empty state, matching Favorites/Playlists.
                ContentUnavailableView("Search Songs", systemImage: "magnifyingglass",
                                       description: Text("There are ~24,000 tracks. Type to search by title."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = model.visibleTracks(results)
                List {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, track in
                        SongRow(track: track, showArtwork: true) {
                            model.audio.play(tracks: shown, startAt: idx)
                        }
                    }
                }
            }
        }
        .onChange(of: query) { _, q in search(q) }
        .navigationTitle("Songs")
    }

    private func search(_ q: String) {
        guard let c = model.catalog, q.count >= 2 else { results = []; return }
        results = c.makePlayable(songs: c.searchSongs(q, limit: 200))
    }
}

// MARK: - Genres -> Artists

func genreIcon(_ name: String) -> String {
    switch name {
    case "Classical": return "pianokeys"
    case "New Age": return "moon.stars"
    case "Electronica": return "waveform"
    case "World": return "globe"
    case "Ambient": return "wind"
    case "Jazz": return "music.quarternote.3"
    case "Hip Hop": return "music.mic"
    case "Alt Rock": return "guitars"
    case "Electro Rock": return "bolt"
    case "Hard Rock": return "flame"
    default: return "music.note"
    }
}

struct GenresView: View {
    @EnvironmentObject var model: AppModel
    @State private var genres: [Genre] = []

    var body: some View {
        List(model.visibleGenres(genres)) { genre in
            // IMPORTANT (recurring bug): the dislike button must NOT be nested inside a
            // NavigationLink's label — on Mac Catalyst the system disclosure chevron is
            // appended after the label and clips/hides the trailing button, so it
            // "vanishes". Instead drive navigation with a hidden value-based link in the
            // background and lay out the row (icon · name · dislike · manual chevron)
            // on top, fully under our control. If you ever re-simplify this row, VERIFY
            // the broken-heart still shows on every genre row.
            ZStack {
                NavigationLink(value: genre) { EmptyView() }.opacity(0)
                HStack(spacing: 12) {
                    Image(systemName: genreIcon(genre.name)).frame(width: 24)
                    Text(genre.name)
                    Spacer()
                    DislikeButton(kind: "genre", id: genre.id)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
        }
        .navigationTitle("Genres")
        .task { if genres.isEmpty { genres = model.catalog?.allGenres() ?? [] } }
    }
}

struct GenreArtistsView: View {
    @EnvironmentObject var model: AppModel
    let genre: Genre
    @State private var artists: [Artist] = []

    var body: some View {
        List(model.visibleArtists(artists)) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtistPhoto(artist: artist, points: 40).frame(width: 40, height: 40).clipShape(Circle())
                        .overlay(Circle().stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
                    Text(artist.name)
                    Spacer()
                    FavoriteButton(kind: "artist", id: artist.id)
                    AddToPlaylistButton { model.catalog?.songs(forArtist: artist.id).map { $0.id } ?? [] }
                }
            }
        }
        .navigationTitle(genre.name)
        .toolbar(.visible, for: .navigationBar)
        .task { artists = model.catalog?.artists(forGenre: genre.id) ?? [] }
    }
}

// MARK: - Tags (collections)

struct TagsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tags: [Tag] = []
    @State private var query = ""

    var filtered: [Tag] {
        let base = query.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return model.visibleTags(base)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Filter tags")
            List(filtered) { tag in
                NavigationLink(value: tag) { Label(tag.name, systemImage: "tag") }
            }
        }
        .navigationTitle("Tags")
        .task { if tags.isEmpty { tags = model.catalog?.allTags() ?? [] } }
    }
}

struct TagAlbumsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isPhoneLayout) private var isPhone
    let tag: Tag
    @State private var albums: [Album] = []
    @State private var names: [Int64: String] = [:]
    private var cols: [GridItem] { [GridItem(.adaptive(minimum: coverDim(150, phone: isPhone)), spacing: 16)] }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(model.visibleAlbums(albums)) { album in
                    AlbumCell(album: album, artistName: names[album.artistId] ?? "")
                }
            }
            .padding()
        }
        .navigationTitle(tag.name)
        .toolbar(.visible, for: .navigationBar)
        .task {
            guard let c = model.catalog else { return }
            names = c.artistNames()
            albums = c.albums(forTag: tag.id)
        }
    }
}

// MARK: - Magnatune-curated Playlists

struct CatalogPlaylistsView: View {
    @EnvironmentObject var model: AppModel
    @State private var playlists: [CatalogPlaylist] = []

    var body: some View {
        List(model.visibleCatalogPlaylists(playlists)) { pl in
            NavigationLink(value: pl) { Label(pl.name, systemImage: "music.note.list") }
        }
        .navigationTitle("Playlists")
        .task { if playlists.isEmpty { playlists = model.catalog?.catalogPlaylists() ?? [] } }
    }
}

struct CatalogPlaylistDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    let playlist: CatalogPlaylist
    @State private var tracks: [PlayableTrack] = []

    var body: some View {
        let shown = model.visibleTracks(tracks)
        List {
            if shown.isEmpty {
                ContentUnavailableView("Empty", systemImage: "music.note.list")
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, t in
                    SongRow(track: t, showArtwork: true) { audio.play(tracks: shown, startAt: idx) }
                }
            }
        }
        .navigationTitle(playlist.name)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !shown.isEmpty {
                Button { audio.play(tracks: shown, startAt: 0) } label: { Image(systemName: "play.fill") }
            }
        }
        .task {
            guard let c = model.catalog else { return }
            tracks = c.makePlayable(songs: c.songs(forCatalogPlaylist: playlist.id))
        }
    }
}
