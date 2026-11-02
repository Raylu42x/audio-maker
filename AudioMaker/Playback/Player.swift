import AVFoundation
import MediaPlayer

/// Plays library items, remembers positions, and hooks up media keys / Now Playing.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var itemID: String?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "playbackRate")
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
        }
    }

    private let player = AVPlayer()
    private let library: Library
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date()

    init(library: Library) {
        self.library = library
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        setUpRemoteCommands()
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        time = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d != duration { duration = d }
        let playing = player.timeControlStatus != .paused
        if playing != isPlaying { isPlaying = playing; updateNowPlaying() }
        if Date().timeIntervalSince(lastSaved) > 5 { savePosition() }
    }

    func play(_ id: String, at start: Double? = nil) {
        guard let item = library.item(id), item.status == .done else { return }
        if itemID != id {
            savePosition()
            itemID = id
            let pi = AVPlayerItem(url: Library.audioURL(id))
            pi.audioTimePitchAlgorithm = .timeDomain  // clearest for speech when sped up
            player.replaceCurrentItem(with: pi)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: pi, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didFinish() }
            }
            duration = item.duration ?? 0
            let resume = start ?? ((item.position > 5 && !item.finished && item.position < (item.duration ?? 0) - 3) ? item.position : 0)
            seek(to: resume)
        } else if let start {
            seek(to: start)
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle(selected: String? = nil) {
        if itemID == nil, let selected { return play(selected) }
        isPlaying ? pause() : player.play()
        isPlaying.toggle()
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
        updateNowPlaying()
    }

    func stop() {
        savePosition()
        player.replaceCurrentItem(with: nil)
        itemID = nil; isPlaying = false; time = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to t: Double) {
        let t = max(0, min(t, duration > 0 ? duration : t))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(_ by: Double) { seek(to: time + by) }

    func savePosition() {
        lastSaved = Date()
        guard let id = itemID else { return }
        let t = time
        library.update(id) { $0.position = t }
    }

    private func didFinish() {
        guard let id = itemID else { return }
        isPlaying = false
        library.update(id) { $0.position = 0; $0.finished = true }
        updateNowPlaying()
    }

    // MARK: - Media keys / Control Center

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.playCommand.addTarget { [weak self] _ in self?.player.play(); self?.isPlaying = true; return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(30); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let id = itemID, let item = library.item(id) else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: "Audio Maker",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
