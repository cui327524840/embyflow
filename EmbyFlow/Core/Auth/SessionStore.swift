import Combine
import Foundation

private let recentServersDefaultsKey = "embyflow.recentServers"
private let activeAccountDefaultsKey = "embyflow.activeAccountID"

private func loadStoredServers() -> [EmbyServer] {
    guard let data = UserDefaults.standard.data(forKey: recentServersDefaultsKey),
          let servers = try? JSONDecoder().decode([EmbyServer].self, from: data) else {
        return []
    }
    return servers
}

/// 多账号：可以保存任意多个「服务器 + 用户」，随时切换。
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var accounts: [EmbyCredentials] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentServers: [EmbyServer] = []

    private(set) var client: EmbyClient?

    var isAuthenticated: Bool { client != nil }

    var activeAccount: EmbyCredentials? {
        guard let activeAccountID = activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    init() {
        recentServers = loadStoredServers()
    }

    // MARK: - 恢复 / 切换

    func restoreSession() {
        guard client == nil else { return }
        let stored = KeychainStore.loadAccounts()
        guard !stored.isEmpty else { return }
        accounts = stored
        let savedID = UserDefaults.standard.string(forKey: activeAccountDefaultsKey)
        let active = stored.first { $0.id == savedID } ?? stored[0]
        activate(active)
    }

    func switchTo(id: String) {
        guard id != activeAccountID, let account = accounts.first(where: { $0.id == id }) else { return }
        activate(account)
    }

    func remove(id: String) {
        accounts.removeAll { $0.id == id }
        KeychainStore.saveAccounts(accounts)
        guard activeAccountID == id else { return }

        client = nil
        activeAccountID = nil
        UserDefaults.standard.removeObject(forKey: activeAccountDefaultsKey)
        if let next = accounts.first {
            activate(next)
        }
    }

    /// 退出登录 = 移除当前账号（其他账号保留）。
    func logout() {
        guard let activeAccountID = activeAccountID else {
            client = nil
            accounts = []
            KeychainStore.delete()
            return
        }
        remove(id: activeAccountID)
    }

    // MARK: - 登录 / 添加账号

    @discardableResult
    func login(address: String, username: String, password: String) async -> Bool {
        guard let normalized = EmbyClient.normalizeServerAddress(address) else {
            errorMessage = APIError.invalidURL.errorDescription
            return false
        }
        guard !username.isEmpty else {
            errorMessage = "请输入用户名。"
            return false
        }

        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            // 探活失败不代表不能登录（有些服务器隐藏了公开接口）。
            let server: EmbyServer
            do {
                server = try await EmbyClient.probe(baseURLString: normalized)
            } catch {
                let host = URL(string: normalized)?.host ?? normalized
                server = EmbyServer(name: host, baseURLString: normalized, version: nil)
            }

            let credentials = try await EmbyClient.authenticate(server: server, username: username, password: password)
            upsert(credentials)
            if let stored = accounts.first(where: { $0.id == credentials.id }) {
                activate(stored)
            } else {
                activate(credentials)
            }
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - 内部

    private func upsert(_ credentials: EmbyCredentials) {
        if let index = accounts.firstIndex(where: { $0.id == credentials.id }) {
            accounts[index] = credentials
        } else {
            accounts.append(credentials)
        }
        KeychainStore.saveAccounts(accounts)
    }

    private func activate(_ account: EmbyCredentials) {
        activeAccountID = account.id
        client = EmbyClient(credentials: account)
        UserDefaults.standard.set(account.id, forKey: activeAccountDefaultsKey)
        remember(server: account.server)
    }

    private func remember(server: EmbyServer) {
        var servers = recentServers.filter { $0.baseURLString != server.baseURLString }
        servers.insert(server, at: 0)
        recentServers = Array(servers.prefix(6))
        if let data = try? JSONEncoder().encode(recentServers) {
            UserDefaults.standard.set(data, forKey: recentServersDefaultsKey)
        }
    }
}
