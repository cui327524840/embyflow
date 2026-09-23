import Foundation
import Security

/// 账号凭据（可多份）存在 Keychain，从不写 UserDefaults。
///
/// 存储格式是 `[EmbyCredentials]`；如果读到的是老版本写入的单个对象，
/// 会自动当成「只有一份账号」，无需额外迁移步骤。
enum KeychainStore {
    private static let service = "com.embyflow.app.session"
    private static let account = "current"

    // MARK: - 多账号

    static func saveAccounts(_ accounts: [EmbyCredentials]) {
        guard !accounts.isEmpty else {
            delete()
            return
        }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        write(data)
    }

    static func loadAccounts() -> [EmbyCredentials] {
        guard let data = read() else { return [] }
        if let accounts = try? JSONDecoder().decode([EmbyCredentials].self, from: data) {
            return accounts
        }
        // 老版本存的是单个对象
        if let single = try? JSONDecoder().decode(EmbyCredentials.self, from: data) {
            return [single]
        }
        return []
    }

    // MARK: - 兼容旧接口

    static func save(_ credentials: EmbyCredentials) {
        var accounts = loadAccounts()
        if let index = accounts.firstIndex(where: { $0.id == credentials.id }) {
            accounts[index] = credentials
        } else {
            accounts.append(credentials)
        }
        saveAccounts(accounts)
    }

    static func load() -> EmbyCredentials? {
        loadAccounts().first
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain 细节

    private static func write(_ data: Data) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
