import SwiftUI

private let arc = Color(red: 0.25, green: 0.85, blue: 1.0)      // arc-reactor cyan
private let gold = Color(red: 1.0, green: 0.72, blue: 0.2)
private let red = Color(red: 1.0, green: 0.3, blue: 0.3)

struct HUDView: View {
    @EnvironmentObject var model: EchoModel
    @EnvironmentObject var glasses: GlassesManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var dictation: Dictation
    @EnvironmentObject var wake: WakeListener
    @State private var text = ""
    @State private var showSettings = false
    @State private var showBridge = false

    private var tint: Color {
        switch glasses.link {
        case .live: return arc
        case .failed: return red
        case .off: return arc.opacity(0.45)
        default: return gold
        }
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.02, green: 0.12, blue: 0.18), .black],
                           center: .top, startRadius: 20, endRadius: 600).ignoresSafeArea()
            VStack(spacing: 14) {
                header
                Reactor(tint: tint, label: glasses.link.label, active: glasses.isActive)
                    .frame(height: 170)
                cameraPane
                logView
                controls
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings).environmentObject(glasses).environmentObject(model)
        }
        .sheet(item: $model.generated3D) { Model3DSheet(item: $0) }
        .sheet(isPresented: $showBridge) { BridgeWebView(address: settings.bridgeAddress) }
    }

    private var header: some View {
        HStack {
            Text("E C H O").font(.system(.headline, design: .monospaced)).foregroundStyle(arc)
            Text(settings.mode == .simulated ? "SIM" : (settings.mode == .mockKit ? "MOCK" : "RAY-BAN META"))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(gold)
            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(arc.opacity(0.5))
            Spacer()
            Button { showBridge = true } label: { Image(systemName: "tv.and.mediabox") }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .foregroundStyle(arc)
    }

    private var cameraPane: some View {
        ZStack {
            if let img = glasses.preview {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Text(glasses.detail.isEmpty ? "GEEN BEELD" : glasses.detail)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(arc.opacity(0.6))
                    .multilineTextAlignment(.center).padding()
            }
        }
        .frame(maxWidth: .infinity).frame(height: 150)
        .background(Color.black.opacity(0.4))
        .overlay(Brackets().stroke(tint, lineWidth: 2))
        .overlay(alignment: .bottomLeading) {
            if case .failed(let msg) = glasses.link {
                Text(msg).font(.caption2).foregroundStyle(red).padding(6)
            } else if !glasses.detail.isEmpty && glasses.preview != nil {
                Text(glasses.detail).font(.caption2).foregroundStyle(gold).padding(6)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.log) { line in
                        Text((line.fromUser ? "› " : "ECHO: ") + line.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(line.fromUser ? .white.opacity(0.6) : arc)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if wake.isOn {
                        Text(wake.triggered ? "🎙 " + (wake.heard.isEmpty ? "ik luister…" : wake.heard) : "● wacht op 'Hey Echo'")
                            .font(.system(.footnote, design: .monospaced)).foregroundStyle(gold)
                    }
                    if dictation.isListening {
                        Text("🎙 " + (dictation.partial.isEmpty ? "luisteren…" : dictation.partial))
                            .font(.system(.footnote, design: .monospaced)).foregroundStyle(gold)
                    }
                }
            }
            .onChange(of: model.log.count) { _ in
                if let last = model.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HUDButton(title: glasses.isActive ? "STOP" : "VERBIND", icon: "dot.radiowaves.left.and.right") {
                    Task { await model.toggleConnection() }
                }
                HUDButton(title: "KIJK", icon: "eye") { Task { await model.lookTapped() } }
                    .disabled(!glasses.isLive || model.busy)
                HUDButton(title: dictation.isListening ? "STOP" : "PRAAT", icon: "mic") {
                    Task { await model.micTapped() }
                }
                HUDButton(title: wake.isOn ? "LUISTERT" : "HEY ECHO", icon: "waveform") {
                    Task { await model.toggleWake() }
                }
            }
            HStack {
                TextField("Typ een opdracht…", text: $text)
                    .textFieldStyle(.roundedBorder).submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }.disabled(model.busy)
            }
        }
        .tint(arc)
    }

    private func send() {
        let t = text; text = ""
        Task { await model.submit(t) }
    }
}

struct HUDButton: View {
    let title: String; let icon: String; let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.system(.caption, design: .monospaced)) }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(arc.opacity(enabled ? 0.9 : 0.25), lineWidth: 1.5))
                .foregroundStyle(arc.opacity(enabled ? 1 : 0.3))
        }
    }
}

struct Reactor: View {
    let tint: Color; let label: String; let active: Bool
    @State private var spin = 0.0
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: 0.72).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin))
            Circle().inset(by: 16).trim(from: 0.1, to: 0.55).stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-spin * 1.6))
            Circle().inset(by: 32).stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            Circle().fill(RadialGradient(colors: [tint.opacity(0.8), .clear], center: .center, startRadius: 2, endRadius: 40))
                .frame(width: 70, height: 70).opacity(active ? 1 : 0.35)
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = 360 } }
    }
}

struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let l: CGFloat = 18
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * l, y: y)); p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        return p
    }
}
