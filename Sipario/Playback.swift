import AVFoundation
import AVKit
import UIKit

/// Player a schermo intero con Picture in Picture e AirPlay.
final class SiparioPlayerController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
        }
    }
}

/// Lettori esterni, per i formati che il player di iOS non legge (es. MKV, AVI).
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case vlc, infuse
    var id: String { rawValue }
    var name: String { self == .vlc ? "VLC" : "Infuse" }

    func link(for url: URL) -> URL? {
        let enc = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        switch self {
        case .vlc: return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(enc)")
        case .infuse: return URL(string: "infuse://x-callback-url/play?url=\(enc)")
        }
    }
}

@MainActor
final class Playback: NSObject, ObservableObject, AVPlayerViewControllerDelegate {
    static let shared = Playback()

    struct Failure: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let message: String
    }

    @Published var failure: Failure?

    private var player: AVPlayer?
    private var controller: SiparioPlayerController?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentItem: MediaItem?
    private var currentEpisode: Episode?
    private var currentURL: URL?
    private var pipActive = false
    private var active = false

    private var store: LibraryStore { LibraryStore.shared }

    static func configureAudio() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: Avvio

    func play(_ item: MediaItem, episode: Episode? = nil) {
        var ep = episode
        if item.kind == .series && ep == nil { ep = store.resumeEpisode(for: item) }
        guard let url = ep?.url ?? item.url else { return }
        start(item: item, episode: ep, url: url)
    }

    private func start(item: MediaItem, episode: Episode?, url: URL) {
        let pid = episode?.id ?? item.id
        let startAt = item.kind == .live ? 0 : store.resumePosition(pid)
        currentItem = item
        currentEpisode = episode
        currentURL = url

        let playerItem = AVPlayerItem(url: url)
        playerItem.externalMetadata = metadata(item: item, episode: episode)
        observe(playerItem, startAt: startAt)

        if let player, active {
            // Episodio successivo nello stesso player.
            player.replaceCurrentItem(with: playerItem)
            player.play()
        } else {
            let player = AVPlayer(playerItem: playerItem)
            player.allowsExternalPlayback = true
            self.player = player
            let vc = SiparioPlayerController()
            vc.player = player
            vc.delegate = self
            vc.allowsPictureInPicturePlayback = true
            vc.canStartPictureInPictureAutomaticallyFromInline = true
            vc.modalPresentationStyle = .fullScreen
            vc.onDismiss = { [weak self] in self?.controllerDismissed() }
            controller = vc
            active = true
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveProgress() }
            }
            Playback.configureAudio()
            try? AVAudioSession.sharedInstance().setActive(true)
            topViewController()?.present(vc, animated: true) { player.play() }
        }
    }

    private func observe(_ playerItem: AVPlayerItem, startAt: Double) {
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if status == .readyToPlay, startAt > 5 {
                    self.player?.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                } else if status == .failed {
                    self.handleFailure(message)
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinishItem() }
        }
    }

    private func metadata(item: MediaItem, episode: Episode?) -> [AVMetadataItem] {
        func meta(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as! AVMetadataItem
        }
        if let episode {
            let title = episode.title.map { "\(episode.code) · \($0)" } ?? episode.code
            return [meta(.commonIdentifierTitle, title), meta(.iTunesMetadataTrackSubTitle, item.displayTitle)]
        }
        return [meta(.commonIdentifierTitle, item.displayTitle)]
    }

    // MARK: Episodio successivo

    private var nextEpisode: Episode? {
        guard let item = currentItem, let ep = currentEpisode else { return nil }
        return store.nextEpisode(after: ep, in: item)
    }

    private func playNext() {
        guard let item = currentItem, let next = nextEpisode else { return }
        saveProgress()
        if let ep = currentEpisode { store.setWatched(ep.id, seriesId: item.id, true) }
        start(item: item, episode: next, url: next.url)
    }

    private func didFinishItem() {
        saveProgress(finished: true)
        if AppSettings.shared.autoplayNext, nextEpisode != nil {
            playNext()
        } else if !pipActive {
            controller?.dismiss(animated: true)
        }
    }

    // MARK: Avanzamento

    private var currentSeconds: Double {
        guard let t = player?.currentTime().seconds, t.isFinite else { return 0 }
        return t
    }

    private var duration: Double {
        guard let d = player?.currentItem?.duration.seconds, d.isFinite else { return 0 }
        return d
    }

    private func saveProgress(finished: Bool = false) {
        guard active, let item = currentItem, item.kind != .live else { return }
        let pid = currentEpisode?.id ?? item.id
        let d = duration
        store.record(pid, seriesId: item.kind == .series ? item.id : nil,
                     seconds: finished ? d : currentSeconds, duration: d)
    }

    // MARK: Errori

    private func handleFailure(_ message: String?) {
        guard let url = currentURL else { return }
        let title = currentItem?.displayTitle ?? "Video"
        let text = "Il player di iOS non riesce ad aprire questo video (\(message ?? "formato non supportato")). Puoi aprirlo con un lettore come VLC o Infuse."
        let present = { [weak self] in
            self?.failure = Failure(url: url, title: title, message: text)
        }
        if let vc = controller, vc.presentingViewController != nil {
            finish()
            vc.dismiss(animated: true) { MainActor.assumeIsolated { present() } }
        } else {
            finish()
            present()
        }
    }

    // MARK: Chiusura

    private func controllerDismissed() {
        // Se il video è passato in Picture in Picture continua a suonare.
        if pipActive { return }
        finish()
    }

    private func finish() {
        guard active else { return }
        saveProgress()
        active = false
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        player = nil
        controller = nil
        pipActive = false
    }

    // MARK: Picture in Picture

    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { self.pipActive = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            self.pipActive = false
            if self.controller?.presentingViewController == nil { self.finish() }
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard let vc = self.controller, vc.presentingViewController == nil, let top = topViewController() else {
                completionHandler(true)
                return
            }
            top.present(vc, animated: true) { completionHandler(true) }
        }
    }
}
