import SwiftUI

struct HomeSection: Identifiable {
    let id: String
    let title: String
    let items: [ItemDto]
    let style: PosterGrid.Style
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var sections: [HomeSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var hasLoaded = false

    init() {}

    func loadIfNeeded(client: EmbyClient) async {
        guard !hasLoaded else { return }
        await reload(client: client)
    }

    func reload(client: EmbyClient) async {
        isLoading = true
        errorMessage = nil

        var collected: [HomeSection] = []
        do {
            let resume = (try? await client.resumeItems(limit: 12)) ?? []
            if !resume.isEmpty {
                collected.append(HomeSection(id: "resume", title: "继续观看", items: resume, style: .landscape))
            }

            let nextUp = (try? await client.nextUp(limit: 12)) ?? []
            if !nextUp.isEmpty {
                collected.append(HomeSection(id: "nextup", title: "接下来", items: nextUp, style: .landscape))
            }

            let views = try await client.userViews()
            for view in views.prefix(6) {
                let latest = (try? await client.latest(parentId: view.id, limit: 14)) ?? []
                if !latest.isEmpty {
                    collected.append(
                        HomeSection(id: "latest-\(view.id)", title: view.name, items: latest, style: .poster)
                    )
                }
            }

            sections = collected
            hasLoaded = true
            if collected.isEmpty {
                errorMessage = "这个服务器上还没有可展示的媒体。"
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model = HomeViewModel()

    @State private var navigationItem: ItemDto?
    @State private var isNavigating = false
    @State private var showAddAccount = false

    var body: some View {
        NavigationView {
            ZStack {
                Theme.background.ignoresSafeArea()

                if let client = session.client {
                    content(client: client)
                } else {
                    EmptyStateView(icon: "wifi.exclamationmark", title: "未连接服务器")
                }
            }
            .navigationBarTitle("首页", displayMode: .large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    accountMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .background(programmaticLink)
            .sheet(isPresented: $showAddAccount) {
                LoginView(isAddingAccount: true, onFinish: { showAddAccount = false })
                    .environmentObject(session)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    /// 左上角账号切换：多服务器 / 多用户一键切。
    private var accountMenu: some View {
        Menu {
            Section(header: Text("切换账号")) {
                ForEach(session.accounts) { account in
                    Button(action: { session.switchTo(id: account.id) }) {
                        if account.id == session.activeAccountID {
                            Label(account.displayName, systemImage: "checkmark.circle.fill")
                        } else {
                            Text(account.displayName)
                        }
                    }
                }
            }
            Button(action: { showAddAccount = true }) {
                Label("添加账号", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 15))
                Text(session.activeAccount?.server.name ?? "账号")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
    }

    @ViewBuilder
    private var programmaticLink: some View {
        if let item = navigationItem, let client = session.client {
            HiddenNavigationLink(item: item, client: client, isActive: $isNavigating)
        }
    }

    private func content(client: EmbyClient) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let featured = model.sections.first?.items.first {
                    NavigationLink(destination: mediaDestination(for: featured, client: client)) {
                        FeaturedBanner(item: featured, client: client)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                ForEach(model.sections) { section in
                    carousel(section: section, client: client)
                }

                if model.isLoading && model.sections.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        ProgressView()
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 60)
                }

                if let error = model.errorMessage, model.sections.isEmpty {
                    ErrorBanner(message: error) {
                        Task { await model.reload(client: client) }
                    }
                }
            }
            .padding(.vertical, 14)
        }
        .onAppear {
            Task { await model.loadIfNeeded(client: client) }
        }
    }

    private func carousel(section: HomeSection, client: EmbyClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: section.title, subtitle: "\(section.items.count) 个")

            PosterGrid(
                items: PosterGrid.makeItems(from: section.items, client: client, style: section.style),
                style: section.style,
                axis: .horizontal,
                onSelect: { id in
                    guard let tapped = section.items.first(where: { $0.id == id }) else { return }
                    navigationItem = tapped
                    isNavigating = true
                }
            )
            .frame(height: PosterGrid.rowHeight(style: section.style, itemWidth: itemWidth(for: section.style)))
        }
    }

    private func itemWidth(for style: PosterGrid.Style) -> CGFloat {
        style == .poster ? PosterGrid.posterItemWidth : PosterGrid.landscapeItemWidth
    }

    private func refresh() {
        guard let client = session.client else { return }
        Task { await model.reload(client: client) }
    }
}
