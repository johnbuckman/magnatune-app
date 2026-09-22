import SwiftUI

// MARK: - Backwards-compatibility shims for iOS 15
//
// The app's modern navigation and empty-state APIs (NavigationStack, value-based
// NavigationLink, ContentUnavailableView, several toolbar/scroll modifiers) are all
// iOS 16/17-only. To let the bundle install and run on iOS 15.x devices (e.g. an
// iPhone 6s Plus capped at 15.8.8) while keeping the modern experience intact for
// everyone on iOS 16+, the app deploys at iOS 15.0 and branches on availability.
//
// Rule of thumb: on iOS 16+ these shims defer to the exact modern API (so Catalyst
// and current devices are byte-for-byte unchanged); on iOS 15 they fall back to the
// pre-16 equivalent, degrading gracefully where no equivalent exists.

// MARK: Empty state (replaces ContentUnavailableView, iOS 17)

/// A centered "empty state" — icon, title, optional description. Mirrors
/// ContentUnavailableView's look but works on every deployment target, so it is used
/// unconditionally (no availability branch, identical on all OSes).
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: Text? = nil

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    /// Mirror of ContentUnavailableView.search(text:).
    static func search(text: String) -> EmptyStateView {
        EmptyStateView("No Results", systemImage: "magnifyingglass",
                       description: Text("No results for “\(text)”."))
    }
}

// MARK: Info overlay (replaces `.sheet` for modal info pages)

/// A dimmed, centered modal card rendered inline in the view tree (not via `.sheet`).
/// A `.sheet` presented from a view deep inside the custom NavigationStack does NOT
/// dismiss on Mac Catalyst when its isPresented binding flips (the action fires, the
/// sheet stays) — so info pages use this overlay, whose visibility is just a plain
/// conditional. Tap the Done button or the dimmed background to close.
struct InfoOverlay<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(maxWidth: 520, maxHeight: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.systemBackground)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.3), radius: 20)
            .padding(24)
        }
    }
}

// MARK: Value-based navigation link (replaces NavigationLink(value:), iOS 16)

/// A drop-in for `NavigationLink(value:) { label }`. On iOS 16+ it *is* that link,
/// pushing the value onto the enclosing NavigationStack's path. On iOS 15 there is no
/// path, so it falls back to `NavigationLink(destination:)`, resolving the destination
/// through `magnatuneDestination(for:)`.
struct NavLink<Value: Hashable, Label: View>: View {
    @EnvironmentObject private var router: NavRouter
    let value: Value
    @ViewBuilder var label: () -> Label

    init(value: Value, @ViewBuilder label: @escaping () -> Label) {
        self.value = value
        self.label = label
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            // Push through the router's typed append (not NavigationLink(value:)): when
            // NavigationStack appends through an external path binding it uses the
            // Hashable-only path, which makes NavigationPath.codable nil and breaks
            // persistence. router.push → applyPush appends the concrete Codable type, so the
            // path stays codable and the drill-down is saved/restored.
            Button(action: { router.push(value) }, label: label)
                .buttonStyle(.plain)
        } else {
            NavigationLink(destination: magnatuneDestination(for: AnyHashable(value)), label: label)
        }
    }
}

/// Central value → detail-view mapping. On iOS 16+ this same mapping lives in the
/// NavigationStack's `.navigationDestination(for:)` handlers (which additionally drive
/// the sidebar highlight); on iOS 15 it backs the legacy `NavigationLink(destination:)`.
/// The sidebar-highlight-follows-drilldown nicety is intentionally dropped on iOS 15.
@MainActor @ViewBuilder
func magnatuneDestination(for value: AnyHashable) -> some View {
    switch value.base {
    case let a as Artist:          ArtistDetailView(artist: a)
    case let al as Album:          AlbumDetailView(album: al)
    case let asng as AlbumSong:    AlbumDetailView(album: asng.album, highlightSongID: asng.songID)
    case let g as Genre:           GenreArtistsView(genre: g)
    case let t as Tag:             TagAlbumsView(tag: t)
    case let cp as CatalogPlaylist: CatalogPlaylistDetailView(playlist: cp)
    case let up as UserPlaylistRef: PlaylistDetailView(playlistID: up.id, name: up.name)
    default:                       EmptyView()
    }
}

// MARK: Form row (LabeledContent / formStyle are iOS 16)

/// A title + trailing-content row. iOS 16+: LabeledContent. iOS 15: a plain HStack with
/// the title leading and the content trailing (the same visual result inside a Form).
struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent(title, content: content)
        } else {
            HStack { Text(title); Spacer(minLength: 12); content() }
        }
    }
}

extension LabeledRow where Content == Text {
    /// Convenience mirroring `LabeledContent(_:value:)`.
    init(_ title: String, value: String) {
        self.init(title) { Text(value) }
    }
}

