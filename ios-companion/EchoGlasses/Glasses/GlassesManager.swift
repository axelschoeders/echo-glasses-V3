import SwiftUI
import MWDATCore
import MWDATCamera
import MWDATMockDevice

enum GlassesMode: String, CaseIterable, Identifiable {
    case simulated   // no SDK involved: bundled test image. Works anywhere, incl. iOS Simulator.
    case mockKit     // Meta's Mock Device Kit (official simulation) feeding the real DAT code path
    case real        // actual Ray-Ban Meta glasses
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simulated: return "Simulatie (zonder SDK)"
        case .mockKit: return "Meta MockDeviceKit"
        case .real: return "Echte bril"
        }
    }
}

enum LinkState: Equatable {
    case off, registering, waiting, connecting, live, paused
    case failed(String)
    var label: String {
        switch self {
        case .off: return "OFFLINE"
        case .registering: return "KOPPELEN"
        case .waiting: return "WACHT OP BRIL"
        case .connecting: return "VERBINDEN"
        case .live: return "ONLINE"
        case .paused: return "GEPAUZEERD"
        case .failed: return "FOUT"
        }
    }
}

enum GlassesError: LocalizedError {
    case notLive, noFrame
    var errorDescription: String? {
        switch self {
        case .notLive: return "De bril is niet verbonden. Tik op Verbind."
        case .noFrame: return "Nog geen beeld van de camera ontvangen."
        }
    }
}

@MainActor
final class GlassesManager: ObservableObject {
    @Published var link: LinkState = .off
    @Published var detail = ""
    @Published var preview: UIImage?
    @Published var registrationText = "—"
    @Published var deviceCount = 0
    @Published var deviceInfo = ""      // what the SDK reports per glasses: link state, compatibility

    var mode: GlassesMode = .simulated
    var useGlassesMic = false

    var isActive: Bool {
        switch link {
        case .off, .failed: return false
        default: return true
        }
    }
    var isLive: Bool { link == .live }

    private var latest: UIImage?
    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens = ListenerTokenBag()
    private var frames = 0
    private var errorTask: Task<Void, Never>?
    private var monitoring = false
    private var mockPaired = false

    // MARK: connect / disconnect

    func connect() async {
        detail = ""
        switch mode {
        case .simulated: startSimulated()
        case .mockKit, .real: await connectSDK()
        }
    }

    func disconnect() {
        camera?.stop()
        camera = nil
        session?.stop()          // Meta: only one session per device, so always stop it
        session = nil
        errorTask?.cancel(); errorTask = nil
        tokens = ListenerTokenBag()   // releases all listeners
        latest = nil
        preview = nil
        link = .off
        detail = ""
    }

    private func startSimulated() {
        guard let path = Bundle.main.path(forResource: "sim-scene", ofType: "jpg"),
              let img = UIImage(contentsOfFile: path) else {
            link = .failed("sim-scene.jpg ontbreekt in de app"); return
        }
        latest = img; preview = img
        link = .live
        detail = "Simulatie: testbeeld, geen echte bril"
    }

