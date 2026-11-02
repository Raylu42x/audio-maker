import AVFoundation

/// Appends PCM audio of any format into a single mono AAC .m4a and tracks the exact running time.
final class AudioWriter {
    static let sampleRate = 24_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioWriter.sampleRate, channels: 1, interleaved: false)!
    private let file: AVAudioFile
    private(set) var frames: AVAudioFramePosition = 0
    var seconds: Double { Double(frames) / Self.sampleRate }

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ input: [AVAudioPCMBuffer]) throws {
        guard let first = input.first else { return }
        if first.format == format {
            for b in input { try file.write(from: b); frames += AVAudioFramePosition(b.frameLength) }
            return
        }
        guard let converter = AVAudioConverter(from: first.format, to: format) else {
            throw NSError(domain: "AudioWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format \(first.format)"])
        }
        let total = input.reduce(0) { $0 + Double($1.frameLength) }
        let capacity = AVAudioFrameCount(total * format.sampleRate / first.format.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var next = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if next < input.count {
                inputStatus.pointee = .haveData
                defer { next += 1 }
                return input[next]
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { throw error ?? NSError(domain: "AudioWriter", code: 2) }
        try file.write(from: out)
        frames += AVAudioFramePosition(out.frameLength)
    }

    func silence(_ secs: Double) throws {
        let n = AVAudioFrameCount(secs * Self.sampleRate)
        guard n > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
        b.frameLength = n  // freshly allocated buffers are zeroed
        try file.write(from: b)
        frames += AVAudioFramePosition(n)
    }

    func appendFile(_ url: URL) throws {
        let f = try AVAudioFile(forReading: url)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return }
        try f.read(into: b)
        try append([b])
    }

    func close() { file.close() }
}
