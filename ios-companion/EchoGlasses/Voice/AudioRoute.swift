import AVFoundation

/// Audio routing per Meta's "Microphones and speakers" guide:
/// A2DP = high-quality output only; HFP = mono voice, needed for the glasses' microphone.
enum AudioRoute {
    static func configure(glassesMic: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        if glassesMic {
            // If your Xcode SDK lacks .allowBluetoothHFP, use .allowBluetooth instead.
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        } else {
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        }
        try s.setActive(true, options: .notifyOthersOnDeactivation)
        if glassesMic, let hfp = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try s.setPreferredInput(hfp)
        }
    }

    static var hfpInputActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }

    /// Meta: the HFP route must be settled BEFORE the camera stream starts.
    /// Runs the engine briefly so the route can settle, then checks it.
    static func settleHFP() async -> Bool {
        do {
            try configure(glassesMic: true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }
            engine.prepare()
            try engine.start()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let ok = hfpInputActive
            input.removeTap(onBus: 0)
            engine.stop()
            if !ok { try? configure(glassesMic: false) }
            return ok
        } catch {
            try? configure(glassesMic: false)
            return false
        }
    }
}
