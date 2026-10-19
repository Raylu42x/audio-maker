import Foundation

/// Optional neural TTS. Runs Resemble AI's Chatterbox in its own uv-managed Python 3.11 env, so the app
/// itself never loads PyTorch. Only used when the user picks it.
enum Chatterbox {
    static let chunkChars = 280  // Chatterbox degrades on long inputs

    static var uvPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var isAvailable: Bool { uvPath != nil }

    static var threads: Int {
        let n = UserDefaults.standard.integer(forKey: "chatterboxThreads")
        return n > 0 ? n : 4
    }

    static func clips() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Library.voicesDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Synthesizes `chunks` into `workdir/00000.wav`… Resumable: existing wavs are skipped by the worker.
    static func run(chunks: [String], clip: String, exaggeration: Double, workdir: URL,
                    process: (Process) -> Void, progress: @escaping (Double, String) -> Void) async throws -> [URL] {
        guard let uv = uvPath else { throw NSError(domain: "Chatterbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chatterbox needs uv (brew install uv)."]) }
        guard let worker = Bundle.main.url(forResource: "chatterbox_worker", withExtension: "py") else {
            throw NSError(domain: "Chatterbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "chatterbox_worker.py missing from app bundle"])
        }
        var job: [String: Any] = ["chunks": chunks, "outdir": workdir.path, "exaggeration": exaggeration, "cfg_weight": 0.5]
        job["voice_clip"] = clip.isEmpty ? NSNull() : Library.voicesDir.appending(path: clip).path
        let jobURL = workdir.appending(path: "job.json")
        try JSONSerialization.data(withJSONObject: job).write(to: jobURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        // setuptools<81: resemble-perth (Chatterbox's watermarker) still imports pkg_resources.
        p.arguments = ["-n", "15", uv, "run", "--no-project", "--python", "3.11",
                       "--with", "chatterbox-tts", "--with", "soundfile", "--with", "setuptools<81",
                       "python", worker.path, jobURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\((uv as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin"
        env["OMP_NUM_THREADS"] = String(threads)
        env["AUDIO_MAKER_THREADS"] = String(threads)
        p.environment = env
        p.qualityOfService = .utility
        let out = Pipe()
        p.standardOutput = out
        let logURL = workdir.appending(path: "chatterbox.log")  // stderr to a file: tqdm output would fill a pipe
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardError = log
        progress(0, "Starting Chatterbox (the first run downloads a few GB — this can take a while)")
        try p.run()
        process(p)

        for try await line in out.fileHandleForReading.bytes.lines {
            if line.hasPrefix("PROGRESS "), let frac = line.split(separator: " ").last?.split(separator: "/"),
               frac.count == 2, let done = Double(frac[0]), let total = Double(frac[1]) {
                progress(done / total, "Chatterbox: part \(Int(done)) of \(Int(total))")
            } else if line.hasPrefix("STATUS ") {
                progress(0, String(line.dropFirst(7)))
            }
        }
        p.waitUntilExit()
        try? log.close()
        if p.terminationReason == .uncaughtSignal { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            let tail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").suffix(4).joined(separator: "\n")
            throw NSError(domain: "Chatterbox", code: 3, userInfo: [NSLocalizedDescriptionKey: "Chatterbox failed:\n\(tail)"])
        }
        return chunks.indices.map { workdir.appending(path: String(format: "%05d.wav", $0)) }
    }
}
