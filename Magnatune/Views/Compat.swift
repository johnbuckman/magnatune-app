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
            // Push through the router (not NavigationLink(value:)): the router records the
            // push in its browser-style history and rebuilds the path from a typed mirror,
            // appending the concrete Codable type — so the path stays codable and the
            // drill-down is saved/restored (appending the AnyHashable wrapper would make
            // NavigationPath.codable nil).
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
    case is RecentlyPlayedRef:     RecentlyPlayedView()
    case is RecommendedRef:        RecommendedView()
    case is HelpRef:               HelpView()
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

/// A single value on a drill-down path, in a Codable+Hashable sum type so the whole
/// navigation history can be persisted and rebuilt losslessly. `NavigationPath` erases
/// its elements (you can read its count but not the values), which is why the router
/// keeps its own typed mirror of the drill-down as `[NavValue]` and treats that — not the
/// opaque path — as the source of truth for back/forward.
enum NavValue: Hashable, Codable {
    case artist(Artist)
    case album(Album)
    case albumSong(AlbumSong)
    case genre(Genre)
    case tag(Tag)
    case catalogPlaylist(CatalogPlaylist)
    case userPlaylist(UserPlaylistRef)
    case recentlyPlayed
    case recommended
    case help

    /// Wrap one of the app's Hashable nav targets. Returns nil for anything not navigable.
    init?(_ value: AnyHashable) {
        switch value.base {
        case let a as Artist:           self = .artist(a)
        case let al as Album:           self = .album(al)
        case let asng as AlbumSong:     self = .albumSong(asng)
        case let g as Genre:            self = .genre(g)
        case let t as Tag:              self = .tag(t)
        case let cp as CatalogPlaylist: self = .catalogPlaylist(cp)
        case let up as UserPlaylistRef: self = .userPlaylist(up)
        case is RecentlyPlayedRef:      self = .recentlyPlayed
        case is RecommendedRef:         self = .recommended
        case is HelpRef:                self = .help
        default:                        return nil
        }
    }

    /// Append the concrete (typed) value to a `NavigationPath`. The concrete type matters:
    /// appending the `AnyHashable` wrapper would make `NavigationPath.codable` nil and break
    /// matching against the typed `.navigationDestination(for:)` handlers.
    @available(iOS 16.0, *)
    func append(to path: inout NavigationPath) {
        switch self {
        case .artist(let a):          path.append(a)
        case .album(let a):           path.append(a)
        case .albumSong(let a):       path.append(a)
        case .genre(let g):           path.append(g)
        case .tag(let t):             path.append(t)
        case .catalogPlaylist(let c): path.append(c)
        case .userPlaylist(let u):    path.append(u)
        case .recentlyPlayed:         path.append(RecentlyPlayedRef())
        case .recommended:            path.append(RecommendedRef())
        case .help:                   path.append(HelpRef())
        }
    }

    /// The value as an `AnyHashable`, for the iOS 15 legacy host's single-push link.
    var anyHashable: AnyHashable {
        switch self {
        case .artist(let a):          return AnyHashable(a)
        case .album(let a):           return AnyHashable(a)
        case .albumSong(let a):       return AnyHashable(a)
        case .genre(let g):           return AnyHashable(g)
        case .tag(let t):             return AnyHashable(t)
        case .catalogPlaylist(let c): return AnyHashable(c)
        case .userPlaylist(let u):    return AnyHashable(u)
        case .recentlyPlayed:         return AnyHashable(RecentlyPlayedRef())
        case .recommended:            return AnyHashable(RecommendedRef())
        case .help:                   return AnyHashable(HelpRef())
        }
    }
}

/// One entry in the navigation history: a top-level section plus its drill-down stack.
/// Switching section and drilling in are both just new locations, so "back" spans both —
/// exactly like a web browser, which is the model John asked for.
struct NavLoc: Hashable, Codable {
    var section: String
    var values: [NavValue]
}

/// UserDefaults key for the persisted current location (section + drill-down).
let kNavLoc = "nav.loc.v2"

/// Browser-style navigation for the whole app: one linear history of `NavLoc`s plus a
/// forward stack. `goBack()`/`goForward()` move through it; the swipe gesture and the
/// custom ‹ Back chevron both call those. The router is the source of truth and drives
/// both the iOS 16 `NavigationStack` path (via the typed mirror) and RootView's top-level
/// `selection` (via a one-shot token). Holds no `NavigationPath` stored property so it
/// still compiles at the iOS 15 floor; the path lives behind the iOS-16 extension below.
@MainActor
final class NavRouter: ObservableObject {
    // Legacy (iOS 15) host signals — the NavigationView fallback can't be driven by a path.
    /// Bumped to pop the drill-down back to the section root (`.id(resetToken)`).
    @Published var resetToken = 0
    /// Bumped to request a programmatic push of `pendingPush`.
    @Published var pushToken = 0
    /// The value to push on the next `pushToken` change (one-shot).
    var pendingPush: AnyHashable?

