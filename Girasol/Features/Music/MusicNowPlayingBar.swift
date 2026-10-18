// SPDX-License-Identifier: CC0-1.0
import UIKit

/// The strip above the tab bar while something plays: artwork, title,
/// artist, previous, play/pause and next. Tapping it opens the full player.
final class MusicNowPlayingBar: UIView {
    static let height: CGFloat = 60

    var onOpen: (() -> Void)?

    private let artwork = ThumbnailImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var timer: Timer?
    private var shownTrackId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 4
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        artistLabel.font = .systemFont(ofSize: 13)
        previousButton.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        let text = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        text.axis = .vertical
        text.spacing = 1
        for sub in [progress, artwork, text, previousButton, playButton, nextButton] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: topAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            artwork.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            artwork.widthAnchor.constraint(equalToConstant: 40),
            artwork.heightAnchor.constraint(equalToConstant: 40),
            text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            text.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -8),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nextButton.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
            playButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor),
            playButton.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            previousButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor),
            previousButton.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 44),
            previousButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openTapped)))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: MusicPlayer.didChangeNotification,
            object: nil
        )
        // Common modes: the progress keeps moving while a list scrolls.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        timer?.invalidate()
    }

    @objc
    func refresh() {
        let theme = ThemeManager.shared
        let player = MusicPlayer.shared
        backgroundColor = theme.surface
        titleLabel.textColor = theme.primaryText
        artistLabel.textColor = theme.secondaryText
        previousButton.tintColor = theme.primaryText
        playButton.tintColor = theme.primaryText
        nextButton.tintColor = theme.primaryText
        progress.progressTintColor = theme.accent
        progress.trackTintColor = .clear
        guard let track = player.current else {
            return
        }
        titleLabel.text = track.title
        artistLabel.text = player.isLoading ? "Loading…" : track.musicArtist
        if shownTrackId != track.id, let url = player.artworkURL(for: track) {
            shownTrackId = track.id
            artwork.setImage(url: url)
        }
        let playing = player.player.timeControlStatus != .paused
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        updateProgress()
    }

    private func updateProgress() {
        let player = MusicPlayer.shared
        let duration = player.duration
        progress.progress = duration > 0 ? Float(player.currentTime / duration) : 0
    }

    @objc
    private func previousTapped() {
        Feedback.tap()
        MusicPlayer.shared.previous()
    }

    @objc
    private func playTapped() {
        Feedback.tap()
        MusicPlayer.shared.togglePlayPause()
    }

    @objc
    private func nextTapped() {
        Feedback.tap()
        MusicPlayer.shared.next()
    }

    @objc
    private func openTapped() {
        onOpen?()
    }
}
