import SwiftUI
import UIKit

/// One card's worth of data, flattened out of `ItemDto` so the collection view
/// never has to touch model objects or the network client.
struct PosterGridItem: Hashable {
    let id: String
    let title: String
    let subtitle: String
    let imageURL: URL?
    let progress: Double
    let isPlayed: Bool
    let badge: String?
}

/// A UICollectionView backed grid / carousel.
///
/// SwiftUI's lazy stacks allocate and diff a lot of view values while
/// scrolling; on an A9 device that shows up as dropped frames. A collection
/// view reuses a fixed number of cells, supports `prefetchItemsAt` and keeps
/// scrolling entirely in the render server — which is what makes browsing feel
/// smooth on an iPhone 6s.
struct PosterGrid: UIViewRepresentable {
    enum Style: Equatable {
        case poster
        case landscape
    }

    enum Axis {
        case vertical
        case horizontal
    }

    let items: [PosterGridItem]
    var style: Style = .poster
    var axis: Axis = .vertical
    var onSelect: ((String) -> Void)?
    var onReachEnd: (() -> Void)?

    static let posterItemWidth: CGFloat = 124
    static let landscapeItemWidth: CGFloat = 232

    /// Height of one carousel row, so SwiftUI can lay it out without measuring.
    static func rowHeight(style: Style, itemWidth: CGFloat) -> CGFloat {
        let aspect: CGFloat = style == .poster ? 1.5 : 9.0 / 16.0
        return (itemWidth * aspect + textHeight).rounded()
    }

    /// Title + subtitle block below the artwork.
    static let textHeight: CGFloat = 44

    func makeUIView(context: Context) -> PosterGridHost {
        PosterGridHost(style: style, axis: axis)
    }

    func updateUIView(_ uiView: PosterGridHost, context: Context) {
        uiView.update(
            items: items,
            style: style,
            onSelect: onSelect,
            onReachEnd: onReachEnd
        )
    }

    // MARK: - Model → card conversion

    @MainActor
    static func makeItems(from mediaItems: [ItemDto], client: EmbyClient, style: Style) -> [PosterGridItem] {
        mediaItems.map { item in
            PosterGridItem(
                id: item.id,
                title: item.name,
                subtitle: subtitle(for: item, style: style),
                imageURL: imageURL(for: item, client: client, style: style),
                progress: item.watchedProgress,
                isPlayed: item.isPlayed,
                badge: item.communityRating.map { String(format: "%.1f", $0) }
            )
        }
    }

    @MainActor
    private static func imageURL(for item: ItemDto, client: EmbyClient, style: Style) -> URL? {
        switch style {
        case .poster:
            return client.posterImageURL(for: item, maxWidth: 420)
        case .landscape:
            return client.landscapeImageURL(for: item, maxWidth: 560)
        }
    }

    private static func subtitle(for item: ItemDto, style: Style) -> String {
        if style == .landscape,
           !item.isPlayed,
           let total = item.duration,
           let position = item.resumeSeconds {
            let remaining = max(0, total - position)
            if remaining > 30 {
                return "剩余 " + formatTimecode(remaining)
            }
        }
        if let label = item.episodeLabel {
            if let runtime = formatRuntime(item.duration) {
                return "\(label) · \(runtime)"
            }
            return label
        }
        let meta = item.shortMetaLine
        return meta.isEmpty ? (item.mediaType == "Video" ? "视频" : "") : meta
    }
}

// MARK: - Host view

final class PosterGridHost: UIView, UICollectionViewDelegateFlowLayout {
    private let collectionView: UICollectionView
    private let flowLayout = UICollectionViewFlowLayout()
    private let style: PosterGrid.Style
    private let axis: PosterGrid.Axis

    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private var items: [PosterGridItem] = []
    private var itemsByID: [String: PosterGridItem] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private var targetSize: CGSize = .zero

    var onSelect: ((String) -> Void)?
    var onReachEnd: (() -> Void)?