extension View {
    /// `.formStyle(.grouped)` (iOS 16). No-op on iOS 15, where Form is already grouped.
    @ViewBuilder func groupedFormCompat() -> some View {
        if #available(iOS 16.0, *) { self.formStyle(.grouped) } else { self }
    }

    /// `.menuStyle(.button)` (iOS 16). iOS 15 falls back to `.borderlessButton`.
    @ViewBuilder func buttonMenuStyleCompat() -> some View {
        if #available(iOS 16.0, *) { self.menuStyle(.button) } else { self.menuStyle(.borderlessButton) }
    }
}

// MARK: - Navigation host (decouples RootView from the iOS-16 NavigationStack)

/// Shared drill-down intent, driven by RootView and consumed by whichever host is live.
/// Holds no `NavigationPath` (that type is iOS 16-only) — just reset/push signals — so it
/// compiles at the iOS 15 floor and works for both hosts.
@MainActor
final class NavRouter: ObservableObject {
    /// Bumped to pop the drill-down back to the section root.
    @Published var resetToken = 0
    /// Bumped to request a programmatic push of `pendingPush`.
    @Published var pushToken = 0
    /// The value to push on the next `pushToken` change (one-shot).
    var pendingPush: AnyHashable?

    /// One-shot guard so the saved drill-down is restored exactly once per launch,
    /// regardless of which host instance triggers it.
    var didRestorePath = false

    /// Opaque `NavigationPath` storage. That type is iOS 16-only, so it can't be named in
    /// a stored property at the iOS 15 floor — held as `Any` and accessed only through the
    /// iOS-16 extension below. This lives on the router (a single, stable StateObject) so
    /// the drill-down is shared across the sidebar and tab-bar layouts and survives the
    /// launch-time compact→regular layout switch — exactly as the original single @State did.
    fileprivate var pathStorage: Any?

    func reset() { resetToken &+= 1 }

    func push<V: Hashable>(_ value: V) {
        pendingPush = AnyHashable(value)
        pushToken &+= 1
    }
}

/// UserDefaults key for the persisted drill-down path.
let kNavPath = "nav.path"

@available(iOS 16.0, *)
extension NavRouter {
    var path: NavigationPath {
        get { (pathStorage as? NavigationPath) ?? NavigationPath() }
        set {
            objectWillChange.send()
            pathStorage = newValue
            // Persist here, synchronously on every change — not via .onChange, which gets
            // coalesced away when NavigationStack writes through the binding during its own
            // update (that was the bug: the drill-down never got saved).
            persist(newValue)
        }
    }
    /// Binding for `NavigationStack(path:)`.
    var pathBinding: Binding<NavigationPath> {
        Binding(get: { self.path }, set: { self.path = $0 })
    }

    /// Encode the drill-down so the app reopens on the same page. Empty/uncodable → clear.
    func persist(_ p: NavigationPath) {
        if !p.isEmpty, let c = p.codable, let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: kNavPath)
        } else {
            UserDefaults.standard.removeObject(forKey: kNavPath)
        }
    }
}

/// iOS 16+ host — the app's real navigation. Value-based NavigationStack with a
/// type-erased path, per-type destinations (which also drive the sidebar highlight),
/// and Codable path persistence. This is unchanged from the original RootView, just
/// lifted into its own view so it can sit behind `#available`.
@available(iOS 16.0, *)
struct ModernNavHost<Root: View>: View {
    @ObservedObject var router: NavRouter
    @Binding var navHighlight: SidebarItem?
    @ViewBuilder var root: () -> Root

    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack(path: router.pathBinding) {
            root()
                .background(InteractivePopGestureEnabler())   // swipe-back with a hidden nav bar
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).onAppear { highlight(.artists) } }
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: AlbumSong.self) { AlbumDetailView(album: $0.album, highlightSongID: $0.songID).onAppear { highlight(nil) } }
                .navigationDestination(for: Genre.self) { GenreArtistsView(genre: $0).onAppear { highlight(.genres) } }
                .navigationDestination(for: Tag.self) { TagAlbumsView(tag: $0).onAppear { highlight(.tags) } }
                .navigationDestination(for: CatalogPlaylist.self) { CatalogPlaylistDetailView(playlist: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: UserPlaylistRef.self) { PlaylistDetailView(playlistID: $0.id, name: $0.name).onAppear { highlight(.myPlaylists) } }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: router.path) { newPath in
            if newPath.isEmpty { navHighlight = nil }
        }
        .onChange(of: router.resetToken) { _ in router.path = NavigationPath() }
        .onChange(of: router.pushToken) { _ in applyPush() }
        .onChange(of: model.catalogReady) { ready in if ready { restoreIfNeeded() } }
        .onAppear { restoreIfNeeded() }
    }

    /// Append the router's pending value with its concrete type (NavigationPath matches
    /// destinations by exact type, so we can't append the AnyHashable wrapper).
    private func applyPush() {
        guard let v = router.pendingPush else { return }
        switch v.base {
        case let a as Artist:           router.path.append(a)
        case let al as Album:           router.path.append(al)
        case let asng as AlbumSong:     router.path.append(asng)
        case let g as Genre:            router.path.append(g)
        case let t as Tag:              router.path.append(t)
        case let cp as CatalogPlaylist: router.path.append(cp)
        case let up as UserPlaylistRef: router.path.append(up)
        default: break
        }
        router.pendingPush = nil
    }

    private func highlight(_ item: SidebarItem?) {
        DispatchQueue.main.async { navHighlight = item }
    }

    private func restoreIfNeeded() {
        guard !router.didRestorePath, model.catalogReady else { return }
        router.didRestorePath = true
        guard let data = UserDefaults.standard.data(forKey: kNavPath),
              let rep = try? JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
        else { NSLog("MAGNAV restore: no saved nav.path"); return }
        router.path = NavigationPath(rep)
        NSLog("MAGNAV restore: applied path count=%d", router.path.count)
    }
}

