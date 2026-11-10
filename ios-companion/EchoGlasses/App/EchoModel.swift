import SwiftUI

struct LogLine: Identifiable {
    let id = UUID()
    let fromUser: Bool
    let text: String
}

@MainActor
final class EchoModel: ObservableObject {
    @Published var log: [LogLine] = []
    @Published var busy = false
    @Published var generated3D: Generated3D?

    let settings: SettingsStore
    let glasses = GlassesManager()
    let dictation = Dictation()
    let wake = WakeListener()
    let clap = ClapListener()
    private let speech = SpeechOutput()
    private var history: [ChatTurn] = []
    private var bridgeState: BridgeState?

    init(settings: SettingsStore) {
        self.settings = settings
        speech.onFinish = { [weak self] in self?.wake.resume() }
        clap.onPattern = { [weak self] n in self?.handleClaps(n) }
        wake.attachClap(settings.clapOn ? clap.core : nil)
        Task { [weak self] in await self?.watchAlerts() }
        Task { [weak self] in await self?.watchClap() }
    }

    private func say(_ text: String) {
        speech.jarvis = settings.jarvisVoice
        speech.speak(text)
    }

    func testVoice() { say("Goedendag. Alle systemen zijn online, en tot uw dienst.") }

    // MARK: clap detection (2 claps = listen, 3 claps = stop everything locally; does not touch the bridge)

    /// Re-evaluated every second: stand-alone clap microphone only while nothing else uses the mic.
    private func watchClap() async {
        while !Task.isCancelled {
            syncClap()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func syncClap() {
        clap.core.sensitivity = settings.clapSensitivity
        wake.attachClap(settings.clapOn ? clap.core : nil)
        let standalone = settings.clapOn && !wake.isOn && !dictation.isListening && !busy
            && UIApplication.shared.applicationState == .active
        if standalone { try? clap.start() } else { clap.stop() }
    }

    private func handleClaps(_ n: Int) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        if n >= 3 { stopEverythingLocally(); return }
        if speech.isSpeaking { speech.stop(); wake.resume() }
        guard !busy, !dictation.isListening else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.wake.isOn { self.wake.forceTrigger() } else { await self.micTapped() }
        }
    }