    init(style: PosterGrid.Style, axis: PosterGrid.Axis) {
        self.style = style
        self.axis = axis

        flowLayout.scrollDirection = axis == .horizontal ? .horizontal : .vertical
        flowLayout.minimumInteritemSpacing = 12
        flowLayout.minimumLineSpacing = axis == .horizontal ? 12 : 16
        flowLayout.sectionInset = axis == .horizontal
            ? UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            : UIEdgeInsets(top: 16, left: 16, bottom: 28, right: 16)
        flowLayout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        super.init(frame: .zero)

        backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = axis == .vertical
        collectionView.isDirectionalLockEnabled = true
        collectionView.alwaysBounceVertical = axis == .vertical
        collectionView.alwaysBounceHorizontal = axis == .horizontal
        collectionView.contentInsetAdjustmentBehavior = axis == .vertical ? .automatic : .never
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        configureDataSource()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = collectionView.bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        collectionView.collectionViewLayout.invalidateLayout()
        updateTargetSize(for: width)
    }

    // MARK: - Updates

    func update(
        items newItems: [PosterGridItem],
        style: PosterGrid.Style,
        onSelect: ((String) -> Void)?,
        onReachEnd: (() -> Void)?
    ) {
        self.onSelect = onSelect
        self.onReachEnd = onReachEnd

        guard newItems != items else { return }
        items = newItems
        itemsByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        updateTargetSize(for: collectionView.bounds.width)

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems.map { $0.id }, toSection: 0)
        // Never animate: appending a page must not move what the user is reading.
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private func updateTargetSize(for width: CGFloat) {
        let itemWidth = itemWidth(for: width)
        let aspect: CGFloat = style == .poster ? 1.5 : 9.0 / 16.0
        targetSize = CGSize(width: itemWidth, height: (itemWidth * aspect).rounded())
    }

    // MARK: - Data source

    private func configureDataSource() {
        let posterRegistration = UICollectionView.CellRegistration<PosterCell, String> { [weak self] cell, _, id in
            guard let self = self, let item = self.itemsByID[id] else { return }
            cell.configure(item: item, targetSize: self.targetSize, scale: UIScreen.main.scale)
        }

        let landscapeRegistration = UICollectionView.CellRegistration<LandscapeMediaCell, String> { [weak self] cell, _, id in
            guard let self = self, let item = self.itemsByID[id] else { return }
            cell.configure(item: item, targetSize: self.targetSize, scale: UIScreen.main.scale)
        }

        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id -> UICollectionViewCell? in
            guard let self = self else { return nil }
            switch self.style {
            case .poster:
                return collectionView.dequeueConfiguredReusableCell(
                    using: posterRegistration, for: indexPath, item: id
                )
            case .landscape:
                return collectionView.dequeueConfiguredReusableCell(
                    using: landscapeRegistration, for: indexPath, item: id
                )
            }
        }
    }

    // MARK: - Layout metrics

    private func itemWidth(for width: CGFloat) -> CGFloat {
        switch axis {
        case .horizontal:
            return style == .poster ? PosterGrid.posterItemWidth : PosterGrid.landscapeItemWidth
        case .vertical:
            let available = max(width - 32, 120)
            let minWidth: CGFloat = style == .poster ? 104 : 220
            let spacing: CGFloat = 12
            var columns = max(2, Int((available + spacing) / (minWidth + spacing)))
            if style == .landscape {
                columns = max(1, columns)
            }
            let usable = available - spacing * CGFloat(columns - 1)
            return floor(usable / CGFloat(columns))
        }
    }

    // MARK: - UICollectionViewDelegate / delegate flow layout

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = itemWidth(for: collectionView.bounds.width)
        let aspect: CGFloat = style == .poster ? 1.5 : 9.0 / 16.0
        return CGSize(width: width, height: (width * aspect + PosterGrid.textHeight).rounded())
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        onSelect?(id)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard !items.isEmpty, indexPath.item >= items.count - 8 else { return }
        onReachEnd?()
    }
}

// MARK: - Prefetching

extension PosterGridHost: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let urls: [URL?] = indexPaths.compactMap { indexPath in
            guard indexPath.item < items.count else { return nil }
            return items[indexPath.item].imageURL
        }
        ImagePipeline.shared.prefetch(urls, target: targetSize, scale: UIScreen.main.scale, limit: 12)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        // Decodes that already started are cheap to finish and land in the cache.
    }
}

// MARK: - Cells