    // Hand-off to RootView for router-initiated section changes (goBack/goForward/restore):
    // RootView observes `sectionToken` and copies `pendingSection` into its @State selection.
    @Published var sectionToken = 0
    var pendingSection: String?

    /// The browser history. `current` is `history.last`; there is always at least one entry.
    @Published private(set) var history: [NavLoc] = [NavLoc(section: "popular", values: [])]
    @Published private(set) var forward: [NavLoc] = []

    /// One-shot guard so the saved location is restored exactly once per launch.
    var didRestorePath = false

    /// Opaque `NavigationPath` storage (iOS 16-only type), accessed only via the extension
    /// below. On a single stable StateObject so the drill-down survives the launch-time
    /// compact↔regular layout switch.
    fileprivate var pathStorage: Any?
    /// True while the router itself is writing the path, so the path setter can tell an
    /// app-initiated change from a user pop (native back button / edge swipe).
    fileprivate var isSyncing = false

    var current: NavLoc { history.last ?? NavLoc(section: "popular", values: []) }
    var canGoBack: Bool { history.count > 1 }
    var canGoForward: Bool { !forward.isEmpty }

    /// Seed the baseline location before any navigation (so the first "back" target is the
    /// page the app actually opened on). No-op once the user has navigated or a restore ran.
    func seed(section raw: String) {
        guard !didRestorePath, history.count == 1, forward.isEmpty, current.values.isEmpty else { return }
        history = [NavLoc(section: raw, values: [])]
    }

    /// Navigate to a top-level section root. `updateSection` is false when RootView already
    /// set its own selection (a sidebar/tab tap) and true when the router drives the change
    /// (e.g. a link inside Help). Re-tapping the current section root is a no-op.
    func go(toSection raw: String, updateSection: Bool) {
        if current.section == raw && current.values.isEmpty {
            if updateSection { pendingSection = raw; sectionToken &+= 1 }
            applyPath()
            return
        }
        history.append(NavLoc(section: raw, values: []))
        forward.removeAll()
        apply(updateSection: updateSection)
    }

    func push<V: Hashable>(_ value: V) {
        guard let nv = NavValue(AnyHashable(value)) else { return }
        var loc = current
        loc.values.append(nv)
        history.append(loc)
        forward.removeAll()
        pendingPush = AnyHashable(value)   // legacy host's hidden link
        apply(updateSection: false)
    }

    /// Back-compat shim: collapse the drill-down to the current section root.
    func reset() { go(toSection: current.section, updateSection: false) }

    func goBack() {
        guard history.count > 1 else { return }
        forward.append(history.removeLast())
        apply(updateSection: true)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        history.append(next)
        apply(updateSection: true)
    }

    /// Restore the last session's location once the catalog is ready.
    func restoreIfNeeded(catalogReady: Bool) {
        guard !didRestorePath, catalogReady else { return }
        didRestorePath = true
        guard let data = UserDefaults.standard.data(forKey: kNavLoc),
              let loc = try? JSONDecoder().decode(NavLoc.self, from: data) else { return }
        history = [loc]
        forward = []
        apply(updateSection: true)
    }

    // MARK: Internal

    /// Push the current location out to the section selection (optional) and the path.
    private func apply(updateSection: Bool) {
        if updateSection { pendingSection = current.section; sectionToken &+= 1 }
        applyPath()
        persistCurrent()
    }

    /// Rebuild the live path from the typed mirror (iOS 16), or fire the legacy signals.
    private func applyPath() {
        if #available(iOS 16.0, *) {
            syncPath()
        } else {
            if current.values.isEmpty { resetToken &+= 1 } else { pushToken &+= 1 }
        }
    }

    fileprivate func persistCurrent() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: kNavLoc)
        }
    }
}

@available(iOS 16.0, *)
extension NavRouter {
    /// The live path bound to `NavigationStack`. The getter reflects the typed mirror; the
    /// setter only has to cope with the user popping the stack (native back button / edge
    /// swipe), since every app-initiated change goes through `syncPath()` with `isSyncing`.
    var path: NavigationPath {
        get { (pathStorage as? NavigationPath) ?? NavigationPath() }
        set {
            let oldCount = (pathStorage as? NavigationPath)?.count ?? 0
            objectWillChange.send()
            pathStorage = newValue
            if !isSyncing && newValue.count < oldCount {
                handleExternalPop(removing: oldCount - newValue.count)
            }
        }
    }

    /// Binding for `NavigationStack(path:)`.
    var pathBinding: Binding<NavigationPath> {
        Binding(get: { self.path }, set: { self.path = $0 })
    }

