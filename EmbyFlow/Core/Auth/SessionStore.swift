import Combine
import Foundation

private let recentServersDefaultsKey = "embyflow.recentServers"

private func loadStoredServers() -> [EmbyServer] {
    guard let data = UserDefaults.standard.data(forKey: recentServersDefaultsKey),
          let servers = try? JSONDecoder().decode([EmbyServer].self, from: data) else {
        return []
    }
    return servers
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var credentials: EmbyCredentials?
    @Published private(set) var isConnecting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentServers: [EmbyServer] = []

    private(set) var client: EmbyClient?

    var isAuthenticated: Bool { client != nil }

    init() {
        recentServers = loadStoredServers()
    }

    func restoreSession() {
        guard client == nil, let saved = KeychainStore.load() else { return }
        credentials = saved
        client = EmbyClient(credentials: saved)
        remember(server: saved.server)
    }

    func login(address: String, username: String, password: String) async {
        guard let normalized = EmbyClient.normalizeServerAddress(address) else {
            errorMessage = APIError.invalidURL.errorDescription
            return
        }
        guard !username.isEmpty else {
            errorMessage = "请输入用户名。"
            return
        }

        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            // A failed probe is not fatal: some servers hide the public endpoint.
            let server: EmbyServer
            do {
                server = try await EmbyClient.probe(baseURLString: normalized)
            } catch {
                let host = URL(string: normalized)?.host ?? normalized
                server = EmbyServer(name: host, baseURLString: normalized, version: nil)
            }

            let newCredentials = try await EmbyClient.authenticate(server: server, username: username, password: password)
            KeychainStore.save(newCredentials)
            credentials = newCredentials
            client = EmbyClient(credentials: newCredentials)
            remember(server: server)
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.delete()
        credentials = nil
        client = nil
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Recent servers

    private func remember(server: EmbyServer) {
        var servers = recentServers.filter { $0.baseURLString != server.baseURLString }
        servers.insert(server, at: 0)
        recentServers = Array(servers.prefix(6))
        if let data = try? JSONEncoder().encode(recentServers) {
            UserDefaults.standard.set(data, forKey: recentServersDefaultsKey)
        }
    }
}