private class MediaCellBase: UICollectionViewCell {
    let imageView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let playedBadge = UIView()
    private let playedCheck = UIImageView()
    let ratingLabel = PillLabel()

    private var fillWidthConstraint: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?
    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func imageAspectRatio() -> CGFloat { 1.5 }

    private func setUp() {
        contentView.backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        imageView.layer.borderWidth = 0.5
        imageView.layer.borderColor = UIColor.white.withAlphaComponent(0.07).cgColor
        imageView.backgroundColor = UIColor(red: 0.152, green: 0.164, blue: 0.180, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.66, alpha: 1)
        subtitleLabel.lineBreakMode = .byTruncatingTail

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        progressTrack.layer.cornerRadius = 1.5
        progressTrack.clipsToBounds = true
        progressFill.backgroundColor = UIColor(red: 0.322, green: 0.710, blue: 0.294, alpha: 1)
        progressTrack.addSubview(progressFill)

        playedBadge.backgroundColor = UIColor(red: 0.322, green: 0.710, blue: 0.294, alpha: 0.95)
        playedBadge.layer.cornerRadius = 9
        playedCheck.image = UIImage(systemName: "checkmark")?.withRenderingMode(.alwaysTemplate)
        playedCheck.tintColor = .black
        playedCheck.contentMode = .scaleAspectFit
        playedBadge.addSubview(playedCheck)

        ratingLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        ratingLabel.textColor = .white
        ratingLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        ratingLabel.layer.cornerRadius = 8
        ratingLabel.clipsToBounds = true

        for view in [imageView, titleLabel, subtitleLabel, progressTrack, playedBadge, ratingLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        playedCheck.translatesAutoresizingMaskIntoConstraints = false
        progressFill.translatesAutoresizingMaskIntoConstraints = false

        let fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint = fillWidth

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: imageAspectRatio()),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
            progressTrack.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -6),
            progressTrack.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),

            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,

            playedBadge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 7),
            playedBadge.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -7),
            playedBadge.widthAnchor.constraint(equalToConstant: 18),
            playedBadge.heightAnchor.constraint(equalToConstant: 18),

            playedCheck.centerXAnchor.constraint(equalTo: playedBadge.centerXAnchor),
            playedCheck.centerYAnchor.constraint(equalTo: playedBadge.centerYAnchor),
            playedCheck.widthAnchor.constraint(equalToConstant: 11),
            playedCheck.heightAnchor.constraint(equalToConstant: 11),

            ratingLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 7),
            ratingLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 7)
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillWidthConstraint?.constant = progressTrack.bounds.width * CGFloat(min(max(progress, 0), 1))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        imageView.image = nil
        titleLabel.text = nil
        subtitleLabel.text = nil
        ratingLabel.text = nil
        ratingLabel.isHidden = true
        playedBadge.isHidden = true
        progressTrack.isHidden = true
        progress = 0
    }

    func configure(item: PosterGridItem, targetSize: CGSize, scale: CGFloat) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        subtitleLabel.isHidden = item.subtitle.isEmpty

        ratingLabel.text = item.badge
        ratingLabel.isHidden = item.badge == nil

        playedBadge.isHidden = !item.isPlayed
        progress = item.progress
        progressTrack.isHidden = item.progress <= 0.01
        setNeedsLayout()

        imageTask?.cancel()
        if let cached = ImagePipeline.shared.cachedImage(for: item.imageURL, target: targetSize, scale: scale) {
            imageView.image = cached
            return
        }
        imageView.image = nil

        guard let url = item.imageURL else { return }
        imageTask = Task { [weak self] in
            let image = await ImagePipeline.shared.image(for: url, target: targetSize, scale: scale)
            guard !Task.isCancelled, let self = self else { return }
            self.imageView.image = image
        }
    }
}

private final class PosterCell: MediaCellBase {
    override func imageAspectRatio() -> CGFloat { 1.5 }
}

private final class LandscapeMediaCell: MediaCellBase {
    override func imageAspectRatio() -> CGFloat { 9.0 / 16.0 }
}

/// UILabel with padding, used for the small rating pill.
private final class PillLabel: UILabel {
    private let insets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(
            width: base.width + insets.left + insets.right,
            height: base.height + insets.top + insets.bottom
        )
    }
}
