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

@MainActor
final class Playback: NSObject, ObservableObject, AVPlayerViewControllerDelegate {
    static let shared = Playback()

    enum Reporter {
        case server(ServerPlayback)
        case archive(ArchiveItem)
        case none
    }

    @Published var errorMessage: String?
    @Published private(set) var isPreparing = false

    private var player: AVPlayer?
    private var controller: SiparioPlayerController?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var reporter: Reporter = .none
    private var pipActive = false
    private var finished = true

    static func configureAudio() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: Avvio

    func play(_ item: JFItem) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                try await start(item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func start(_ item: JFItem) async throws {
        let p = try await Jellyfin.playback(for: item)
        let start = (item.progress ?? 0) < 0.95 ? item.resumeSeconds : 0
        begin(url: p.url, title: item.name ?? item.displayName, subtitle: item.isEpisode ? item.seriesName : nil,
              start: start, reporter: .server(p))
    }

    /// Riproduce un elemento del server sapendo solo l'id (carica prima i dati aggiornati).
    func play(jellyfinId: String) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let item = try await Jellyfin.item(jellyfinId)
                try await start(item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func play(_ item: ArchiveItem) {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let url = try await Archive.videoURL(item.identifier)
                let start = MyList.shared.archiveProgress[item.identifier]?.seconds ?? 0
                begin(url: url, title: item.title, subtitle: item.year, start: start, reporter: .archive(item))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func begin(url: URL, title: String, subtitle: String?, start: Double, reporter: Reporter) {
        finish()
        self.reporter = reporter
        finished = false

        let playerItem = AVPlayerItem(url: url)
        playerItem.externalMetadata = metadata(title: title, subtitle: subtitle)
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = true
        self.player = player

        if start > 5 {
            statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                      toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                    self.statusObservation = nil
                }
            }
        }

        let vc = SiparioPlayerController()
        vc.player = player
        vc.delegate = self
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.modalPresentationStyle = .fullScreen
        vc.onDismiss = { [weak self] in
            self?.controllerDismissed()
        }
        controller = vc

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reportProgress() }
        }

        Playback.configureAudio()
        try? AVAudioSession.sharedInstance().setActive(true)
        topViewController()?.present(vc, animated: true) {
            player.play()
        }

        if case .server(let p) = reporter {
            Task { await Jellyfin.reportStart(p, seconds: start, duration: 0) }
        }
    }

    private func metadata(title: String, subtitle: String?) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as! AVMetadataItem
        }
        var out = [item(.commonIdentifierTitle, title)]
        if let subtitle, !subtitle.isEmpty { out.append(item(.iTunesMetadataTrackSubTitle, subtitle)) }
        return out
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

    private func reportProgress() {
        guard !finished, let player else { return }
        if let error = player.currentItem?.error {
            errorMessage = "Riproduzione non riuscita: \(error.localizedDescription)"
        }
        switch reporter {
        case .server(let p):
            let s = currentSeconds
            let d = duration
            let paused = player.rate == 0
            Task { await Jellyfin.reportProgress(p, seconds: s, duration: d, paused: paused) }
        case .archive(let item):
            MyList.shared.setProgress(item, seconds: currentSeconds, duration: duration)
        case .none:
            break
        }
    }

    // MARK: Chiusura

    private func controllerDismissed() {
        // Se il video è passato in Picture in Picture continua a suonare.
        if pipActive { return }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let seconds = currentSeconds
        switch reporter {
        case .server(let p):
            let d = duration
            Task {
                await Jellyfin.reportStopped(p, seconds: seconds, duration: d)
                await JellyfinLibrary.shared.refresh()
            }
        case .archive(let item):
            MyList.shared.setProgress(item, seconds: seconds, duration: duration)
        case .none:
            break
        }
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        player = nil
        controller = nil
        reporter = .none
        pipActive = false
    }

    // MARK: Picture in Picture

    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { self.pipActive = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            self.pipActive = false
            // PiP chiuso con la X: se il player non è più a schermo, la visione è finita.
            if self.controller?.presentingViewController == nil {
                self.finish()
            }
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            guard let vc = self.controller, vc.presentingViewController == nil, let top = topViewController() else {
                completionHandler(true)
                return
            }
            top.present(vc, animated: true) { completionHandler(true) }
        }
    }
}
