import SwiftUI

/// User-selectable appearance. `.system` follows the device's Light/Dark setting;
/// `.light` / `.dark` force one. Stored in UserDefaults under `AppAppearance.key`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// nil = follow the system; otherwise force the chosen scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    static let key = "appearance"
}

@main
struct MagnatuneApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppAppearance.key) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
                .environmentObject(model)
                .environmentObject(model.userStore)
                .environmentObject(model.credentials)
                .environmentObject(model.audio)
                .task {
                    await model.credentials.refreshMembership()   // verify membership once, at launch
                    await model.refreshCatalog()
                    await model.checkCatalogUpdate()   // auto-download a newer catalog in the background
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }   // no "New Window" — single-window app
            PlaybackCommands(audio: model.audio)
        }
    }
}

/// Native Mac menu-bar "Controls" menu with keyboard shortcuts, wired to the player.
struct PlaybackCommands: Commands {
    @ObservedObject var audio: AudioPlayer

    var body: some Commands {
        CommandMenu("Controls") {
            Button(audio.isPlaying ? "Pause" : "Play") { audio.toggle() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(audio.current == nil)
            Divider()
            Button("Next Track") { audio.next() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(audio.current == nil)
            Button("Previous Track") { audio.previous() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(audio.current == nil)
        }
    }
}
