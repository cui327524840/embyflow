import SwiftUI
import UIKit

/// Route every card through here so folders open a browser and titles open the
/// detail screen, without needing iOS 16's `navigationDestination`.
@ViewBuilder
func mediaDestination(for item: ItemDto, client: EmbyClient) -> some View {
    if item.isFolderLike {
        LibraryView(item: item, client: client)
    } else {
        ItemDetailView(item: item, client: client)
    }
}

/// Thin watch-progress line. Uses `scaleEffect` instead of a `GeometryReader`
/// so a grid of cards costs no extra layout passes.
struct WatchProgressBar: View {
    var value: Double
    var height: CGFloat = 3
    var tint: Color = Theme.accent

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.25))
            Capsule()
                .fill(tint)
                .scaleEffect(x: CGFloat(min(max(value, 0), 1)), anchor: .leading)
        }
        .frame(height: height)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.tertiaryText)
            }

            Spacer(minLength: 0)

            if let action = action {
                Button(action: action) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.tertiaryText)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Small translucent capsule used for metadata in the detail screen.
struct MetaPill: View {
    let text: String
    var icon: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.12))
        .cornerRadius(7)
    }
}

struct EpisodeRow: View {
    let item: ItemDto
    let client: EmbyClient
    var width: CGFloat = 150

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RemoteImage(
                    url: client.landscapeImageURL(for: item, maxWidth: Int(width * 2)),
                    targetSize: CGSize(width: width, height: width * 9 / 16)
                )
                VStack {
                    Spacer(minLength: 0)
                    if item.watchedProgress > 0.01 {
                        WatchProgressBar(value: item.watchedProgress, height: 2)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .cardShape(8)
            .cardStroke(8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let label = item.episodeLabel {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    if item.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.accent)
                    }
                }

                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let runtime = formatRuntime(item.duration) {
                    Text(runtime)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                }

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct LibraryTile: View {
    let item: ItemDto
    let client: EmbyClient

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(
                url: client.landscapeImageURL(for: item, maxWidth: 700),
                targetSize: CGSize(width: 220, height: 124)
            )

            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.85)]),
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let count = item.childCount ?? item.recursiveItemCount {
                    Text("\(count) 个项目")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.72))
                }
            }
            .padding(12)
        }
        .frame(height: 124)
        .cardShape(14)
        .cardStroke(14)
    }
}

struct FeaturedBanner: View {
    let item: ItemDto
    let client: EmbyClient

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(
                url: client.landscapeImageURL(for: item, maxWidth: 900),
                targetSize: CGSize(width: 390, height: 236)
            )
            .frame(height: 236)

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.92)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 236)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let progress = resumeText {
                        MetaPill(text: progress, icon: "clock.fill", tint: Theme.accent)
                    }
                    if let rating = item.communityRating {
                        MetaPill(text: String(format: "%.1f", rating), icon: "star.fill")
                    }
                    if let year = item.productionYear {
                        MetaPill(text: String(year))
                    }
                }

                Text(item.name)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(item.resumeSeconds == nil ? "播放" : "继续播放")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.accent)
                .cornerRadius(19)
                .padding(.top, 2)
            }
            .padding(16)
        }
        .frame(height: 236)
        .cardShape(18)
        .cardStroke(18)
    }

    private var resumeText: String? {
        guard !item.isPlayed,
              let position = item.resumeSeconds,
              let total = item.duration,
              position > 30 else { return nil }
        return "已看 \(Int(item.watchedProgress * 100))% · 剩 \(formatTimecode(max(0, total - position)))"
    }
}

struct ErrorBanner: View {
    let message: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.secondaryText)
            if let message = message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

/// Programmatic navigation for the collection view grids: UIKit cells call back
/// with an id, SwiftUI pushes the destination.
struct HiddenNavigationLink: View {
    let item: ItemDto
    let client: EmbyClient
    @Binding var isActive: Bool

    var body: some View {
        NavigationLink(
            destination: mediaDestination(for: item, client: client),
            isActive: $isActive,
            label: { EmptyView() }
        )
    }
}
