import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var settings: AppSettings

    @State private var cacheSizeText = "计算中…"
    @State private var showLogoutConfirm = false
    @State private var showAddAccount = false

    private let bitrateOptions: [(title: String, value: Int)] = [
        ("自动（不限制）", 0),
        ("4 Mbps", 4_000_000),
        ("8 Mbps", 8_000_000),
        ("12 Mbps", 12_000_000),
        ("20 Mbps", 20_000_000),
        ("40 Mbps", 40_000_000)
    ]

    private let languageOptions: [(title: String, value: String)] = [
        ("中文", "zh"),
        ("英文", "en"),
        ("日文", "ja"),
        ("韩文", "ko"),
        ("跟随服务器默认", ""),
        ("关闭字幕", "__off__")
    ]

    var body: some View {
        NavigationView {
            List {
                playbackModeSection
                playbackSection
                accountsSection
                serverSection
                cacheSection
                aboutSection
                logoutSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationBarTitle("设置", displayMode: .large)
            .onAppear(perform: refreshCacheSize)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showAddAccount) {
            LoginView(isAddingAccount: true, onFinish: { showAddAccount = false })
                .environmentObject(session)
        }
        .alert(isPresented: $showLogoutConfirm) {
            Alert(
                title: Text("退出登录"),
                message: Text("将清除本机保存的登录凭据。"),
                primaryButton: .destructive(Text("退出")) { session.logout() },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var accountsSection: some View {
        Section(
            header: Text("账号"),
            footer: Text("可以保存多个服务器 / 用户，点一下即可切换；左滑删除。")
        ) {
            ForEach(session.accounts) { account in
                Button(action: { session.switchTo(id: account.id) }) {
                    HStack(spacing: 10) {
                        Image(systemName: account.id == session.activeAccountID ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundColor(account.id == session.activeAccountID ? Theme.accent : Theme.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.userName)
                                .foregroundColor(.white)
                            Text(account.server.baseURLString)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .onDelete(perform: deleteAccounts)

            Button(action: { showAddAccount = true }) {
                Label("添加账号", systemImage: "plus.circle")
            }
        }
    }

    private func deleteAccounts(_ offsets: IndexSet) {
        for index in offsets where session.accounts.indices.contains(index) {
            session.remove(id: session.accounts[index].id)
        }
    }

    // MARK: - Sections

    private var playbackModeSection: some View {
        Section(header: Text("播放模式"), footer: Text(settings.playbackMode.detail)) {
            Picker(
                "模式",
                selection: Binding(
                    get: { settings.playbackMode },
                    set: { settings.updatePlaybackMode($0) }
                )
            ) {
                ForEach(PlaybackMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.accent)
                    .frame(width: 22)
                Text("本机解码")
                Spacer(minLength: 12)
                Text(settings.deviceCapabilities.decodeClass.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            infoRow(icon: "iphone", title: "机型标识", value: settings.deviceCapabilities.machine)
        }
    }

    private var playbackSection: some View {
        Section(header: Text("播放")) {
            Picker(
                "最大码率",
                selection: Binding(
                    get: { settings.maxStreamingBitrate },
                    set: { settings.updateMaxStreamingBitrate($0) }
                )
            ) {
                ForEach(bitrateOptions, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }

            Picker(
                "首选字幕",
                selection: Binding(
                    get: { settings.subtitleLanguage },
                    set: { settings.updateSubtitleLanguage($0) }
                )
            ) {
                ForEach(languageOptions, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }

            Toggle(
                "自动选择字幕",
                isOn: Binding(
                    get: { settings.autoSelectSubtitles },
                    set: { settings.updateAutoSelectSubtitles($0) }
                )
            )

            Toggle(
                "自动播放下一集",
                isOn: Binding(
                    get: { settings.autoPlayNext },
                    set: { settings.updateAutoPlayNext($0) }
                )
            )
        }
    }

    private var serverSection: some View {
        Section(header: Text("服务器")) {
            if let credentials = session.activeAccount {
                infoRow(icon: "server.rack", title: "名称", value: credentials.server.name)
                infoRow(icon: "link", title: "地址", value: credentials.server.baseURLString)
                infoRow(icon: "person", title: "用户", value: credentials.userName)
                if let version = credentials.server.version {
                    infoRow(icon: "number", title: "版本", value: version)
                }
            } else {
                Text("未连接").foregroundColor(Theme.secondaryText)
            }
        }
    }

    private var cacheSection: some View {
        Section(
            header: Text("缓存"),
            footer: Text("海报与缩略图缓存在本机，滚动时不重复下载。低内存机型会自动使用更小的缓存。")
        ) {
            infoRow(icon: "internaldrive", title: "图片缓存", value: cacheSizeText)
            Button("清除图片缓存", action: clearCache)
        }
    }

    private var aboutSection: some View {
        Section(header: Text("关于")) {
            infoRow(icon: "play.rectangle", title: "客户端", value: "EmbyFlow for iOS")
            infoRow(icon: "number", title: "版本", value: "1.0")
            infoRow(icon: "film", title: "播放内核", value: "AVFoundation")
        }
    }

    private var logoutSection: some View {
        Section {
            Button("退出登录") { showLogoutConfirm = true }
                .foregroundColor(.red)
        }
    }

    // MARK: - Helpers

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Theme.accent)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func refreshCacheSize() {
        Task {
            let bytes = await ImagePipeline.shared.diskSize()
            cacheSizeText = formatFileSize(bytes) ?? "0 KB"
        }
    }

    private func clearCache() {
        Task {
            await ImagePipeline.shared.clear()
            refreshCacheSize()
        }
    }
}
