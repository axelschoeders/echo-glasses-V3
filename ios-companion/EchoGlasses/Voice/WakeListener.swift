import AVFoundation
import Speech
import UIKit

/// Thread-safe holder so the audio tap (audio thread) can feed the current recognition request.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private var clap: ClapCore?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
    func setClap(_ c: ClapCore?) { lock.lock(); clap = c; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); req?.append(b); let c = clap; lock.unlock(); c?.process(b) }
}

/// "Hey Echo" wake phrase: keeps the microphone open and listens continuously with Apple's
/// speech recognizer (nl-NL). When it hears the wake phrase, the words that follow become the command.
/// Limits: needs the app running (foreground, or background audio mode); uses battery; the recognizer
/// is not a dedicated wake-word engine, so it can miss or mishear.
@MainActor
final class WakeListener: ObservableObject {
    @Published var isOn = false
    @Published var triggered = false
    @Published var heard = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var failsafe: Task<Void, Never>?
    private var generation = 0
    private var paused = false
    private var pendingCommand = ""
    private var onCommand: ((String) -> Void)?

    // Tolerant wake detection: greeting + something that sounds like "echo", or "echo" as first word.
    private let greetings: Set<String> = ["hey", "hé", "he", "hee", "hei", "hai", "hoi", "hallo", "hi", "ok", "oké", "okay"]
    private let echoLike: Set<String> = ["echo", "eco", "ecco", "ekko", "echoo", "echos", "hecho", "ecko", "ekho", "ecko", "eko"]

    /// Claps are detected on the same microphone stream while "Hey Echo" is on (pass nil to turn off).
    func attachClap(_ core: ClapCore?) { box.setClap(core) }

    // MARK: on / off

    func start(glassesMic: Bool, onCommand: @escaping (String) -> Void) throws {
        guard !isOn else { return }
        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }
        try AudioRoute.configure(glassesMic: glassesMic)
        self.onCommand = onCommand

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let box = self.box
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            box.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isOn = true
        paused = false
        beginSession()

        // Recognition sessions are time-limited; refresh when idle.
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.restartIfIdle()
            }
        }
    }

    func stop() {
        isOn = false
        timer?.cancel(); refresh?.cancel(); failsafe?.cancel()
        endSession()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        box.set(nil)
        triggered = false; heard = ""; pendingCommand = ""
    }

    /// Stop reacting (while ECHO is thinking or speaking) but keep the microphone open.
    func suspend() {
        guard isOn else { return }
        paused = true
        timer?.cancel()
        endSession()
        triggered = false; heard = ""; pendingCommand = ""
        failsafe?.cancel()
        failsafe = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled { self?.resume() }
        }
    }

    func resume() {
        guard isOn, paused else { return }
        paused = false
        failsafe?.cancel()
        beginSession()
    }

    /// Used by the PRAAT button while listening mode is on: skip the wake phrase.
    func forceTrigger() {
        guard isOn else { return }
        if paused { resume() }
        triggered = true
        heard = ""
        pendingCommand = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        armTimer(empty: true)
    }

    // MARK: recognition session

    private func beginSession() {
        guard isOn, !paused, let recognizer else { return }
        endSession()
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = ["Hey Echo", "Echo", "hé Echo", "Ecko", "Ekho", "Eko", "Netflix", "Disney plus", "tv", "volume", "harder", "zachter", "Eufy", "camerabeelden", "Uber Eats"]
        currentRequest = req
        box.set(req)
        triggered = false
        heard = ""
        pendingCommand = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let r = result { self.handle(r.bestTranscription.formattedString) }
                if error != nil || (result?.isFinal ?? false) { self.restartSoon() }
            }
        }
    }

    private func endSession() {
        generation += 1
        box.set(nil)
        currentRequest?.endAudio()
        currentRequest = nil
        task?.cancel()
        task = nil
    }

    private func restartSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.beginSession()
        }
    }

    private func restartIfIdle() {
        if isOn, !paused, !triggered { beginSession() }
    }

    // MARK: wake phrase + command extraction

    private func handle(_ text: String) {
        let lower = text.lowercased()
        var command: String
        if let spoken = wakeCommand(in: lower) {
            if !triggered { triggered = true; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            command = spoken
        } else if triggered {
            command = lower          // PRAAT button path: no wake phrase needed
        } else {
            return                   // ordinary speech: ignore
        }
        command = command.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        pendingCommand = command
        heard = command
        armTimer(empty: command.isEmpty)
    }

    /// Returns the words after the wake phrase, or nil when the wake phrase wasn't heard.
    private func wakeCommand(in lower: String) -> String? {
        let words = lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        var found: Int?
        for (i, w) in words.enumerated() where isEchoLike(w) {
            if i == 0 || greetings.contains(words[i - 1]) || isGreetingLike(words[i - 1]) { found = i }
        }
        guard let i = found else { return nil }
        return words[(i + 1)...].joined(separator: " ")
    }

    /// Allow small speech-to-text spelling errors (e.g. "ecko" / "ekho") without
    /// treating every mention of a vaguely similar word as the wake phrase.
    private func isEchoLike(_ word: String) -> Bool {
        if echoLike.contains(word) { return true }
        guard word.count >= 3, word.count <= 6 else { return false }
        return echoLike.contains { candidate in
            let distance = levenshtein(word, candidate)
            return distance <= 1 && candidate.count >= 3
        }
    }

    private func isGreetingLike(_ word: String) -> Bool {
        if greetings.contains(word) { return true }
        return ["hey", "hei", "hai", "hoi"].contains { levenshtein(word, $0) <= 1 }
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let lhs = Array(a), rhs = Array(b)
        var row = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (left == right ? 0 : 1))
            }
            row = next
        }
        return row[rhs.count]
    }

    private func armTimer(empty: Bool) {
        timer?.cancel()
        let delay: UInt64 = empty ? 4_000_000_000 : 1_400_000_000
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if !Task.isCancelled { self?.fire() }
        }
    }

    private func fire() {
        let command = pendingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCommand = ""
        if command.isEmpty {
            triggered = false
            beginSession()
        } else {
            let callback = onCommand
            suspend()
            callback?(command)
        }
    }
}
