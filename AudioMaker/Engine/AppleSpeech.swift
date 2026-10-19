import AVFoundation

/// Apple's on-device voices, including Premium/Enhanced downloads and the user's Personal Voice.
enum AppleVoices {
    static func all() -> [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                let ka = (a.voiceTraits.contains(.isPersonalVoice) ? 0 : 1, a.language.hasPrefix(lang) ? 0 : 1,
                          a.language, -a.quality.rawValue, a.name)
                let kb = (b.voiceTraits.contains(.isPersonalVoice) ? 0 : 1, b.language.hasPrefix(lang) ? 0 : 1,
                          b.language, -b.quality.rawValue, b.name)
                return ka < kb
            }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        if v.voiceTraits.contains(.isPersonalVoice) { return "\(v.name) (Personal Voice)" }
        switch v.quality {
        case .premium: return "\(v.name) (Premium)"
        case .enhanced: return "\(v.name) (Enhanced)"
        default: return v.name
        }
    }

    static func best() -> AVSpeechSynthesisVoice {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        return all().first { $0.language == lang && !$0.voiceTraits.contains(.isPersonalVoice) }
            ?? AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice.speechVoices()[0]
    }

    /// Resolve a stored voice: identifier first, then the display name the web version saved.
    static func find(_ idOrName: String) -> AVSpeechSynthesisVoice? {
        if let v = AVSpeechSynthesisVoice(identifier: idOrName) { return v }
        return all().first { label($0) == idOrName || $0.name == idOrName }
    }
}

/// Renders one utterance at a time to PCM buffers (no audio plays).
final class AppleRenderer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func render(_ text: String, voice: AVSpeechSynthesisVoice) async -> [AVAudioPCMBuffer] {
        await withCheckedContinuation { cont in
            lock.withLock { buffers = []; continuation = cont }
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            synth.write(u) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.finish() } else { self.lock.withLock { self.buffers.append(pcm.copy() as! AVAudioPCMBuffer) } }
            }
        }
    }

    private func finish() {
        let (cont, out) = lock.withLock { () -> (CheckedContinuation<[AVAudioPCMBuffer], Never>?, [AVAudioPCMBuffer]) in
            defer { continuation = nil }
            return (continuation, buffers)
        }
        cont?.resume(returning: out)
    }

    // Backstop in case the final empty buffer never arrives.
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish() }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

/// Plays a short sample of a voice through the speakers.
@MainActor
enum VoicePreview {
    private static let synth = AVSpeechSynthesizer()
    static func play(_ voice: AVSpeechSynthesisVoice) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: "Hi! This is how I'll sound reading your documents.")
        u.voice = voice
        synth.speak(u)
    }
}
