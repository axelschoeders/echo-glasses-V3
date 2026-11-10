import AVFoundation

/// Speaks ECHO's replies (nl). Output goes to the glasses automatically when they are the active route.
/// "Jarvis" mode: deepest male Dutch voice installed on the iPhone (Enhanced/Premium preferred), lower pitch, calm tempo.
/// It cannot be the film voice itself; install a better voice in Instellingen > Toegankelijkheid > Gesproken content > Stemmen.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?
    var jarvis = true
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.pickVoice(jarvis: jarvis)
        if jarvis {
            u.pitchMultiplier = 0.82
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
            u.preUtteranceDelay = 0.15
        } else {
            u.rate = AVSpeechUtteranceDefaultSpeechRate
        }
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    static func pickVoice(jarvis: Bool) -> AVSpeechSynthesisVoice? {
        let nl = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("nl") }
        guard jarvis else {
            return nl.first(where: { $0.language == "nl-BE" }) ?? nl.first ?? AVSpeechSynthesisVoice(language: "nl-NL")
        }
        let maleNames = ["xander", "maarten", "ruben", "frank", "jasper", "daan"]
        let male = nl.filter { v in
            v.gender == .male || maleNames.contains { v.name.lowercased().contains($0) }
        }
        let pool = male.isEmpty ? nl : male
        return pool.sorted { $0.quality.rawValue > $1.quality.rawValue }.first
            ?? AVSpeechSynthesisVoice(language: "nl-NL")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.onFinish?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
