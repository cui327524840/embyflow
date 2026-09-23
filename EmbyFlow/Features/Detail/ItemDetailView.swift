import SwiftUI

@MainActor
final class ItemDetailViewModel: ObservableObject {
    @Published private(set) var item: ItemDto
    @Published private(set) var seasons: [ItemDto] = []
    @Published private(set) var episodes: [ItemDto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedSeasonId: String?
    @Published var isOverviewExpanded = false

    private var hasLoaded = false

    nonisolated init(item: ItemDto) {
        self.item = item
    }

    func loadIfNeeded(client: EmbyClient) async {
        guard !hasLoaded else { return }
        await reload(client: client)
    }

    func reload(client: EmbyClient) async {
        isLoading = true
        errorMessage = nil

        do {
            item = try await client.item(id: item.id)

            if item.isSeries {
                let loadedSeasons = try await client.seasons(seriesId: item.id)
                seasons = loadedSeasons
                if selectedSeasonId == nil || !loadedSeasons.contains(where: { $0.id == selectedSeasonId }) {
                    selectedSeasonId = loadedSeasons.first?.id
                }
                if let seasonId = selectedSeasonId {
                    episodes = try await client.episodes(seriesId: item.id, seasonId: seasonId)
                }
            }
            hasLoaded = true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh user data (played / favourite / resume position) without
    /// rebuilding the episode list.
    func refresh(client: EmbyClient) async {
        if let updated = try? await client.item(id: item.id) {
            item = updated
        }
        if !episodes.isEmpty, let seriesId = item.seriesId ?? (item.isSeries ? item.id : nil) {
            if let refreshed = try? await client.episodes(seriesId: seriesId, seasonId: selectedSeasonId) {
                episodes = refreshed
            }
        }
    }

    func selectSeason(_ season: ItemDto, client: EmbyClient) async {
        guard season.id != selectedSeasonId, let seriesId = item.isSeries ? item.id : item.seriesId else { return }
        selectedSeasonId = season.id
        episodes = []
        do {
            episodes = try await client.episodes(seriesId: seriesId, seasonId: season.id)
        } catch {
            errorMessage = "剧集列表加载失败，请重试。"
        }
    }

    /// The queue the player should start with.
    func playbackQueue(selected: ItemDto?) -> (items: [ItemDto], startIndex: Int) {
        guard item.isSeries, !episodes.isEmpty else {
            return ([item], 0)
        }

        if let selected = selected, let index = episodes.firstIndex(where: { $0.id == selected.id }) {
            return (Array(episodes[index...]), 0)
        }

        let firstUnwatched = episodes.firstIndex(where: { !$0.isPlayed }) ?? 0
        return (Array(episodes[firstUnwatched...]), 0)
    }
}

struct ItemDetailView: View {
    let item: ItemDto
    let client: EmbyClient

    @StateObject private var model: ItemDetailViewModel
    @State private var playbackRequest: PlaybackRequest?

    init(item: ItemDto, client: EmbyClient) {
        self.item = item
        self.client = client
        _model = StateObject(wrappedValue: ItemDetailViewModel(item: item))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    hero
                    actions

                    if model.item.isSeries {
                        episodeSection
                    }

                    overviewSection

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) {
                            Task { await model.reload(client: client) }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .navigationBarTitle(model.item.name, displayMode: .inline)
        .onAppear {
            Task { await model.loadIfNeeded(client: client) }
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerView(request: request)
        }
    }

    // MARK: - Sections

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(
                url: client.landscapeImageURL(for: model.item, maxWidth: 900),
                targetSize: CGSize(width: 390, height: 220)
            )
            .frame(height: 220)

            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.08), Color.black.opacity(0.92)]),
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 8) {
                if let logoURL = client.logoImageURL(for: model.item) {
                    RemoteImage(
                        url: logoURL,
                        targetSize: CGSize(width: 240, height: 90),
                        contentMode: .fit
                    )
                    .frame(height: 44)
                    .frame(maxWidth: 240, alignment: .leading)
                } else {
                    Text(model.item.name)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let year = model.item.productionYear {
                        MetaPill(text: String(year))
                    }
                    if let runtime = formatRuntime(model.item.duration) {
                        MetaPill(text: runtime)
                    }
                    if let rating = model.item.communityRating {
                        MetaPill(text: String(format: "%.1f", rating), icon: "star.fill")
                    }
                    if let official = model.item.officialRating, !official.isEmpty {
                        MetaPill(text: official)
                    }
                }

                if let genres = model.item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(16)
        }
        .frame(height: 220)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: { play(selected: nil) }) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(playButtonTitle)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Theme.accent)
                    .cornerRadius(10)
                }

                if model.item.isSeries, let next = model.episodes.first(where: { !$0.isPlayed }) {
                    Button(action: { play(selected: next) }) {
                        Text("下一集")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Theme.surfaceElevated)
                            .cornerRadius(10)
                    }
                }

                Spacer(minLength: 0)

                Button(action: togglePlayed) {
                    Image(systemName: model.item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundColor(model.item.isPlayed ? Theme.accent : .white)
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                }

                Button(action: toggleFavorite) {
                    Image(systemName: model.item.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18))
                        .foregroundColor(model.item.isFavorite ? Theme.accent : .white)
                        .frame(width: 40, height: 40)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)

            if let position = model.item.resumeSeconds, !model.item.isPlayed {
                VStack(alignment: .leading, spacing: 6) {
                    WatchProgressBar(value: model.item.watchedProgress, height: 4)
                    Text("上次看到 \(formatTimecode(position))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.seasons) { season in
                            Button(action: { selectSeason(season) }) {
                                Text(season.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(season.id == model.selectedSeasonId ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(season.id == model.selectedSeasonId ? Theme.accent : Theme.surfaceElevated)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            ForEach(model.episodes) { episode in
                Button(action: { play(selected: episode) }) {
                    EpisodeRow(item: episode, client: client)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            if model.episodes.isEmpty && model.isLoading {
                HStack {
                    Spacer(minLength: 0)
                    ProgressView()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
        if let overview = model.item.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(overview)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(model.isOverviewExpanded ? nil : 4)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.isOverviewExpanded.toggle()
                    }
                }) {
                    Text(model.isOverviewExpanded ? "收起" : "展开")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions

    private var playButtonTitle: String {
        if model.item.isPlayed { return "重新播放" }
        if model.item.resumeSeconds != nil { return "继续播放" }
        return "播放"
    }

    private func play(selected: ItemDto?) {
        let queue = model.playbackQueue(selected: selected)
        guard !queue.items.isEmpty else { return }
        playbackRequest = PlaybackRequest(items: queue.items, startIndex: queue.startIndex)
    }

    private func selectSeason(_ season: ItemDto) {
        Task { await model.selectSeason(season, client: client) }
    }

    private func togglePlayed() {
        let target = !model.item.isPlayed
        Task {
            try? await client.setPlayed(itemId: model.item.id, played: target)
            await model.refresh(client: client)
        }
    }

    private func toggleFavorite() {
        let target = !model.item.isFavorite
        Task {
            try? await client.setFavorite(itemId: model.item.id, favorite: target)
            await model.refresh(client: client)
        }
    }
}
