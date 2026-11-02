import Foundation
import SQLite3

/// The on-disk library: one folder per item holding item.json, text.txt, sync.json and audio.m4a.
@MainActor
final class Library: ObservableObject {
    static let home: URL = {
        if let custom = ProcessInfo.processInfo.environment["AUDIO_MAKER_HOME"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Audio Maker")
    }()
    static let itemsDir = home.appending(path: "items")
    static let voicesDir = home.appending(path: "voices")  // Chatterbox voice-cloning clips

    @Published private(set) var items: [Item] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.itemsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.voicesDir, withIntermediateDirectories: true)
        migrateFromWebVersion()
        load()
    }

    // MARK: - Paths

    static func dir(_ id: String) -> URL { itemsDir.appending(path: id) }
    static func audioURL(_ id: String) -> URL { dir(id).appending(path: "audio.m4a") }
    func text(_ id: String) -> String { (try? String(contentsOf: Self.dir(id).appending(path: "text.txt"), encoding: .utf8)) ?? "" }

    func sync(_ id: String) -> SyncMap? {
        guard let data = try? Data(contentsOf: Self.dir(id).appending(path: "sync.json")) else { return nil }
        return try? JSONDecoder().decode(SyncMap.self, from: data)
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    // MARK: - Load / save

    private func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.itemsDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Item] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appending(path: "item.json")),
                  var it = try? decoder.decode(Item.self, from: data) else { continue }
            if it.status == .working {  // interrupted by quitting: start again
                it.status = .queued
                it.progress = 0
                write(it)
            }
            loaded.append(it)
        }
        items = loaded.sorted { $0.created > $1.created }
    }

    private func write(_ it: Item) {
        guard let data = try? encoder.encode(it) else { return }
        try? data.write(to: Self.dir(it.id).appending(path: "item.json"), options: .atomic)
    }

    func update(_ id: String, persist: Bool = true, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        if persist { write(items[i]) }
    }

    func add(title: String, sourceName: String?, text: String, voice: VoiceChoice) throws -> Item {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let d = Self.dir(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try text.write(to: d.appending(path: "text.txt"), atomically: true, encoding: .utf8)
        var it = Item(id: id, title: title, sourceName: sourceName, created: Date(), engine: voice.engine,
                      voice: "", voiceName: "", status: .queued, chars: text.count)
        apply(voice, to: &it)
        write(it)
        items.insert(it, at: 0)
        return it
    }

    /// Throw away the audio and queue the item again with a different voice.
    func remake(_ id: String, voice: VoiceChoice) {
        let d = Self.dir(id)
        for f in ["audio.m4a", "audio.partial.m4a", "sync.json"] { try? FileManager.default.removeItem(at: d.appending(path: f)) }
        try? FileManager.default.removeItem(at: d.appending(path: "parts"))
        update(id) {
            self.apply(voice, to: &$0)
            $0.status = .queued; $0.progress = 0; $0.message = nil; $0.duration = nil
            $0.position = 0; $0.finished = false
        }
    }

    private func apply(_ v: VoiceChoice, to it: inout Item) {
        it.engine = v.engine
        if v.engine == .apple {
            it.voice = v.appleVoiceID
            it.voiceName = v.appleVoiceName
        } else {
            it.voice = v.clip
            it.voiceName = v.clip.isEmpty ? "Built-in voice" : v.clip
            it.exaggeration = v.exaggeration
        }
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.dir(id))
    }

    // MARK: - Bookmarks

    @discardableResult
    func addBookmark(_ id: String, at position: Double) -> Bookmark? {
        var snippet = ""
        if let sents = sync(id)?.sentences, !sents.isEmpty {
            snippet = (sents.first { ($0.e ?? 0) > position } ?? sents[sents.count - 1]).t
        }
        let b = Bookmark(position: position, snippet: snippet)
        update(id) {
            $0.bookmarks.append(b)
            $0.bookmarks.sort { $0.position < $1.position }
        }
        return b
    }

    func setNote(_ itemID: String, _ bookmarkID: UUID, _ note: String) {
        update(itemID) { it in
            if let i = it.bookmarks.firstIndex(where: { $0.id == bookmarkID }) { it.bookmarks[i].note = note }
        }
    }

    func deleteBookmark(_ itemID: String, _ bookmarkID: UUID) {
        update(itemID) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
    }

    var allBookmarks: [(item: Item, bookmark: Bookmark)] {
        items.flatMap { it in it.bookmarks.map { (it, $0) } }.sorted { $0.bookmark.created > $1.bookmark.created }
    }

    // MARK: - Import from the old web version (library.db)

    private func migrateFromWebVersion() {
        let db = Self.home.appending(path: "library.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return }
        var h: OpaquePointer?
        guard sqlite3_open_v2(db.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(h) }

        func rows(_ sql: String, _ bind: String? = nil, _ each: (OpaquePointer) -> Void) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
            defer { sqlite3_finalize(st) }
            if let bind { sqlite3_bind_text(st, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            while sqlite3_step(st) == SQLITE_ROW { each(st) }
        }
        func str(_ st: OpaquePointer, _ i: Int32) -> String? {
            sqlite3_column_text(st, i).map { String(cString: $0) }
        }

        rows("SELECT id, title, source_name, created, engine, voice, status, chars, duration, position, finished FROM items") { st in
            guard let id = str(st, 0) else { return }
            let d = Self.dir(id)
            guard FileManager.default.fileExists(atPath: d.path),
                  !FileManager.default.fileExists(atPath: d.appending(path: "item.json").path) else { return }
            let voice = str(st, 5) ?? ""
            let hasAudio = FileManager.default.fileExists(atPath: d.appending(path: "audio.m4a").path)
            var it = Item(
                id: id, title: str(st, 1) ?? id, sourceName: str(st, 2),
                created: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                engine: Engine(rawValue: str(st, 4) ?? "apple") ?? .apple,
                voice: voice, voiceName: voice,
                status: hasAudio ? .done : .queued,
                chars: Int(sqlite3_column_int64(st, 7)))
            if sqlite3_column_type(st, 8) != SQLITE_NULL { it.duration = sqlite3_column_double(st, 8) }
            it.position = sqlite3_column_double(st, 9)
            it.finished = sqlite3_column_int(st, 10) != 0
            rows("SELECT position, note, snippet, created FROM bookmarks WHERE item_id = ? ORDER BY position", id) { b in
                it.bookmarks.append(Bookmark(position: sqlite3_column_double(b, 0), note: str(b, 1) ?? "",
                                             snippet: str(b, 2) ?? "",
                                             created: Date(timeIntervalSince1970: sqlite3_column_double(b, 3))))
            }
            write(it)
        }
        try? FileManager.default.moveItem(at: db, to: Self.home.appending(path: "library.db.imported"))
    }
}
