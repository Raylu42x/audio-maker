import AVFoundation
import Foundation

/// Makes audio for queued items, one at a time, at low priority so the Mac stays responsive.
@MainActor
final class Generator: ObservableObject {
    private let library: Library
    private var task: Task<Void, Never>?
    private var currentID: String?
    private var process: Process?
    private var renderer: AppleRenderer?

    init(library: Library) {
        self.library = library
    }

    func kick() {
        guard task == nil, let next = library.items.last(where: { $0.status == .queued }) else { return }
        currentID = next.id
        task = Task(priority: .utility) { [weak self] in
            await self?.run(next)
            guard let self else { return }
            self.task = nil
            self.currentID = nil
            self.process = nil
            self.renderer = nil
            self.kick()
        }
    }

    /// Stop work on an item that's being deleted or re-made.
    func cancel(_ id: String) {
        guard id == currentID else { return }
        task?.cancel()
        process?.terminate()
        renderer?.stop()
    }

    private func run(_ item: Item) async {
        let id = item.id
        library.update(id) { $0.status = .working; $0.progress = 0; $0.message = "Starting" }
        let dir = Library.dir(id)
        let partial = dir.appending(path: "audio.partial.m4a")
        let text = library.text(id)
        var lastPersist = Date.distantPast
        let report: (Double, String) -> Void = { [weak self] frac, msg in
            Task { @MainActor in
                // Keep UI live but only rewrite item.json every few seconds.
                let persist = Date().timeIntervalSince(lastPersist) > 3
                if persist { lastPersist = Date() }
                guard let self, self.library.item(id)?.status == .working else { return }  // late update after finishing
                self.library.update(id, persist: persist) { $0.progress = frac * 0.98; $0.message = msg }
            }
        }
        do {
            let sync: SyncMap
            let duration: Double
            switch item.engine {
            case .apple:
                (sync, duration) = try await renderApple(text, voiceID: item.voice, to: partial, progress: report)
            case .chatterbox:
                (sync, duration) = try await renderChatterbox(text, item: item, to: partial, progress: report)
            }
            try Task.checkCancellation()
            try JSONEncoder().encode(sync).write(to: dir.appending(path: "sync.json"))
            let final = Library.audioURL(id)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            try? FileManager.default.removeItem(at: dir.appending(path: "parts"))
            library.update(id) { $0.status = .done; $0.progress = 1; $0.message = nil; $0.duration = duration }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            library.update(id) { $0.status = .error; $0.message = error.localizedDescription }
        }
    }

    /// Apple voices: one utterance per sentence, so every sentence's start/end time is exact.
    private func renderApple(_ text: String, voiceID: String, to url: URL,
                             progress: @escaping (Double, String) -> Void) async throws -> (SyncMap, Double) {
        var sents = TextPlanner.sentences(text)
        let voice = AppleVoices.find(voiceID) ?? AppleVoices.best()
        let r = AppleRenderer()
        renderer = r
        let writer = try AudioWriter(url: url)
        for i in sents.indices {
            try Task.checkCancellation()
            let buffers = await r.render(sents[i].t, voice: voice)
            sents[i].s = (writer.seconds * 100).rounded() / 100
            try writer.append(buffers)
            sents[i].e = (writer.seconds * 100).rounded() / 100
            let paragraphEnds = i + 1 < sents.count && sents[i + 1].p != sents[i].p
            try writer.silence(paragraphEnds ? 0.45 : 0.12)
            if i % 4 == 0 || i == sents.count - 1 {
                progress(Double(i + 1) / Double(sents.count), "Speaking sentence \(i + 1) of \(sents.count)")
            }
            await Task.yield()
        }
        writer.close()
        return (SyncMap(sentences: sents), writer.seconds)
    }

    /// Chatterbox: short multi-sentence chunks; sentence times inside a chunk are estimated by length.
    private func renderChatterbox(_ text: String, item: Item, to url: URL,
                                  progress: @escaping (Double, String) -> Void) async throws -> (SyncMap, Double) {
        var (sents, groups) = TextPlanner.plan(text, maxChars: Chatterbox.chunkChars)
        let work = Library.dir(item.id).appending(path: "parts")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let files = try await Chatterbox.run(
            chunks: groups.map { TextPlanner.groupText(sents, $0) }, clip: item.voice,
            exaggeration: item.exaggeration, workdir: work,
            process: { [weak self] p in Task { @MainActor in self?.process = p } }, progress: progress)
        try Task.checkCancellation()
        progress(1, "Stitching audio together")
        let writer = try AudioWriter(url: url)
        for (g, f) in zip(groups, files) {
            let start = writer.seconds
            try writer.appendFile(f)
            let dur = writer.seconds - start
            let weights = g.map { TextPlanner.speechWeight(sents[$0].t) }
            let total = weights.reduce(0, +)
            var t = start
            for (i, w) in zip(g, weights) {
                sents[i].s = (t * 100).rounded() / 100
                t += dur * w / total
                sents[i].e = (t * 100).rounded() / 100
            }
        }
        writer.close()
        return (SyncMap(sentences: sents), writer.seconds)
    }
}
