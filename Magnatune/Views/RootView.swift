import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case popular, artists, albums, genres, tags, playlists, songs
    case favorites, myPlaylists
    case search, settings, help

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
        case .help: return "Help"
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
        case .help: return "questionmark.circle"
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
    @State private var didRestorePath = false                // one-shot guard for restoring the drill-down

    private static let kSection = "nav.section"
    private static let kPath = "nav.path"

    init() {
        // Restore the top-level page immediately (no flash of Popular). The drill-down is
        // restored later, once the catalog is ready (see restoreNavPathIfNeeded()).
        let saved = UserDefaults.standard.string(forKey: Self.kSection)
        _selection = State(initialValue: SidebarItem(rawValue: saved ?? "") ?? .popular)
    }

    var body: some View {
        GeometryReader { geo in
            // Compact (iPhone) when the width is phone-sized OR the size class is compact.
            // (Mac Catalyst always reports .regular, so the width check drives the
            // iPhone-sized preview window; real iPhones also hit the size-class check.)
            // 700, not 600: the regular layout's player controls overflow the right
            // edge around ~640pt, so switch to the compact layout before that.
            let compact = hSizeClass == .compact || geo.size.width < 700
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
            persistPath(newPath)
        }
        .onChange(of: selection) { _, s in
            UserDefaults.standard.set(s.rawValue, forKey: Self.kSection)
        }
        .onChange(of: model.catalogReady) { _, ready in
            if ready { restoreNavPathIfNeeded() }
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
        .onAppear { model.resumePeerSharingIfGranted(); restoreNavPathIfNeeded() }
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
                .navigationDestination(for: AlbumSong.self) { AlbumDetailView(album: $0.album, highlightSongID: $0.songID).onAppear { highlight(nil) } }
                .navigationDestination(for: Genre.self) { GenreArtistsView(genre: $0).onAppear { highlight(.genres) } }
                .navigationDestination(for: Tag.self) { TagAlbumsView(tag: $0).onAppear { highlight(.tags) } }
                .navigationDestination(for: CatalogPlaylist.self) { CatalogPlaylistDetailView(playlist: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: UserPlaylistRef.self) { PlaylistDetailView(playlistID: $0.id, name: $0.name).onAppear { highlight(.myPlaylists) } }
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
                .frame(width: 168)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.375), radius: 1.5, x: 0, y: 1)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 12)
                .zIndex(1)
            VStack(spacing: 0) {
                mainNavStack.frame(maxWidth: .infinity, maxHeight: .infinity)
                // Match the web app's perfect 12px gutters around the player.
                // Player card insets are internally 10 (right/bottom) and the gap to
                // the sidebar is 8 (sidebar .trailing) + 10 (player .leading) = 18.
                // So: +2 bottom & +2 trailing → 12; -6 leading → 12 gap. All 12pt.
                MiniPlayer(onExpand: { showNowPlaying = true })
                    .padding(.bottom, 2)
                    .padding(.trailing, 2)
                    .padding(.leading, -6)
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
                    // Tap the mascot to open in-app help. contentShape is on the
                    // mascot-width frame (before the centering frame) so only the
                    // visible mascot is tappable, not the full-width column strip.
                    Button { showHelp() } label: {
                        BrandImage(name: "magnatune_mascot")
                            .frame(width: mh * (1000.0 / 392.0), height: mh)  // aspect-correct
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity)                        // center in column
                            .clipped()                                         // clip L/R at edges
                    }
                    .buttonStyle(.plain)
                    .offset(y: -(mh * 371.0 / 392.0) - 6)              // line at block top (mascot nudged 6px down)
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)   // never wrap the label
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

    /// Show the Help page in the content area, like selecting any sidebar section.
    /// Used by both the mascot tap and Settings → "App Help".
    private func showHelp() {
        navHighlight = nil
        selection = .help
        path = NavigationPath()
    }

    /// Update the sidebar highlight after the push settles (deferred to avoid mutating
    /// state mid-navigation).
    private func highlight(_ item: SidebarItem?) {
        DispatchQueue.main.async { navHighlight = item }
    }

    /// Persist the current drill-down (encoded NavigationPath) so the app reopens on the
    /// same page. Saved on every push/pop; the section is saved separately on change.
    private func persistPath(_ p: NavigationPath) {
        if let c = p.codable, let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.kPath)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.kPath)
        }
    }

    /// Restore the saved drill-down once, after the catalog is ready (the detail views
    /// resolve their content from it). The section was already restored in init().
    private func restoreNavPathIfNeeded() {
        guard !didRestorePath, model.catalogReady else { return }
        didRestorePath = true
        guard let data = UserDefaults.standard.data(forKey: Self.kPath),
              let rep = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
        else { return }
        path = NavigationPath(rep)
    }

    @ViewBuilder private var content: some View {
        if !model.catalogReady {
            // Startup screen: the mascot with clear "loading" text so it's obvious the app is
            // working (not stuck) while the catalog is being prepared.
            VStack(spacing: 14) {
                Image("LaunchLogo")
                    .resizable().scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .accessibilityHidden(true)
                Text("Magnatune is loading…")
                    .font(.title3.weight(.semibold))
                Text("Please wait — this only takes a moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            switch selection {
            case .popular: PopularView()
            case .artists: ArtistsView()
            case .albums: AlbumsView()
            case .genres: GenresView(onOpen: { path.append($0) })
            case .tags: TagsView()
            case .playlists: CatalogPlaylistsView()
            case .songs: SongsView()
            case .favorites: FavoritesView()
            case .myPlaylists: PlaylistsView()
            case .search: SearchView()
            case .settings: SettingsView(onShowHelp: { showHelp() })
            case .help: HelpView(onNavigate: { item in
                navHighlight = nil
                selection = item
                path = NavigationPath()
            })
            }
        }
    }
}
