import AVFoundation
import UIKit

/// Clap analysis, thread-safe: called from the audio thread, reports patterns through `onPattern`.
/// A clap = sudden, loud, broadband spike (speech and music are mostly low-frequency and rise gradually).
/// 2 claps = start listening, 3 claps = stop everything. Audio is analysed in memory only, never stored or sent.
final class ClapCore: @unchecked Sendable {
    private let lock = NSLock()
    private var floor: Float = 0.01
    private var prevPeak: Float = 0
    private var lastClap: TimeInterval = 0
    private var claps: [TimeInterval] = []
    private var sens: Double = 6

    var onPattern: (@Sendable (Int) -> Void)?

    /// 1 = strict ... 10 = sensitive
    var sensitivity: Double {
        get { lock.lock(); defer { lock.unlock() }; return sens }
        set { lock.lock(); sens = min(10, max(1, newValue)); lock.unlock() }
    }

    func reset() {
        lock.lock(); floor = 0.01; prevPeak = 0; lastClap = 0; claps = []; lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 1 else { return }

        var pk: Float = 0, sq: Float = 0, diff: Float = 0
        var prev = ch[0]
        for i in 0..<n {
            let x = ch[i]
            let a = abs(x)
            if a > pk { pk = a }
            sq += x * x
            let d = x - prev
            diff += d * d
            prev = x
        }
        let rms = (sq / Float(n)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime

        var finished: Int?
        lock.lock()
        let thr = Float(0.9 - sens * 0.07)                       // sensitivity 1..10 -> threshold .83 ... .2
        let broadband = sq > 0 && (diff / sq) > 0.3               // energy in the highs (first-difference ratio)
        if pk > thr, pk > floor * 7, pk > prevPeak * 1.8, now - lastClap > 0.14, broadband {
            lastClap = now
            claps.append(now)
        }
        floor = floor * 0.97 + rms * 0.03
        prevPeak = pk * 0.5 + prevPeak * 0.3
        if let last = claps.last, now - last > 0.65 {            // pause after the last clap = pattern complete
            if claps.count >= 2 { finished = min(claps.count, 3) }
            claps = []
        }
        lock.unlock()

        if let f = finished { onPattern?(f) }
    }
}

/// Stand-alone microphone listener for claps (used when "Hey Echo" is off).
/// While "Hey Echo" is on, WakeListener feeds its own audio into `core` instead (one microphone, no conflict).
@MainActor
final class ClapListener: ObservableObject {
    @Published private(set) var running = false
    let core = ClapCore()
    var onPattern: ((Int) -> Void)?

    private let engine = AVAudioEngine()

    init() {
        core.onPattern = { [weak self] n in
            Task { @MainActor in self?.onPattern?(n) }
        }
    }

    func start() throws {
        guard !running else { return }
        try AudioRoute.configure(glassesMic: false)        // iPhone microphone: the glasses' HFP mic is too narrow-band for claps
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let core = self.core
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            core.process(buffer)
        }
        engine.prepare()
        try engine.start()
        core.reset()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }
}
