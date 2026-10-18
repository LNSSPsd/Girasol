// SPDX-License-Identifier: CC0-1.0
import UIKit

/// The one row style of music mode: artwork (or a track number), two lines of
/// text, the playing track in the accent color.
final class MusicItemCell: UITableViewCell {
    static let reuseId = "MusicItemCell"
    static let height: CGFloat = 68

    private let artwork = ThumbnailImageView(frame: .zero)
    private let indexLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    /// Set for song rows: shows the "…" button, called with it as anchor.
    var onMore: ((UIView) -> Void)? {
        didSet { moreButton.isHidden = onMore == nil }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 4
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        indexLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 13)
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.isHidden = true
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        for view in [artwork, indexLabel, text, moreButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artwork.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 52),
            artwork.heightAnchor.constraint(equalToConstant: 52),
            indexLabel.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            indexLabel.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `number` shows a track number in place of the artwork.
    func configure(
        title: String,
        subtitle: String,
        artworkURL: String?,
        number: Int? = nil,
        isCurrent: Bool = false
    ) {
        let theme = ThemeManager.shared
        backgroundColor = theme.background
        contentView.backgroundColor = theme.background
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleLabel.textColor = isCurrent ? theme.accent : theme.primaryText
        subtitleLabel.textColor = theme.secondaryText
        moreButton.tintColor = theme.secondaryText
        indexLabel.textColor = isCurrent ? theme.accent : theme.secondaryText
        if let number {
            artwork.cancel()
            artwork.image = nil
            artwork.isHidden = true
            indexLabel.isHidden = false
            indexLabel.text = "\(number)"
        } else {
            artwork.isHidden = false
            indexLabel.isHidden = true
            artwork.backgroundColor = theme.surface
            if let artworkURL, let url = URL(string: artworkURL) {
                artwork.setImage(url: url)
            } else {
                artwork.cancel()
                artwork.image = UIImage(systemName: "music.note")
                artwork.tintColor = theme.secondaryText
                artwork.contentMode = .center
                return
            }
            artwork.contentMode = .scaleAspectFill
        }
    }

    @objc
    private func moreTapped() {
        onMore?(moreButton)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onMore = nil
        artwork.cancel()
        artwork.image = nil
    }
}
