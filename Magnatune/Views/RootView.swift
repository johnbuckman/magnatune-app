import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case popular, artists, albums, genres, tags, playlists, songs
    case favorites, myPlaylists
    case search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: return "Popular"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .genres: return "Genres"
        case .tags: return "Tags"
        case .playlists: return "Featured"
        case .songs: return "Songs"
        case .favorites: return "Favorites"
        case .myPlaylists: return "Playlists"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .popular: return "flame"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
        case .tags: return "tag"
        case .playlists: return "star"
        case .songs: return "music.note"
        case .favorites: return "heart"
        case .myPlaylists: return "music.note.list"
        case .search: return "magnifyingglass"
        case .settings: return "gear"
        }
    }

    static let browse: [SidebarItem] = [.popular, .artists, .albums, .genres, .tags, .playlists, .songs]
    static let library: [SidebarItem] = [.favorites, .myPlaylists]
    static let app: [SidebarItem] = [.settings]   // Search moved up under the library group
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var audio: AudioPlayer
    @State private var selection: SidebarItem = .popular     // drives the detail root
    @State private var navHighlight: SidebarItem? = nil      // visual-only override while drilled in
    @State private var path = NavigationPath()
    @State private var showNowPlaying = false
    @State private var sidebarHeight: CGFloat = 800          // measured column height

    var body: some View {
        // Manual two-column layout (NOT NavigationSplitView): a fixed sidebar column
        // and a content column that OWNS the player. This guarantees the player is
        // confined to the content column — NavigationSplitView lets a bottom bar span
        // the full window under the sidebar, which we don't want.
        HStack(spacing: 0) {
            // Floating rounded-rectangle sidebar card: material fill, rounded corners,
            // inset on all sides, with a soft drop shadow. zIndex(1) draws it above the
            // content so the shadow falls over the content's left edge.
            sidebar
                .frame(width: 200)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .zIndex(1)
            VStack(spacing: 0) {
                NavigationStack(path: $path) {
                    content
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).onAppear { highlight(.artists) } }
                        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0).onAppear { highlight(nil) } }
                        .navigationDestination(for: Genre.self) { GenreArtistsView(genre: $0).onAppear { highlight(.genres) } }
                        .navigationDestination(for: Tag.self) { TagAlbumsView(tag: $0).onAppear { highlight(.tags) } }
                        .navigationDestination(for: CatalogPlaylist.self) { CatalogPlaylistDetailView(playlist: $0).onAppear { highlight(nil) } }
                }
                // Lists draw a darker grouped background by default; hide it so List-based
                // pages (Artists/Genres/Tags/Songs/Featured) match the ScrollView pages.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                MiniPlayer(onExpand: { showNowPlaying = true })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
        // On iPad the home-indicator safe area would push the floating sidebar
        // and mini-player cards up, leaving a white gap below them. Mac Catalyst
        // has no bottom safe area, so it already fills. Ignoring the bottom safe
        // area makes both behave like the Mac: the cards float their intended
        // small inset (10–12pt) from the physical bottom edge on every device.
        .ignoresSafeArea(.container, edges: .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { navHighlight = nil }
        }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        .background(MacWindowConfigurator())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                BrandImage(name: "magnatune_logo")
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .padding(.top, 30).padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SidebarItem.browse) { sidebarRow($0) }
                    Color.clear.frame(height: 14)
                    ForEach(SidebarItem.library) { sidebarRow($0) }
                    Color.clear.frame(height: 14)
                    sidebarRow(.search)
                }
                .padding(.horizontal, 8).padding(.top, 10)
            }

            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(SidebarItem.app) { sidebarRow($0) }
            }
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 12)
            .overlay(alignment: .top) {
                // Mascot has its own horizontal line baked in (row 371/392). Size by
                // height = 10% of the column, center it, and clip the sides at the
                // column edges. The baked-in line lands at the top of the Search block.
                let mh = sidebarHeight * 0.10
                BrandImage(name: "magnatune_mascot")
                    .frame(width: mh * (1000.0 / 392.0), height: mh)  // aspect-correct
                    .frame(maxWidth: .infinity)                        // center in column
                    .clipped()                                         // clip L/R at edges
                    .offset(y: -(mh * 371.0 / 392.0) - 6)              // line at block top (mascot nudged 6px down)
                    .allowsHitTesting(false)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { sidebarHeight = g.size.height }
                .onChange(of: g.size.height) { _, h in sidebarHeight = h }
        })
        .focusEffectDisabled()
    }

    /// A sidebar row. We draw the highlight ourselves (not via List selection) so that
    /// reflecting a drill-down never changes the NavigationSplitView's sidebar selection,
    /// which would otherwise reset the detail navigation stack.
    private func sidebarRow(_ item: SidebarItem) -> some View {
        let highlighted = (navHighlight ?? selection) == item
        return Button {
            // Always act: switch section (if needed) and pop any drill-down back to the
            // section root, so tapping the current section while deep in it still works.
            navHighlight = nil
            selection = item
            path = NavigationPath()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .frame(width: 22)            // fixed icon column → text always aligns
                Text(item.title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(labelColor(item))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.accentColor.opacity(0.22) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Browse/library sections that can't offer un-downloaded content offline are
    /// shown in light grey while offline. Favorites (your downloads), Search and
    /// Settings stay at full strength.
    private static let greyWhenOffline: Set<SidebarItem> =
        [.popular, .artists, .albums, .genres, .tags, .playlists, .songs, .myPlaylists]

    private func labelColor(_ item: SidebarItem) -> Color {
        if !model.isOnline && RootView.greyWhenOffline.contains(item) {
            return Color(uiColor: .tertiaryLabel)
        }
        return .primary
    }

    /// Update the sidebar highlight after the push settles (deferred to avoid mutating
    /// state mid-navigation).
    private func highlight(_ item: SidebarItem?) {
        DispatchQueue.main.async { navHighlight = item }
    }

    @ViewBuilder private var content: some View {
        if !model.catalogReady {
            ContentUnavailableView("Loading catalog…", systemImage: "music.note")
        } else {
            switch selection {
            case .popular: PopularView()
            case .artists: ArtistsView()
            case .albums: AlbumsView()
            case .genres: GenresView()
            case .tags: TagsView()
            case .playlists: CatalogPlaylistsView()
            case .songs: SongsView()
            case .favorites: FavoritesView()
            case .myPlaylists: PlaylistsView()
            case .search: SearchView()
            case .settings: SettingsView()
            }
        }
    }
}
