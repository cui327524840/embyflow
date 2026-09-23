import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        Group {
            if session.isAuthenticated {
                // 切换账号时整棵树重建，避免残留上一个账号的列表与缓存。
                MainTabView()
                    .id(session.activeAccountID ?? "guest")
            } else {
                LoginView()
            }
        }
        .onAppear { session.restoreSession() }
    }
}

struct MainTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            LibraryListView()
                .tabItem { Label("媒体库", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .accentColor(Theme.accent)
    }
}
