import Foundation

enum Engine: String, Codable, CaseIterable, Identifiable {
    case apple, chatterbox
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple voices" : "Chatterbox (AI)" }
}

enum ItemStatus: String, Codable {
    case queued, working, done, error
}

/// One sentence of the document and where it sits in the audio. Same shape as `sync.json`.
struct Sentence: Codable, Hashable {
    var t: String
    var p: Int
    var s: Double?
    var e: Double?
}

struct SyncMap: Codable {
    var version = 1
    var sentences: [Sentence]
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var position: Double
    var note = ""
    var snippet = ""
    var created = Date()
}

struct Item: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var sourceName: String?
    var created: Date
    var engine: Engine
    /// AVSpeechSynthesisVoice identifier for Apple, or a clip file name ("" = built-in) for Chatterbox.
    var voice: String
    var voiceName: String
    var exaggeration = 0.5
    var status: ItemStatus
    var progress = 0.0
    var message: String?
    var chars: Int
    var duration: Double?
    var position = 0.0
    var finished = false
    var bookmarks: [Bookmark] = []

    var isBusy: Bool { status == .queued || status == .working }
    var engineLabel: String { engine == .apple ? voiceName : "Chatterbox · \(voiceName)" }
}

/// Settings chosen when making audio.
struct VoiceChoice: Equatable {
    var engine: Engine
    var appleVoiceID: String
    var appleVoiceName: String
    var clip: String
    var exaggeration: Double
}

func formatTime(_ s: Double?) -> String {
    let s = max(0, Int((s ?? 0).rounded(.down)))
    let h = s / 3600, m = s % 3600 / 60, x = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
}
