import SwiftUI

@main
struct MagnatuneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
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
