import Foundation

struct EmbyServer: Codable, Hashable, Identifiable {
    var name: String
    var baseURLString: String
    var version: String?

    var id: String { baseURLString }

    var url: URL? { URL(string: baseURLString) }
}

struct EmbyCredentials: Codable, Hashable, Identifiable {
    var server: EmbyServer
    var accessToken: String
    var userId: String
    var userName: String
    var deviceId: String

    /// 一个「服务器 + 用户」就是一份账号，用来做多账号切换。
    var id: String { "\(server.baseURLString)|\(userId)" }

    var displayName: String { "\(userName) @ \(server.name)" }
}