    private func connectSDK() async {
        // A leftover session from an earlier attempt makes createSession fail ("already exists").
        camera?.stop(); camera = nil
        session?.stop(); session = nil
        link = .registering
        do {
            if mode == .mockKit { try setUpMock() }
            startMonitors()

            var status = try await Wearables.shared.checkPermissionStatus(.camera)
            if status != .granted { status = try await Wearables.shared.requestPermission(.camera) }
            guard status == .granted else { link = .failed("Camera-toestemming geweigerd"); return }

            if useGlassesMic {
                let ok = await AudioRoute.settleHFP()
                if !ok { detail = "Bril-microfoon niet actief; iPhone-microfoon wordt gebruikt." }
            } else {
                try? AudioRoute.configure(glassesMic: false)
            }

            let selector = AutoDeviceSelector(wearables: Wearables.shared)
            // createSession only succeeds once a device is connected AND compatible; right after
            // the Meta AI app releases the glasses this can fail briefly, so retry a few times.
            var created: DeviceSession?
            var lastError: Error?
            for _ in 0..<6 {
                do { created = try Wearables.shared.createSession(deviceSelector: selector); break }
                catch { lastError = error; detail = "Wachten op bril…"; refreshDeviceInfo(); try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
            guard let session = created else {
                refreshDeviceInfo()
                throw lastError ?? GlassesError.notLive
            }
            self.session = session
            errorTask?.cancel()
            errorTask = Task { [weak self] in
                for await error in session.errorStream() {
                    self?.link = .failed(error.localizedDescription)
                }
            }
            let states = session.stateStream()
            try session.start()
            link = .waiting
            Task { [weak self] in
                for await state in states {
                    // Meta documents `.started` and `.stopped` for the session state.
                    if state == .started { self?.startCamera() }
                    else if state == .stopped { self?.disconnect() }
                }
            }
        } catch {
            link = .failed(error.localizedDescription + (deviceInfo.isEmpty ? "" : "\n" + deviceInfo))
        }
    }

    private func startCamera() {
        guard camera == nil, let session else { return }
        do {
            let config = StreamConfiguration(videoCodec: VideoCodec.raw,
                                             resolution: StreamingResolution.medium,
                                             frameRate: 7)
            // Returns nil until the session is `.started`.
            guard let camera = try session.addCamera(config: config) else { return }
            self.camera = camera
            let stream = camera.stream

            stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.onStream(state) }
            }.store(in: tokens)

            stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage() else { return }
                Task { @MainActor in self?.latest = image; self?.preview = image; self?.frames += 1 }
            }.store(in: tokens)

            stream.start()
        } catch {
            link = .failed(error.localizedDescription)
        }
    }

    private func onStream(_ state: StreamState) {
        detail = "Stream: \(String(describing: state))"
        switch state {
        case .streaming: link = .live
        case .paused: link = .paused
        case .waitingForDevice: link = .waiting
        case .starting: link = .connecting
        case .stopped: if isActive { link = .off }
        default: break
        }
    }

    // MARK: snapshot for the AI

    /// Uses the newest frame of the (documented, non-beta) camera stream.
    func snapshotJPEG() async throws -> Data {
        guard isLive || link == .paused else { throw GlassesError.notLive }
        for _ in 0..<30 {
            if let img = latest, let data = img.jpegForAI() { return data }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw GlassesError.noFrame
    }

    // MARK: registration (real glasses)

    func startRegistration() async {
        do { try await Wearables.shared.startRegistration() }
        catch { link = .failed(error.localizedDescription) }
    }

    func startUnregistration() async {
        do { try await Wearables.shared.startUnregistration() }
        catch { link = .failed(error.localizedDescription) }
    }

    /// Forward callback URLs from the Meta AI app unchanged.
    func handle(url: URL) async {
        do { _ = try await Wearables.shared.handleUrl(url) }
        catch { detail = "Callback-fout: \(error.localizedDescription)" }
    }

    func startMonitors() {
        guard !monitoring else { return }
        monitoring = true
        Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                self?.registrationText = String(describing: state)
            }
        }
        Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                self?.deviceCount = devices.count
                self?.refreshDeviceInfo()
            }
        }
    }

    /// Diagnostics: what does the SDK think of each paired device? (names per Meta's DAT sample/skills)
    func refreshDeviceInfo() {
        let wearables = Wearables.shared
        deviceInfo = wearables.devices.compactMap { id -> String? in
            guard let d = wearables.deviceForIdentifier(id) else { return nil }
            return "\(d.nameOrId()) | link: \(String(describing: d.linkState)) | compat: \(String(describing: d.compatibility()))"
        }.joined(separator: "\n")
    }

    // MARK: Meta Mock Device Kit

    private func setUpMock() throws {
        guard !mockPaired else { return }
        MockDeviceKit.shared.enable()
        let device = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        let camera = device.services.camera
        if let feed = Bundle.main.url(forResource: "sim-feed", withExtension: "mov") {
            camera.setCameraFeed(fileURL: feed)           // HEVC (h265) as Meta requires
        }
        if let img = Bundle.main.url(forResource: "sim-scene", withExtension: "jpg") {
            camera.setCapturedImage(fileURL: img)
        }
        mockPaired = true
        detail = "MockDeviceKit actief (apparaat moet 'powered on' en 'donned' zijn, zie README)."
    }
}
