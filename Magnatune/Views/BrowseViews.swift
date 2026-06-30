import SwiftUI

// MARK: - Browse sort

/// Sort order for the Albums and Artists browse lists, shown as a menu beside the filter box.
enum BrowseSort: String, CaseIterable, Identifiable {
    case popular, alphabetical, recent   // segmented-control order: Popular · Alphabetical · Date
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: return "Popular"
        case .alphabetical: return "Alphabetical"
        case .recent: return "Date"
        }
    }
}

/// Sort control placed to the right of a `SearchField` — a segmented control showing all three
/// choices at once.
struct SortMenu: View {
    @Binding var sort: BrowseSort
    @Environment(\.isPhoneLayout) private var isPhone
    var body: some View {
        // Narrow / portrait: a compact pull-down menu so it doesn't squeeze the filter box.
        // Wide: the all-choices-visible segmented control.
        if isPhone {
            Menu {
                // List the three choices directly (no nested "Sort" submenu).
                ForEach(BrowseSort.allCases) { opt in
                    Button { sort = opt } label: {
                        if sort == opt {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
        } else {
            Picker("Sort", selection: $sort) {
                ForEach(BrowseSort.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

/// Genre filter placed beside the `SortMenu` on the Artists and Albums browse screens.
/// A pull-down `Menu` (styled like the phone variant of `SortMenu`) whose default choice
/// "Genres" means *all* genres. `options` is the list of genres to offer (already narrowed
/// to the current search by the caller); `selection` is nil for "all".
struct GenrePicker: View {
    var options: [Genre]
    @Binding var selection: Genre?

    var body: some View {
        Menu {
            Button { selection = nil } label: {
                if selection == nil { Label("All Genres", systemImage: "checkmark") } else { Text("All Genres") }
            }
            ForEach(options) { genre in
                Button { selection = genre } label: {
                    if selection == genre {
                        Label(genre.name, systemImage: "checkmark")
                    } else {
                        Text(genre.name)
                    }
                }
            }
        } label: {
            Label(selection?.name ?? "All Genres", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

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
    @State private var sort: BrowseSort = .popular
    @State private var allGenres: [Genre] = []
    @State private var selectedGenre: Genre?

    /// Artists whose NAME matches the current search, ignoring the genre selection. Used both
    /// for the visible rows and to derive which genres the picker should offer.
    private var nameMatched: [Artist] {
        query.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var filtered: [Artist] {
        var base = nameMatched
        if let g = selectedGenre {
            // Read the membership map from the model so it tracks the current catalog
            // (rebuilt on every refresh/hot-swap), never a stale per-view snapshot.
            base = base.filter { model.genresByArtist[$0.id]?.contains(g.id) ?? false }
        }
        return model.visibleArtists(base)
    }

    /// Genres represented among the name-matched artists (so the picker rebuilds per keystroke),
    /// always keeping the current selection so it stays consistent. Empty search → all genres.
    /// Disliked genres are dropped via `visibleGenres` (gated on hideDislikes), the same way
    /// the Genres screen hides them — applied in addition to the search-aware narrowing.
    private var genreOptions: [Genre] {
        let available = model.visibleGenres(allGenres)
        guard !query.isEmpty else { return available }
        var present = Set<Int64>()
        for a in nameMatched { if let gs = model.genresByArtist[a.id] { present.formUnion(gs) } }
        if let sel = selectedGenre { present.insert(sel.id) }
        return available.filter { present.contains($0.id) }
    }

    private func load() {
        guard let c = model.catalog else { return }
        switch sort {
        case .recent: artists = c.artistsByRecent()
        case .alphabetical: artists = c.allArtists()
        case .popular: artists = c.artistsByPopularity()
        }
        allGenres = c.allGenres()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SearchField(text: $query, prompt: "Filter artists")
                GenrePicker(options: genreOptions, selection: $selectedGenre).padding(.trailing, 4).padding(.bottom, 2)
                SortMenu(sort: $sort).padding(.trailing).padding(.bottom, 2)
            }
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
        .task { if artists.isEmpty { load() } }
        .onChange(of: sort) { load() }
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
    @State private var sort: BrowseSort = .popular
    @State private var allGenres: [Genre] = []
    @State private var selectedGenre: Genre?

    private var cols: [GridItem] { [GridItem(.adaptive(minimum: coverDim(150, phone: isPhone)), spacing: 16)] }

    /// Albums whose NAME matches the current search, ignoring the genre selection.
    private var nameMatched: [Album] {
        query.isEmpty ? albums : albums.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var filtered: [Album] {
        var base = nameMatched
        if let g = selectedGenre {
            // Read the membership map from the model so it tracks the current catalog
            // (rebuilt on every refresh/hot-swap), never a stale per-view snapshot.
            base = base.filter { model.genresByAlbum[$0.id]?.contains(g.id) ?? false }
        }
        return model.visibleAlbums(base)
    }

    /// Genres represented among the name-matched albums (rebuilt per keystroke), always
    /// keeping the current selection. Empty search → all genres. Disliked genres are dropped
    /// via `visibleGenres` (gated on hideDislikes), in addition to the search-aware narrowing.
    private var genreOptions: [Genre] {
        let available = model.visibleGenres(allGenres)
        guard !query.isEmpty else { return available }
        var present = Set<Int64>()
        for a in nameMatched { if let gs = model.genresByAlbum[a.id] { present.formUnion(gs) } }
        if let sel = selectedGenre { present.insert(sel.id) }
        return available.filter { present.contains($0.id) }
    }

    private func load() {
        guard let c = model.catalog else { return }
        if names.isEmpty { names = c.artistNames() }
        switch sort {
        case .recent: albums = c.albumsByRecent()
        case .alphabetical: albums = c.allAlbums()
        case .popular: albums = c.albumsByPopularity()
        }
        allGenres = c.allGenres()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SearchField(text: $query, prompt: "Filter albums")
                GenrePicker(options: genreOptions, selection: $selectedGenre).padding(.trailing, 4).padding(.bottom, 2)
                SortMenu(sort: $sort).padding(.trailing).padding(.bottom, 2)
            }
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
        .task { if albums.isEmpty { load() } }
        .onChange(of: sort) { load() }
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
    /// Navigate to a genre. Driven by the parent's NavigationPath (RootView) so this row
    /// needs NO NavigationLink — see the recurring-bug note below.
    var onOpen: (Genre) -> Void

    var body: some View {
        List(model.visibleGenres(genres)) { genre in
            // IMPORTANT (recurring bug — the dislike button kept "vanishing" on Mac
            // Catalyst): do NOT use a NavigationLink for this row. Catalyst draws/reserves
            // a trailing disclosure accessory for a List NavigationLink (even a hidden
            // value-based one) which clips the trailing dislike button. Instead the whole
            // row is a plain tappable HStack (onTapGesture → onOpen) with the dislike
            // button + a manual chevron laid out under our control. If you ever reintroduce
            // a NavigationLink here, VERIFY the broken-heart still shows on every genre row.
            HStack(spacing: 12) {
                Image(systemName: genreIcon(genre.name)).frame(width: 24)
                Text(genre.name)
                Spacer()
                Text("\(model.visibleAlbumCount(forGenre: genre.id))")
                    .font(.callout).foregroundStyle(.secondary)
                DislikeButton(kind: "genre", id: genre.id)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(genre) }
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
                NavigationLink(value: tag) {
                    HStack {
                        Label(tag.name, systemImage: "tag")
                        Spacer()
                        Text("\(model.visibleAlbumCount(forTag: tag.id))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
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
            NavigationLink(value: pl) {
                HStack {
                    Label(pl.name, systemImage: "music.note.list")
                    Spacer()
                    Text("\(model.visibleTrackCount(forCatalogPlaylist: pl.id))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
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
