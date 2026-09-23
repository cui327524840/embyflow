import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var query = ""
    @State private var results: [ItemDto] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var navigationItem: ItemDto?
    @State private var isNavigating = false

    var body: some View {
        NavigationView {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchField

                    if let client = session.client {
                        resultsView(for: client)
                    } else {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "未连接服务器")
                    }
                }
            }
            .navigationBarTitle("搜索", displayMode: .large)
            .background(programmaticLink)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private var programmaticLink: some View {
        if let item = navigationItem, let client = session.client {
            HiddenNavigationLink(item: item, client: client, isActive: $isNavigating)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.secondaryText)

            TextField("搜索电影、剧集", text: $query)
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: query) { newValue in
                    scheduleSearch(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.tertiaryText)
                }
            } else if isSearching {
                ProgressView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .cornerRadius(11)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func resultsView(for client: EmbyClient) -> some View {
        if let error = errorMessage {
            ErrorBanner(message: error, onRetry: nil)
        }

        if results.isEmpty {
            if query.count < 2 {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "输入关键词开始搜索",
                    message: "至少输入 2 个字符。"
                )
            } else if !isSearching {
                EmptyStateView(icon: "questionmark.circle", title: "没有找到匹配的内容")
            }
        } else {
            PosterGrid(
                items: PosterGrid.makeItems(from: results, client: client, style: .poster),
                style: .poster,
                axis: .vertical,
                onSelect: { id in
                    guard let tapped = results.first(where: { $0.id == id }) else { return }
                    navigationItem = tapped
                    isNavigating = true
                }
            )
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()

        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        guard let client = session.client else { return }

        isSearching = true
        searchTask = Task {
            // 300ms debounce keeps the server from being hit per keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let found = try await client.search(term: term)
                guard !Task.isCancelled else { return }
                self.results = found
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "搜索失败，请重试。"
            }
            self.isSearching = false
        }
    }
}
