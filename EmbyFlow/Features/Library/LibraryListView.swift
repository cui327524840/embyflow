import SwiftUI

struct LibraryListView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var views: [ItemDto] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 340), spacing: 14, alignment: .top)]

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
            .navigationBarTitle("媒体库", displayMode: .large)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func content(client: EmbyClient) -> some View {
        ScrollView {
            if views.isEmpty && isLoading {
                ProgressView()
                    .padding(.vertical, 60)
            } else if views.isEmpty, let error = errorMessage {
                ErrorBanner(message: error) {
                    Task { await load(client: client) }
                }
            } else if views.isEmpty {
                EmptyStateView(icon: "tray", title: "没有可用的媒体库", message: "请在 Emby 服务器上添加媒体库。")
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(views) { view in
                        NavigationLink(destination: LibraryView(item: view, client: client)) {
                            LibraryTile(item: view, client: client)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            Task { await load(client: client) }
        }
    }

    private func load(client: EmbyClient) async {
        guard views.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            views = try await client.userViews()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
