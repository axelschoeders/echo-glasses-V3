import SwiftUI
import MWDATCore

@main
struct EchoGlassesApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var model: EchoModel

    init() {
        // Meta DAT: call once at launch. If it fails (e.g. missing Info.plist keys),
        // the app still runs in simulation mode.
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }
        let s = SettingsStore()
        _settings = StateObject(wrappedValue: s)
        _model = StateObject(wrappedValue: EchoModel(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            HUDView()
                .environmentObject(settings)
                .environmentObject(model)
                .environmentObject(model.glasses)
                .environmentObject(model.dictation)
                .environmentObject(model.wake)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Callback from the Meta AI app (registration / permissions).
                    if url.host == "shortcut-done" { return }     // returning from an iOS Shortcut
                    Task { await model.glasses.handle(url: url) }
                }
        }
    }
}
