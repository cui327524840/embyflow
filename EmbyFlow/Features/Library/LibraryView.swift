import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    enum SortOption: String, CaseIterable, Identifiable {
        case name = "名称"
        case dateAdded = "最近添加"
        case rating = "评分"
        case year = "年份"

        var id: String { rawValue }

        var apiValue: String {
            switch self {
            case .name: return "SortName"
            case .dateAdded: return "DateCreated"
            case .rating: return "CommunityRating"
            case .year: return "ProductionYear"
            }
        }

        var apiSortOrder: String {
            switch self {
            case .name, .year: return "Ascending"
            case .dateAdded, .rating: return "Descending"
            }
        }
    }

    enum FilterOption: String, CaseIterable, Identifiable {
        case all = "全部"
        case unwatched = "未观看"
        case played = "已观看"

        var id: String { rawValue }

        var apiFilters: [String]? {
            switch self {
            case .all: return nil
            case .unwatched: return ["IsUnplayed"]
            case .played: return ["IsPlayed"]
            }
        }
    }

    @Published private(set) var items: [ItemDto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published var sort: SortOption = .name
    @Published var filter: FilterOption = .all

    let item: ItemDto

    private let pageSize = 60
    private var totalCount = 0
    private var startIndex = 0
    private var hasLoaded = false

    init(item: ItemDto) {
        self.item = item
    }

    var hasMore: Bool { items.count < totalCount }

    func loadIfNeeded(client: EmbyClient) async {
        guard !hasLoaded else { return }
        await reload(client: client)
    }

    func reload(client: EmbyClient) async {
        isLoading = true
        errorMessage = nil
        startIndex = 0

        do {
            let result = try await fetch(client: client, startIndex: 0)
            items = result.items
            totalCount = result.totalRecordCount
            startIndex = result.items.count
            hasLoaded = true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Called when the grid is close to its end.
    func loadMore(client: EmbyClient) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }

        isLoadingMore = true
        do {
            let result = try await fetch(client: client, startIndex: startIndex)
            let existingIds = Set(items.map { $0.id })
            let fresh = result.items.filter { !existingIds.contains($0.id) }
            items.append(contentsOf: fresh)
            startIndex += result.items.count
            // An empty page means the server has nothing more to give.
            totalCount = fresh.isEmpty ? items.count : result.totalRecordCount
        } catch {
            // Pagination failures stay silent; the grid simply stops growing.
        }
        isLoadingMore = false
    }

    private func fetch(client: EmbyClient, startIndex: Int) async throws -> ItemsQueryResult {
        try await client.items(
            parentId: item.id,
            includeItemTypes: includeTypes,
            recursive: isRecursive,
            startIndex: startIndex,
            limit: pageSize,
            sortBy: sort.apiValue,
            sortOrder: sort.apiSortOrder,
            filters: filter.apiFilters
        )
    }

    private var isRecursive: Bool {
        switch item.type ?? "" {
        case "CollectionFolder", "UserView", "AggregateFolder": return true
        default: return false
        }
    }

    private var includeTypes: [String]? {
        isRecursive || item.type == "BoxSet"
            ? nil
            : ["Movie", "Series", "Episode", "Video", "Folder", "BoxSet", "Season"]
    }
}

struct LibraryView: View {
    let item: ItemDto
    let client: EmbyClient

    @StateObject private var model: LibraryViewModel
    @State private var navigationItem: ItemDto?
    @State private var isNavigating = false

    init(item: ItemDto, client: EmbyClient) {
        self.item = item
        self.client = client
        _model = StateObject(wrappedValue: LibraryViewModel(item: item))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationBarTitle(item.name, displayMode: .inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                sortMenu
                filterMenu
            }
        }
        .background(programmaticLink)
        .onAppear {
            Task { await model.loadIfNeeded(client: client) }
        }
    }

    @ViewBuilder
    private var programmaticLink: some View {
        if let media = navigationItem {
            HiddenNavigationLink(item: media, client: client, isActive: $isNavigating)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty && model.isLoading {
            ProgressView()
                .padding(.vertical, 60)
        } else if model.items.isEmpty, let error = model.errorMessage {
            ErrorBanner(message: error) {
                Task { await model.reload(client: client) }
            }
        } else if model.items.isEmpty {
            EmptyStateView(icon: "tray", title: "这里还没有内容")
        } else {
            PosterGrid(
                items: PosterGrid.makeItems(from: model.items, client: client, style: .poster),
                style: .poster,
                axis: .vertical,
                onSelect: { id in
                    guard let tapped = model.items.first(where: { $0.id == id }) else { return }
                    navigationItem = tapped
                    isNavigating = true
                },
                onReachEnd: {
                    Task { await model.loadMore(client: client) }
                }
            )
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibraryViewModel.SortOption.allCases) { option in
                Button(action: { changeSort(option) }) {
                    if option == model.sort {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(LibraryViewModel.FilterOption.allCases) { option in
                Button(action: { changeFilter(option) }) {
                    if option == model.filter {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "line.horizontal.3.decrease.circle")
        }
    }

    private func changeSort(_ option: LibraryViewModel.SortOption) {
        guard option != model.sort else { return }
        model.sort = option
        Task { await model.reload(client: client) }
    }

    private func changeFilter(_ option: LibraryViewModel.FilterOption) {
        guard option != model.filter else { return }
        model.filter = option
        Task { await model.reload(client: client) }
    }
}
