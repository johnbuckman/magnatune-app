import SwiftUI

// MARK: - Search (artists + albums + songs)

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var songs: [PlayableTrack] = []
    @State private var names: [Int64: String] = [:]

    var body: some View {
        let vArtists = model.visibleArtists(artists)
        let vAlbums = model.visibleAlbums(albums)
        let vSongs = model.visibleTracks(songs)
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Artists, albums, songs")
            List {
                if !vArtists.isEmpty {
                    Section("Artists") {
                        ForEach(vArtists) { a in
                            NavigationLink(value: a) { Label(a.name, systemImage: "person") }
                        }
                    }
                }
                if !vAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(vAlbums) { al in
                            NavigationLink(value: al) {
                                Text("\(al.name) — \(names[al.artistId] ?? "")")
                            }
                        }
                    }
                }
                if !vSongs.isEmpty {
                    Section("Songs") {
                        ForEach(Array(vSongs.enumerated()), id: \.element.id) { idx, t in
                            SongRow(track: t, showArtwork: true) { model.audio.play(tracks: vSongs, startAt: idx) }
                        }
                    }
                }
                if query.count >= 2, vArtists.isEmpty, vAlbums.isEmpty, vSongs.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .onChange(of: query) { _, q in search(q) }
        .navigationTitle("Search")
    }

    private func search(_ q: String) {
        guard let c = model.catalog, q.count >= 2 else { artists = []; albums = []; songs = []; return }
        if names.isEmpty { names = c.artistNames() }
        artists = c.searchArtists(q, limit: 20)
        albums = c.searchAlbums(q, limit: 20)
        songs = c.makePlayable(songs: c.searchSongs(q, limit: 50))
    }
}

// MARK: - Favorites

struct FavoritesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var user: UserStore
    @State private var songs: [PlayableTrack] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var names: [Int64: String] = [:]
    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        let vArtists = model.visibleArtists(artists)
        let vAlbums = model.visibleAlbums(albums)
        let vSongs = model.visibleTracks(songs)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !vArtists.isEmpty {
                    header("Artists") { playFavoriteArtists() }
                    ForEach(vArtists) { a in
                        NavigationLink(value: a) {
                            HStack {
                                ArtistPhoto(artist: a).frame(width: 36, height: 36).clipShape(Circle())
                                Text(a.name)
                                Spacer()
                                FavoriteButton(kind: "artist", id: a.id)   // tap to remove
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !vAlbums.isEmpty {
                    header("Albums") { playFavoriteAlbums() }
                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(vAlbums) { al in
                            AlbumCell(album: al, artistName: names[al.artistId] ?? "")
                                .overlay(alignment: .topTrailing) {
                                    FavoriteButton(kind: "album", id: al.id)   // tap to remove
                                        .padding(6)
                                        .background(.regularMaterial, in: Circle())
                                        .padding(6)
                                }
                        }
                    }
                }
                if !vSongs.isEmpty {
                    header("Songs") { model.audio.play(tracks: vSongs, startAt: 0) }
                    ForEach(Array(vSongs.enumerated()), id: \.element.id) { idx, t in
                        SongRow(track: t, showArtwork: true) { model.audio.play(tracks: vSongs, startAt: idx) }
                    }
                }
                if vSongs.isEmpty && vAlbums.isEmpty && vArtists.isEmpty {
                    ContentUnavailableView("No Favorites Yet", systemImage: "heart",
                                           description: Text(model.isOnline
                                               ? "Tap the heart on any song, album, or artist."
                                               : "You're offline. Favorites you've downloaded will appear here."))
                        .padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle("Favorites")
        .task(id: favSignature) { load() }
    }

    private func header(_ title: String, play: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.title2.bold())
            Button(action: play) {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .help("Play all favorite \(title.lowercased())")
            Spacer()
        }
    }

    private var favSignature: String {
        "\(user.favoriteSongIDs.count)-\(user.favoriteAlbumIDs.count)-\(user.favoriteArtistIDs.count)"
    }

    /// Play every track from all favorite albums, in album order (downloaded only when offline).
    private func playFavoriteAlbums() {
        guard let c = model.catalog else { return }
        let allSongs = model.visibleSongs(albums.flatMap { c.songs(forAlbum: $0.id) })
        model.playSongs(allSongs, startAt: 0)
    }

    /// Play every track from all favorite artists' albums (downloaded only when offline).
    private func playFavoriteArtists() {
        guard let c = model.catalog else { return }
        let allSongs = model.visibleSongs(artists
            .flatMap { c.albums(forArtist: $0.id) }
            .flatMap { c.songs(forAlbum: $0.id) })
        model.playSongs(allSongs, startAt: 0)
    }

    private func load() {
        guard let c = model.catalog else { return }
        if names.isEmpty { names = c.artistNames() }
        artists = user.favoriteIDs(kind: "artist").compactMap { c.artist(id: $0) }
        albums = user.favoriteIDs(kind: "album").compactMap { c.album(id: $0) }
        songs = c.makePlayable(songs: user.favoriteIDs(kind: "song").compactMap { c.song(id: $0) })
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @EnvironmentObject var user: UserStore
    @State private var rows: [UserStore.PlaylistRow] = []
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("No Playlists Yet", systemImage: "music.note.list",
                                       description: Text("Tap + to create a playlist, then add songs from the … menu on any track."))
            } else {
                List {
                    ForEach(rows) { pl in
                        NavigationLink { PlaylistDetailView(playlistID: pl.id, name: pl.name) } label: {
                            HStack { Label(pl.name, systemImage: "music.note.list"); Spacer(); Text("\(pl.count)").foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { idx in
                        idx.map { rows[$0].id }.forEach { user.deletePlaylist(id: $0) }
                        reload()
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Button { newName = ""; showNew = true } label: { Image(systemName: "plus") }
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { if !newName.isEmpty { user.createPlaylist(name: newName); reload() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { reload() }
    }

    private func reload() { rows = user.playlists() }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var user: UserStore
    let playlistID: Int64
    let name: String
    @State private var tracks: [PlayableTrack] = []

    var body: some View {
        let shown = model.visibleTracks(tracks)
        List {
            if shown.isEmpty {
                ContentUnavailableView("Empty", systemImage: "music.note.list",
                                       description: Text(model.isOnline
                                           ? "Add songs from the … menu on any track."
                                           : "You're offline — none of this playlist's songs are downloaded."))
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, t in
                    SongRow(track: t, showArtwork: true) { model.audio.play(tracks: shown, startAt: idx) }
                }
                .onDelete { idx in
                    idx.map { shown[$0].song.id }.forEach { user.removeItem(songID: $0, fromPlaylist: playlistID) }
                    load()
                }
            }
        }
        .navigationTitle(name)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !shown.isEmpty {
                Button { model.audio.play(tracks: shown, startAt: 0) } label: { Image(systemName: "play.fill") }
            }
        }
        .task { load() }
    }

    private func load() {
        guard let c = model.catalog else { return }
        tracks = c.makePlayable(songs: user.songIDs(inPlaylist: playlistID).compactMap { c.song(id: $0) })
    }
}
