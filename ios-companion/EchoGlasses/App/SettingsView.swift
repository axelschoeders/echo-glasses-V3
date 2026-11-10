import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var glasses: GlassesManager
    @EnvironmentObject var model: EchoModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("ECHO AI (zelfde als de webapp)") {
                    Button("Plak koppelcode van ECHO (Koppel bril-app)") { model.pastePairing() }
                    TextField("Endpoint-URL", text: $settings.config.url).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model (tekst)", text: $settings.config.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Vision-model (moet afbeeldingen aankunnen)", text: $settings.config.visionModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API-sleutel", text: $settings.config.key)
                    TextField("Jouw naam", text: $settings.config.name)
                    Text("Leeg vision-model = hetzelfde model als hierboven. Een tekstmodel kan geen beelden lezen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Bril") {
                    Picker("Modus", selection: $settings.mode) {
                        ForEach(GlassesMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Bril-microfoon gebruiken (HFP)", isOn: $settings.glassesMic)
                    if settings.mode == .real {
                        LabeledContent("Registratie", value: glasses.registrationText)
                        LabeledContent("Gevonden brillen", value: "\(glasses.deviceCount)")
                        if !glasses.deviceInfo.isEmpty {
                            Text(glasses.deviceInfo).font(.system(.caption, design: .monospaced))
                        }
                        Button("Registreer bij Meta AI-app") { Task { await glasses.startRegistration() } }
                        Button("Uitschrijven", role: .destructive) { Task { await glasses.startUnregistration() } }
                    }
                }
                Section("Stem en klappen") {
                    Toggle("Jarvis-stem", isOn: $settings.jarvisVoice)
                    Button("Test stem") { model.testVoice() }
                    Toggle("Klapdetectie (2x = luisteren, 3x = alles stoppen)", isOn: $settings.clapOn)
                    if settings.clapOn {
                        VStack(alignment: .leading) {
                            Text("Gevoeligheid: \(Int(settings.clapSensitivity))  (1 = streng, 10 = gevoelig)").font(.caption)
                            Slider(value: $settings.clapSensitivity, in: 1...10, step: 1)
                        }
                    }
                    Text("Klappen werken met de iPhone-microfoon, terwijl de app open is (of 'Hey Echo' aan staat). De stem is de diepste mannelijke Nederlandse stem op je iPhone; installeer een 'Verbeterde' stem voor een beter resultaat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("ECHO Bridge (tv & pc)") {
                    TextField("http://192.168.x.x:8765/#t=…", text: $settings.bridgeAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: settings.bridgeAddress) { _ in model.resetBridgeCache() }
                    Text("Het adres dat de bridge bij het opstarten toont. iPhone en pc moeten op hetzelfde wifi zitten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Instellingen")
            .toolbar { Button("Klaar") { dismiss() } }
            .onAppear { if settings.mode != .simulated { glasses.startMonitors() } }
            .onChange(of: settings.mode) { _ in if settings.mode != .simulated { glasses.startMonitors() } }
        }
    }
}

/// Shows the bridge's own remote page (remote.html) — no duplicated TV/PC UI.
struct BridgeWebView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let url = URL(string: address), url.host != nil {
                    WebContainer(url: url)
                } else {
                    Text("Stel eerst het bridge-adres in (Instellingen).").padding()
                }
            }
            .navigationTitle("TV & PC")
            .toolbar { Button("Klaar") { dismiss() } }
        }
    }
}

private struct WebContainer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero)
        v.isOpaque = false; v.backgroundColor = .black
        v.load(URLRequest(url: url))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
