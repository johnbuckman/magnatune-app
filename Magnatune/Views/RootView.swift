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
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var isCompact = false                     // mirrors layout mode for sheets

    var body: some View {
        GeometryReader { geo in
            // Compact (iPhone) when the width is phone-sized OR the size class is compact.
            // (Mac Catalyst always reports .regular, so the width check drives the
            // iPhone-sized preview window; real iPhones also hit the size-class check.)
            let compact = hSizeClass == .compact || geo.size.width < 600
            Group {
                if compact { compactLayout } else { regularLayout }
            }
            .environment(\.isPhoneLayout, compact)
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { isCompact = compact }
            .onChange(of: compact) { _, v in isCompact = v }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { navHighlight = nil }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(
                onOpenAlbum: { album in
                    showNowPlaying = false
                    DispatchQueue.main.async { path.append(album) }
                },
                onOpenArtist: { album in
                    showNowPlaying = false
                    if let artist = model.catalog?.artist(id: album.artistId) {
                        DispatchQueue.main.async { path.append(artist) }
                    }
                }
            )
            .environment(\.isPhoneLayout, isCompact)
            .environmentObject(model)
            .environmentObject(model.audio)
        }
        .background(MacWindowConfigurator())
        .onAppear { model.startPeerSharingIfNeeded() }
        .alert(model.localNetworkDenied ? "Local Network Access Needed" : "Find Magnatune Players Nearby",
               isPresented: $model.showLocalNetworkPrimer) {
            if model.localNetworkDenied {
                Button("Not Now", role: .cancel) { model.dismissLocalNetworkPrimer() }
                Button("Open Settings") { model.openLocalNetworkSettings() }
            } else {
                Button("Not Now", role: .cancel) { model.declineLocalNetworkPrimer() }
                Button("OK") { model.confirmLocalNetworkPrimer() }
            }
        } message: {
            Text(model.localNetworkDenied
                 ? "Magnatune isn’t allowed to find devices on your local network, so it can’t see other Magnatune apps. To use Share & control, turn on Local Network for Magnatune in Settings."
                 : "Magnatune can see other Magnatune apps on your Wi-Fi, so that when you’re not playing here, this player can show and control what’s playing on another device.\n\nTap OK and iOS will ask permission to find devices on your local network. You can change this any time in Settings.")
        }
    }

    /// Shared navigation stack (content + drill-down destinations), reused by both the
    /// sidebar (regular) and tab-bar (compact) layouts.
    private var mainNavStack: some View {
        NavigationStack(path: $path) {
            content
                .background(InteractivePopGestureEnabler())   // swipe-back works even with hidden nav bar
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).onAppear { highlight(.artists) } }
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: Genre.self) { GenreArtistsView(genre: $0).onAppear { highlight(.genres) } }
                .navigationDestination(for: Tag.self) { TagAlbumsView(tag: $0).onAppear { highlight(.tags) } }
                .navigationDestination(for: CatalogPlaylist.self) { CatalogPlaylistDetailView(playlist: $0).onAppear { highlight(nil) } }
        }
        // Hide the default grouped List background so List pages match the ScrollView pages.
        .scrollContentBackground(.hidden)
    }

    // MARK: Regular layout (Mac / iPad) — floating sidebar card + content column

    private var regularLayout: some View {
        HStack(spacing: 0) {
            // Floating rounded-rectangle sidebar card with a soft drop shadow drawn over
            // the content (zIndex 1).
            sidebar
                .frame(width: 140)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.375), radius: 1.5, x: 0, y: 1)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .zIndex(1)
            VStack(spacing: 0) {
                mainNavStack.frame(maxWidth: .infinity, maxHeight: .infinity)
                MiniPlayer(onExpand: { showNowPlaying = true })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
        // Let the floating cards reach the physical bottom edge (iPad home-indicator area).
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Compact layout (iPhone) — content + docked player + bottom tab bar

    private var compactLayout: some View {
        VStack(spacing: 0) {
            topBar
            mainNavStack.frame(maxWidth: .infinity, maxHeight: .infinity)
            MiniPlayer(onExpand: { showNowPlaying = true })
            tabBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // iPhone: browse-by categories in the top bar; library/search/settings in the bottom bar.
    private var topBarItems: [SidebarItem] { [.popular, .artists, .albums, .songs, .genres, .search] }
    private var compactTabs: [SidebarItem] { [.favorites, .myPlaylists, .tags, .playlists, .settings] }

    private var topBar: some View {
        HStack(spacing: 0) {
            ForEach(topBarItems) { compactBarButton($0) }
        }
        .background(Color(.systemGray6).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(compactTabs) { compactBarButton($0) }
        }
        .padding(.top, 4)
        .background(
            ZStack(alignment: .bottom) {
                Color(.systemGray6)
                // iPhone: drop the wordmark into the home-indicator safe-area space below
                // the tab buttons. It's in the background, so the toolbar isn't moved/resized.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    BrandImage(name: "magnatune_logo")
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 32)
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea(edges: .bottom)   // extend behind home indicator
        )
        .overlay(alignment: .top) { Divider() }
    }

    /// A top-/bottom-bar button: icon above label, tinted when its section is selected.
    private func compactBarButton(_ item: SidebarItem) -> some View {
        let selected = selection == item
        return Button {
            navHighlight = nil
            selection = item
            path = NavigationPath()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon).font(.system(size: 19))
                Text(item.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                // Hidden on iPhone (the sidebar can appear in Max landscape).
                if UIDevice.current.userInterfaceIdiom != .phone {
                    let mh = sidebarHeight * 0.10
                    BrandImage(name: "magnatune_mascot")
                        .frame(width: mh * (1000.0 / 392.0), height: mh)  // aspect-correct
                        .frame(maxWidth: .infinity)                        // center in column
                        .clipped()                                         // clip L/R at edges
                        .offset(y: -(mh * 371.0 / 392.0) - 6)              // line at block top (mascot nudged 6px down)
                        .allowsHitTesting(false)
                }
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
