import AVFoundation
import Speech

/// Push-to-talk dictation (nl-NL). Mic = iPhone, or the glasses when HFP is the active route.
@MainActor
final class Dictation: ObservableObject {
    @Published var isListening = false
    @Published var partial = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var delivered = false

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        return speech && mic
    }

    func start(glassesMic: Bool, onFinal: @escaping (String) -> Void) throws {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }
        // Keep the current route if HFP was already settled for the glasses; else configure.
        if !(glassesMic && AudioRoute.hfpInputActive) { try AudioRoute.configure(glassesMic: glassesMic) }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        delivered = false
        partial = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isListening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result {
                    self.partial = r.bestTranscription.formattedString
                    self.armSilenceTimer()
                    if r.isFinal { self.finish(onFinal) }
                }
                if error != nil { self.finish(onFinal) }
            }
        }
    }

    func stop() {
        silenceTask?.cancel()
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { await MainActor.run { self?.request?.endAudio() } }
        }
    }

    private func finish(_ onFinal: (String) -> Void) {
        guard !delivered else { return }
        delivered = true
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onFinal(text) }
    }
}

enum DictationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Spraakherkenning (Nederlands) is niet beschikbaar." }
}