    private func stopEverythingLocally() {
        speech.stop()
        dictation.stop()
        if wake.isOn { wake.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        add(false, "Alles gestopt (klap). Voor de pc-bridge: zeg 'stop alle processen'.")
    }

    // MARK: security alerts from the bridge (spoken through the active audio route = the glasses)
    private var alertCursor = -1

    private func watchAlerts() async {
        while !Task.isCancelled {
            if let b = try? BridgeClient(config: settings.bridge),
               let r = try? await b.alerts(since: alertCursor) {
                alertCursor = r.last
                for a in r.alerts {
                    add(false, "ALARM: " + a)
                    say("ECHO beveiligingsalarm. " + a)
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: actions wired to the UI

    func toggleConnection() async {
        if glasses.isActive { glasses.disconnect(); return }
        glasses.mode = settings.mode
        glasses.useGlassesMic = settings.glassesMic
        if settings.glassesMic { _ = await dictation.requestPermissions() }
        await glasses.connect()
    }

    func lookTapped() async { await submit("Wat zie je? Beschrijf kort wat ik voor me heb.") }

    /// "Hey Echo" listening mode on/off.
    func toggleWake() async {
        if wake.isOn {
            wake.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        guard await dictation.requestPermissions() else { add(false, "Geen toestemming voor microfoon of spraakherkenning."); return }
        clap.stop()
        do {
            try wake.start(glassesMic: settings.glassesMic) { [weak self] text in
                Task { await self?.submit(text) }
            }
            UIApplication.shared.isIdleTimerDisabled = true     // keep the screen on while listening
            add(false, "Ik luister. Zeg: Hey Echo, gevolgd door je vraag.")
        } catch { add(false, error.localizedDescription) }
    }

    func micTapped() async {
        if wake.isOn { wake.forceTrigger(); return }     // in listening mode PRAAT skips the wake phrase
        if dictation.isListening { dictation.stop(); return }
        guard await dictation.requestPermissions() else { add(false, "Geen toestemming voor microfoon of spraakherkenning."); return }
        clap.stop()
        do {
            speech.stop()
            try dictation.start(glassesMic: settings.glassesMic) { [weak self] text in
                Task { await self?.submit(text) }
            }
        } catch { add(false, error.localizedDescription) }
    }

    func pastePairing() {
        guard let text = UIPasteboard.general.string else { add(false, "Het klembord is leeg."); return }
        do { try settings.applyPairing(text); add(false, "ECHO gekoppeld. Je AI-instellingen zijn overgenomen.") }
        catch { add(false, error.localizedDescription) }
    }

    func resetBridgeCache() { bridgeState = nil }

    // MARK: main pipeline

    func submit(_ input: String) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { wake.resume(); return }
        wake.suspend()
        busy = true
        defer { busy = false }
        add(true, text)

        var reply: String
        do {
            let apps = bridgeState?.apps ?? []
            switch CommandRouter.route(text, apps: apps) {
            case .look(let prompt):
                let jpeg = try await glasses.snapshotJPEG()
                reply = try await client().describe(jpeg: jpeg, prompt: prompt)
                remember(text, reply)
            case .shortcut(let name, let spoken):
                var c = URLComponents(string: "shortcuts://run-shortcut")!
                c.queryItems = [URLQueryItem(name: "name", value: name),
                                URLQueryItem(name: "x-success", value: "echoglasses://shortcut-done")]
                if let url = c.url { _ = await UIApplication.shared.open(url) }
                reply = spoken
            case .model3D(let prompt):
                let raw = try await client().askRaw(system: Model3DPrompt.system, user: prompt)
                let m = try SceneBuilder.parse(raw)
                generated3D = SceneBuilder.generate(from: m)
                reply = "Hier is je 3D-model: \(m.name ?? "object"). Draai het met je vinger."
            case .search(let query):
                reply = try await client().search(query)
                remember(text, reply)
            case .chat:
                reply = try await client().ask(text, history: history)
                remember(text, reply)
            case .tv(let key, let wake, let spoken):
                let (bridge, tv) = try await bridgeAndTV(text)
                if wake { try await bridge.tvWake(tv: tv) } else if let key { try await bridge.tvKey(tv: tv, key: key) }
                reply = spoken
            case .tvApp(let app):
                let (bridge, tv) = try await bridgeAndTV(text)
                try await bridge.tvApp(tv: tv, app: app)
                reply = "Ik open \(app) op de tv."
            case .tvVolume(let change):
                let (bridge, tv) = try await bridgeAndTV(text)
                reply = try await bridge.tvVolume(tv: tv, change: change)
            case .pcVolume(let change):
                reply = try await bridge().pcVolume(change)
            case .pc(let action, let spoken):
                try await bridge().pc(action)
                reply = spoken
            case .openApp(let app):
                try await bridge().openApp(app)
                reply = "Ik open \(app)."
            case .eufyCamera:
                try await bridge().openEufyCamera()
                reply = "Ik open de ingestelde Eufy-camerastream op je pc."
            case .uberEats:
                if let url = URL(string: "https://www.ubereats.com/") {
                    _ = await UIApplication.shared.open(url)
                }
                reply = "Ik open Uber Eats. Vertel me wat je zoekt en ik help je de keuze voorbereiden. Een ouder of voogd moet de winkelmand, het adres en de betaling controleren en zelf bevestigen."
            case .refuse(let msg):
                reply = msg
            }
        } catch {
            reply = "Er ging iets mis. \(error.localizedDescription)"
        }
        add(false, reply)
        say(reply)
    }

    // MARK: helpers

    private func client() throws -> EchoClient {
        guard settings.config.isComplete else { throw EchoError.notConfigured }
        return EchoClient(cfg: settings.config)
    }

    private func bridge() async throws -> BridgeClient {
        let b = try BridgeClient(config: settings.bridge)
        if bridgeState == nil { bridgeState = try await b.state() }
        return b
    }

    private func bridgeAndTV(_ spoken: String) async throws -> (BridgeClient, String) {
        let b = try await bridge()
        let tvs = bridgeState?.tvs ?? []
        guard let tv = tvs.first(where: { spoken.lowercased().contains($0.lowercased()) }) ?? tvs.first else {
            throw BridgeError.failed("Geen tv ingesteld in config.json van de bridge.")
        }
        return (b, tv)
    }

    private func remember(_ user: String, _ reply: String) {
        history.append(ChatTurn(role: "user", content: user))
        history.append(ChatTurn(role: "assistant", content: reply))
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    private func add(_ user: Bool, _ text: String) {
        log.append(LogLine(fromUser: user, text: text))
        if log.count > 40 { log.removeFirst() }
    }
}