/// iOS 15 host — pre-16 `NavigationView` fallback. Drill-down works to arbitrary depth
/// through `NavLink` (which uses `NavigationLink(destination:)` here). A hidden activating
/// link handles the two programmatic pushes; `.id(resetToken)` pops to root. Degraded vs.
/// the modern host: no launch-time deep-path restore, and the sidebar highlight does not
/// follow drill-downs (both acceptable on legacy devices).
struct LegacyNavHost<Root: View>: View {
    @ObservedObject var router: NavRouter
    @ViewBuilder var root: () -> Root
    @State private var pushActive = false

    var body: some View {
        NavigationView {
            root()
                .background(InteractivePopGestureEnabler())
                .navigationBarHidden(true)
                .background(
                    NavigationLink(isActive: $pushActive) {
                        magnatuneDestination(for: router.pendingPush ?? AnyHashable(0))
                    } label: { EmptyView() }
                    .hidden()
                )
        }
        .navigationViewStyle(.stack)
        .id(router.resetToken)
        .onChange(of: router.pushToken) { _ in
            if router.pendingPush != nil { pushActive = true }
        }
    }
}

// MARK: Wrapping chips container (FlowLayout is iOS 16-only)

/// Chips/tags container. iOS 16+ wraps them with `FlowLayout`; iOS 15 degrades to a
/// single horizontally-scrolling row (taps still work — just no multi-line wrap).
struct WrapChips<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            FlowLayout(spacing: spacing) { content() }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) { content() }
            }
        }
    }
}

// MARK: View-modifier shims

extension View {
    /// Show/hide the navigation bar. iOS 16+: `.toolbar(_:for:.navigationBar)`.
    /// iOS 15: the pre-16 `.navigationBarHidden(_:)`.
    @ViewBuilder func navBar(hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        } else {
            self.navigationBarHidden(hidden)
        }
    }

    /// `.persistentSystemOverlays(.hidden)` (iOS 16). No-op on iOS 15.
    @ViewBuilder func hideSystemOverlays() -> some View {
        if #available(iOS 16.0, *) { self.persistentSystemOverlays(.hidden) } else { self }
    }

    /// `.scrollContentBackground(.hidden)` (iOS 16). No-op on iOS 15 (the grouped List
    /// keeps its default background there — a minor cosmetic difference).
    @ViewBuilder func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) { self.scrollContentBackground(.hidden) } else { self }
    }

    /// `.presentationCompactAdaptation(.popover)` (iOS 16.4). No-op on older OSes
    /// (the popover adapts to a sheet on compact widths there — acceptable).
    @ViewBuilder func keepPopoverCompat() -> some View {
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
    }

    /// `.focusEffectDisabled()` (iOS 17). No-op on iOS 15/16.
    @ViewBuilder func disableFocusEffectCompat() -> some View {
        if #available(iOS 17.0, *) { self.focusEffectDisabled() } else { self }
    }

    /// `.presentationDetents(_:)` (iOS 16). No-op on iOS 15 (sheet uses the default size).
    @ViewBuilder func presentationDetentsCompat(_ detents: Set<PresentationDetentCompat>) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(Set(detents.map(\.resolved)))
        } else {
            self
        }
    }
}

/// A tiny detent enum so call sites don't have to name the iOS 16 `PresentationDetent`
/// type directly (which would fail to compile against the iOS 15 floor).
enum PresentationDetentCompat: Hashable {
    case medium
    case large

    @available(iOS 16.0, *)
    var resolved: PresentationDetent {
        switch self {
        case .medium: return .medium
        case .large:  return .large
        }
    }
}