    /// Rebuild the opaque path from the typed mirror, marking the write as app-initiated.
    func syncPath() {
        isSyncing = true
        var p = NavigationPath()
        for v in current.values { v.append(to: &p) }
        objectWillChange.send()
        pathStorage = p
        isSyncing = false
    }

    /// The user popped the stack directly (native back button or left-edge swipe). Mirror
    /// that into the history so swipe-forward still works afterwards.
    private func handleExternalPop(removing n: Int) {
        var k = n
        while k > 0 && history.count > 1 {
            forward.append(history.removeLast())
            k -= 1
        }
        persistCurrent()
    }
}

/// Custom ‹ Back chevron for section-root pages (Popular, Artists, …, Settings, Help),
/// which — being the root of the NavigationStack — have no native back button. Shown only
/// when there is somewhere to go back to. Drill-down pages keep their native chevron, so
/// this never overlaps it. Styled to sit where a nav-bar back button would.
/// A circular caret button matching the system back button that drill-down pages show
/// (a chevron in a soft circle). Used for the section-root back/forward controls so they
/// look identical to the native one.
struct CaretButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.systemGray5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Section-root ‹ Back — a circular caret identical to the drill-down native back button.
struct BackChevron: View {
    var action: () -> Void
    var body: some View {
        CaretButton(systemImage: "chevron.backward", label: "Back", action: action)
    }
}

/// Forward › — the mirror of `BackChevron` (same circular caret, pointing right), for
/// redoing a back you just made. Appears in the section-root bar and overlaid on
/// drill-down pages whenever the forward stack is non-empty.
struct ForwardChevron: View {
    var action: () -> Void
    var body: some View {
        CaretButton(systemImage: "chevron.forward", label: "Forward", action: action)
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
        VStack(spacing: 0) {
            // Custom ‹ Back / Forward › bar for section-root pages only (drill-down pages have
            // the native back chevron + the forward overlay below). A real row that pushes
            // content down, so it never overlaps the filter bar. Shown when there's history
            // to move through in either direction.
            if router.path.isEmpty && (router.canGoBack || router.canGoForward) {
                HStack(spacing: 0) {
                    if router.canGoBack { BackChevron { router.goBack() } }
                    Spacer(minLength: 0)
                    if router.canGoForward { ForwardChevron { router.goForward() } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
            }
            navStack
                // Drill-down pages keep the native back chevron but have no native forward;
                // overlay a Forward › (aligned with the native back) when there's somewhere
                // forward to go.
                .overlay(alignment: .topTrailing) {
                    if !router.path.isEmpty && router.canGoForward {
                        ForwardChevron { router.goForward() }
                            .padding(.trailing, 12)
                            .padding(.top, 6)
                    }
                }
        }
        .onChange(of: model.catalogReady) { ready in if ready { router.restoreIfNeeded(catalogReady: true) } }
        .onAppear { router.restoreIfNeeded(catalogReady: model.catalogReady) }
    }

    private var navStack: some View {
        NavigationStack(path: router.pathBinding) {
            root()
                .background(InteractivePopGestureEnabler())   // swipe-back with a hidden nav bar
                // Full-width swipe: right = back, left = forward. Attached here (inside the
                // NavigationStack root) so it finds the nav controller and covers every page.
                .background(BackForwardSwipeInstaller(onBack: { router.goBack() },
                                                      onForward: { router.goForward() }))
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0).onAppear { highlight(.artists) } }
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: AlbumSong.self) { AlbumDetailView(album: $0.album, highlightSongID: $0.songID).onAppear { highlight(nil) } }
                .navigationDestination(for: Genre.self) { GenreArtistsView(genre: $0).onAppear { highlight(.genres) } }
                .navigationDestination(for: Tag.self) { TagAlbumsView(tag: $0).onAppear { highlight(.tags) } }
                .navigationDestination(for: CatalogPlaylist.self) { CatalogPlaylistDetailView(playlist: $0).onAppear { highlight(nil) } }
                .navigationDestination(for: UserPlaylistRef.self) { PlaylistDetailView(playlistID: $0.id, name: $0.name).onAppear { highlight(.myPlaylists) } }
                .navigationDestination(for: RecentlyPlayedRef.self) { _ in RecentlyPlayedView().onAppear { highlight(.myPlaylists) } }
                .navigationDestination(for: RecommendedRef.self) { _ in RecommendedView().onAppear { highlight(.myPlaylists) } }
                .navigationDestination(for: HelpRef.self) { _ in HelpView().onAppear { highlight(nil) } }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: router.path) { newPath in
            if newPath.isEmpty { navHighlight = nil }
        }
    }

    private func highlight(_ item: SidebarItem?) {
        DispatchQueue.main.async { navHighlight = item }
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
