// SPDX-License-Identifier: CC0-1.0
import UIKit

/// Full-screen player: artwork, title and artist, a scrubber, transport,
/// shuffle and repeat, and lyrics under the controls when LRCLIB has them.
/// Dragged down it follows the finger, and closes once let go far or fast
/// enough.
final class MusicPlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let player = MusicPlayer.shared
    private let artwork = ThumbnailImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let shuffleButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private var timer: Timer?
    private var isScrubbing = false
    private var shownTrackId: String?
    private let lyricsView = OPLyricsView()
    private let downloadButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let sleepButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private var lyricsTrackId: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = ThemeManager.shared
        view.backgroundColor = theme.background
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 10
        artwork.backgroundColor = theme.surface
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = theme.primaryText
        titleLabel.numberOfLines = 2
        artistLabel.font = .systemFont(ofSize: 17)
        artistLabel.textColor = theme.secondaryText
        // The artist's name opens their page.
        artistLabel.isUserInteractionEnabled = true
        artistLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(artistTapped))
        )
        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = theme.secondaryText
        }
        remainingLabel.textAlignment = .right
        slider.minimumTrackTintColor = theme.accent
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(
            self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        slider.addTarget(self, action: #selector(scrubMoved), for: .valueChanged)
        spinner.color = theme.secondaryText

        let grabber = UIView()
        grabber.backgroundColor = theme.separator
        grabber.layer.cornerRadius = 2.5
        let times = UIStackView(arrangedSubviews: [elapsedLabel, remainingLabel])
        times.distribution = .fillEqually
        setup(shuffleButton, symbol: "shuffle", size: 20, action: #selector(shuffleTapped))
        setup(previousButton, symbol: "backward.fill", size: 28, action: #selector(previousTapped))
        setup(playButton, symbol: "play.fill", size: 44, action: #selector(playTapped))
        setup(nextButton, symbol: "forward.fill", size: 28, action: #selector(nextTapped))
        setup(repeatButton, symbol: "repeat", size: 20, action: #selector(repeatTapped))
        let controls = UIStackView(arrangedSubviews: [
            shuffleButton, previousButton, playButton, nextButton, repeatButton
        ])
        controls.distribution = .equalSpacing
        controls.alignment = .center
        let text = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        text.axis = .vertical
        text.spacing = 4
        lyricsView.textColor = theme.secondaryText
        lyricsView.highlightColor = theme.primaryText
        lyricsView.isHidden = true
        // A preview: it follows the song; a tap opens the lyrics screen.
        lyricsView.isInteractive = false
        lyricsView.onTap = { [weak self] in
            self?.openLyrics()
        }
        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        setup(queueButton, symbol: "list.bullet", size: 20, action: #selector(queueTapped))
        setup(moreButton, symbol: "ellipsis", size: 20, action: #selector(moreTapped))
        setup(sleepButton, symbol: "moon", size: 20, action: #selector(sleepTapped))
        for button in [queueButton, sleepButton, moreButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
        }
        for sub in [grabber, artwork, text, slider, times, controls, spinner, lyricsView, downloadButton] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            grabber.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 40),
            grabber.heightAnchor.constraint(equalToConstant: 5),
            downloadButton.centerYAnchor.constraint(equalTo: grabber.centerYAnchor, constant: 8),
            downloadButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            downloadButton.widthAnchor.constraint(equalToConstant: 44),
            downloadButton.heightAnchor.constraint(equalToConstant: 44),
            moreButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor),
            queueButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            queueButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            sleepButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            sleepButton.leadingAnchor.constraint(equalTo: queueButton.trailingAnchor),
            // Clear of the top buttons, not just the grabber.
            artwork.topAnchor.constraint(equalTo: downloadButton.bottomAnchor, constant: 16),
            artwork.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artwork.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -64),
            artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor),
            spinner.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            text.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 28),
            text.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            text.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            slider.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 16),
            slider.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            times.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            times.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            times.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            controls.topAnchor.constraint(equalTo: times.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            lyricsView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            lyricsView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            lyricsView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            lyricsView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            // Lyrics get at least this much; the artwork gives way on short
            // screens, and takes the full width when there is room.
            lyricsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        let fullWidth = artwork.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -64)
        fullWidth.priority = .defaultHigh
        fullWidth.isActive = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: MusicPlayer.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: DownloadStore.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: .OPSleepTimerDidChange,
            object: nil
        )
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func setup(_ button: UIButton, symbol: String, size: CGFloat, action: Selector) {
        button.setImage(
            UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size)
            ),
            for: .normal
        )
        button.tintColor = ThemeManager.shared.primaryText
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func setSymbol(_ button: UIButton, _ symbol: String, size: CGFloat) {
        button.setImage(
            UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size)
            ),
            for: .normal
        )
    }

    @objc
    private func refresh() {
        guard let track = player.current else {
            dismiss(animated: true)
            return
        }
        let theme = ThemeManager.shared
        titleLabel.text = track.title
        artistLabel.text = track.musicArtist
        if shownTrackId != track.id, let url = player.artworkURL(for: track) {
            shownTrackId = track.id
            artwork.setImage(url: url)
        }
        loadLyricsIfNeeded(for: track)
        let symbol: String
        switch MusicDownloads.state(of: track.id) {
        case .downloaded:
            symbol = "checkmark.circle.fill"
        case .queued:
            symbol = "arrow.down.circle.fill"
        case .none:
            symbol = "arrow.down.circle"
        }
        setSymbol(downloadButton, symbol, size: 22)
        // Never the dimmed grey of a disabled control: plain like its
        // neighbours until saved, then the accent.
        downloadButton.tintColor = MusicDownloads.state(of: track.id) == .none ? theme.primaryText : theme.accent
        player.isLoading ? spinner.startAnimating() : spinner.stopAnimating()
        let playing = player.player.timeControlStatus != .paused
        setSymbol(playButton, playing ? "pause.fill" : "play.fill", size: 44)
        shuffleButton.tintColor = player.isShuffled ? theme.accent : theme.secondaryText
        setSymbol(sleepButton, OPSleepTimer.isArmed ? "moon.fill" : "moon", size: 20)
        sleepButton.tintColor = OPSleepTimer.isArmed ? theme.accent : theme.primaryText
        switch player.repeatMode {
        case .off:
            setSymbol(repeatButton, "repeat", size: 20)
            repeatButton.tintColor = theme.secondaryText
        case .all:
            setSymbol(repeatButton, "repeat", size: 20)
            repeatButton.tintColor = theme.accent
        case .one:
            setSymbol(repeatButton, "repeat.1", size: 20)
            repeatButton.tintColor = theme.accent
        }
        updateTime()
    }

    private func updateTime() {
        let duration = player.duration
        let current = isScrubbing ? Double(slider.value) * duration : player.currentTime
        if !isScrubbing {
            slider.value = duration > 0 ? Float(current / duration) : 0
        }
        lyricsView.updateTime(player.currentTime)
        elapsedLabel.text = Self.format(current)
        remainingLabel.text = duration > 0 ? "-" + Self.format(duration - current) : "--:--"
    }

    // MARK: - Lyrics

    /// The lyrics screen, while it is up, follows the song too.
    private weak var lyricsScreen: OPLyricsViewController?
    private var clearedForTrackId: String?

    private func loadLyricsIfNeeded(for track: Video) {
        // A new song: the old lyrics go at once, not when the new ones land.
        if clearedForTrackId != track.id, lyricsTrackId != track.id {
            clearedForTrackId = track.id
            lyricsView.lyrics = nil
            lyricsView.isHidden = true
        }
        // Waits for the stream: its length is what matches the right version.
        // A stream that has not told its length yet goes by the listed one
        // ("4:59"); without either, matching would ignore length entirely.
        let listed = (track.duration ?? "").split(separator: ":")
            .compactMap { Int($0) }
            .reduce(0) { $0 * 60 + $1 }
        let duration = player.duration > 0 ? player.duration : TimeInterval(listed)
        guard lyricsTrackId != track.id, !player.isLoading, duration > 0 else {
            return
        }
        lyricsTrackId = track.id
        let trackId = track.id
        OPLyrics.fetch(
            forVideoId: track.id,
            title: track.title,
            artist: track.channelName,
            duration: duration
        ) { [weak self] lyrics in
            guard let self, self.player.current?.id == trackId else {
                return
            }
            AppLog.player(
                "lyrics for \(trackId) (\(Int(duration))s): "
                    + (lyrics.map {
                        "\($0.lines.count) lines, synced=\($0.isSynced), \($0.source), offset \($0.offset)"
                    } ?? "none")
            )
            self.lyricsView.lyrics = lyrics
            self.lyricsView.isHidden = lyrics == nil
            self.lyricsView.updateTime(self.player.currentTime)
            if let screen = self.lyricsScreen {
                if let lyrics {
                    screen.show(lyrics, title: track.title, artist: track.channelName)
                } else {
                    // Nothing to show for this song: the screen closes.
                    screen.dismiss(animated: true)
                }
            }
        }
    }

    private func openLyrics() {
        guard let lyrics = lyricsView.lyrics, let track = player.current else {
            return
        }
        let theme = ThemeManager.shared
        let screen = OPLyricsViewController(
            lyrics: lyrics, title: track.title, artist: track.channelName
        )
        screen.backgroundColor = theme.background
        screen.textColor = theme.secondaryText
        screen.highlightColor = theme.primaryText
        screen.currentTime = { [weak self] in
            self?.player.currentTime ?? 0
        }
        screen.onSeek = { [weak self] time in
            self?.player.seek(to: time)
        }
        screen.modalPresentationStyle = .fullScreen
        lyricsScreen = screen
        present(screen, animated: true)
    }

    // MARK: - Drag to close

    /// Only downward drags, and none that start on the scrubber. The lyrics
    /// preview does not scroll, so a drag there closes the player too.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let velocity = pan.velocity(in: view)
        let point = pan.location(in: view)
        if slider.frame.insetBy(dx: 0, dy: -12).contains(point) {
            return false
        }
        return velocity.y > abs(velocity.x)
    }

    @objc
    private func handlePan(_ pan: UIPanGestureRecognizer) {
        let offset = max(0, pan.translation(in: view).y)
        switch pan.state {
        case .changed:
            view.transform = CGAffineTransform(translationX: 0, y: offset)
        case .ended, .cancelled:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended, offset > view.bounds.height * 0.25 || velocity > 800 {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: .curveEaseOut,
                    animations: {
                        self.view.transform = CGAffineTransform(
                            translationX: 0, y: self.view.bounds.height
                        )
                    },
                    completion: { _ in
                        self.dismiss(animated: false)
                    }
                )
            } else {
                UIView.animate(
                    withDuration: 0.35,
                    delay: 0,
                    usingSpringWithDamping: 0.8,
                    initialSpringVelocity: 0,
                    options: [],
                    animations: { self.view.transform = .identity }
                )
            }
        default:
            break
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc
    private func scrubBegan() {
        isScrubbing = true
    }

    @objc
    private func scrubMoved() {
        updateTime()
    }

    @objc
    private func scrubEnded() {
        isScrubbing = false
        player.seek(to: Double(slider.value) * player.duration)
    }

    @objc
    private func artistTapped() {
        guard let track = player.current else {
            return
        }
        MusicNavigator.open(.artist, of: track, from: self)
    }

    @objc
    private func queueTapped() {
        Feedback.tap()
        let nav = RotatingNavigationController(rootViewController: MusicQueueViewController())
        present(nav, animated: true)
    }

    /// Sleep timer: a few lengths (fading out over the last minute), the end
    /// of this song or of the album/playlist, or off.
    @objc
    private func sleepTapped() {
        Feedback.tap()
        let theme = ThemeManager.shared
        let sheet = OPTrackSheet(title: "Sleep timer", subtitle: OPSleepTimer.statusText())
        sheet.cardColor = theme.surface
        sheet.textColor = theme.primaryText
        sheet.secondaryTextColor = theme.secondaryText
        sheet.accentColor = theme.accent
        sheet.fillColor = theme.separator
        var actions = OPSleepTimer.minuteChoices.map { minutes in
            OPSheetAction(title: "\(minutes.intValue) minutes", symbol: "timer", destructive: false) {
                OPSleepTimer.start(withMinutes: minutes.intValue)
            }
        }
        let endOfSong = OPSheetAction(title: "End of this song", symbol: "music.note", destructive: false) {
            OPSleepTimer.startForEndOfSong()
        }
        endOfSong.checked = OPSleepTimer.endOfSong
        actions.append(endOfSong)
        // Only where there is an end: not a radio, nor the mix after one.
        if player.playsCollection || OPSleepTimer.endOfContext {
            let endOfContext = OPSheetAction(
                title: "End of album/playlist", symbol: "music.note.list", destructive: false
            ) {
                OPSleepTimer.startForEndOfContext()
            }
            endOfContext.checked = OPSleepTimer.endOfContext
            actions.append(endOfContext)
        }
        if OPSleepTimer.isArmed {
            actions.append(OPSheetAction(title: "Turn off", symbol: "moon", destructive: true) {
                OPSleepTimer.cancel()
            })
        }
        sheet.actions = actions
        sheet.present(from: self)
    }

    @objc
    private func moreTapped() {
        guard let track = player.current else {
            return
        }
        MusicTrackMenu.show(for: track, from: self, anchor: moreButton)
    }

    @objc
    private func downloadTapped() {
        guard let track = player.current else {
            return
        }
        Feedback.tap()
        switch MusicDownloads.state(of: track.id) {
        case .none:
            MusicDownloads.download([track])
            refresh()
        case .queued:
            ToastView.show("Downloading…", in: view)
        case .downloaded:
            ToastView.show("Downloaded — plays offline", in: view)
        }
    }

    @objc
    private func playTapped() {
        Feedback.tap()
        player.togglePlayPause()
    }

    @objc
    private func nextTapped() {
        Feedback.tap()
        player.next()
    }

    @objc
    private func previousTapped() {
        Feedback.tap()
        player.previous()
    }

    @objc
    private func shuffleTapped() {
        Feedback.select()
        player.toggleShuffle()
    }

    @objc
    private func repeatTapped() {
        Feedback.select()
        player.cycleRepeat()
    }
}
