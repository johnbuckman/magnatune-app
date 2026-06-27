import SwiftUI

struct ArtistDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.isPhoneLayout) private var isPhone
    let artist: Artist
    @State private var albums: [Album] = []
    @State private var tracks: [PlayableTrack] = []
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
                if let bio = artist.bio ?? artist.description, !bio.isEmpty {
                    Text(bio).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Albums").font(.title2.bold())
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(model.visibleAlbums(albums)) { album in
                        AlbumCell(album: album, artistName: artist.name)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showPhoto) {
            // Sized thumbnail (artist_840, a few KB) with a smaller one shown instantly;
            // falls back to the full-resolution original if the artist has no album.
            FullScreenImage(
                url: albums.first.flatMap { URLBuilder.artistPhotoURL(artistName: artist.name, albumName: $0.name, size: 840) }
                    ?? URLBuilder.artistPhotoURL(artist),
                placeholderURL: albums.first.flatMap { URLBuilder.artistPhotoURL(artistName: artist.name, albumName: $0.name, size: 200) })
        }
        .task {
            albums = model.catalog?.albums(forArtist: artist.id) ?? []
            if let c = model.catalog {
                tracks = c.makePlayable(songs: c.songs(forArtist: artist.id))
            }
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.isPhoneLayout) private var isPhone
    let album: Album
    @State private var tracks: [PlayableTrack] = []
    @State private var artist: Artist?
    @State private var artistName: String = ""
    @State private var genres: [Genre] = []
    @State private var tags: [Tag] = []
    @State private var showCover = false

    var body: some View {
        let shown = model.visibleTracks(tracks)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(artistName: artistName, albumName: album.name, points: 200)
                        .frame(width: coverDim(200, phone: isPhone), height: coverDim(200, phone: isPhone))
                        .onTapGesture { showCover = true }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.name).font(.largeTitle.bold())
                        if let artist {
                            NavigationLink(value: artist) {
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
                            Button {
                                audio.shuffleEnabled.toggle()   // on/off mode, doesn't start playback
                            } label: {
                                Image(audio.shuffleEnabled ? "ShufOn" : "ShufOff")
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .frame(width: 22, height: 21)
                            }
                                .buttonStyle(.bordered)
                                .tint(audio.shuffleEnabled ? Color.accentColor : .secondary)
                                .help(audio.shuffleEnabled ? "Shuffle on" : "Shuffle off")
                            FavoriteButton(kind: "album", id: album.id)
                            AddToPlaylistButton { shown.map { $0.song.id } }
                        }
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let desc = album.description, !desc.isEmpty {
                        Text(desc).font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !genres.isEmpty || !tags.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(genres) { g in
                                NavigationLink(value: g) { ChipLabel(text: g.name, prominent: true) }
                                    .buttonStyle(.plain)
                            }
                            ForEach(tags) { tag in
                                NavigationLink(value: tag) { ChipLabel(text: tag.name) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Divider()
                ForEach(Array(shown.enumerated()), id: \.element.id) { idx, track in
                    SongRow(track: track) { audio.play(tracks: shown, startAt: idx) }
                    Divider()
                }
            }
            .padding()
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showCover) {
            FullScreenImage(
                url: URLBuilder.coverURL(artistName: artistName, albumName: album.name, size: 1400),
                placeholderURL: URLBuilder.coverURL(artistName: artistName, albumName: album.name, size: 600))
        }
        .task { load() }
    }

    private func load() {
        guard let c = model.catalog else { return }
        artist = c.artist(id: album.artistId)
        artistName = artist?.name ?? ""
        tracks = c.makePlayable(songs: c.songs(forAlbum: album.id))
        let gt = c.genresAndTags(forAlbum: album.id)
        genres = gt.genres
        tags = gt.tags
    }
}
