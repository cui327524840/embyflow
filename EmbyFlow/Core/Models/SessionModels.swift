import Foundation

struct EmbyServer: Codable, Hashable, Identifiable {
    var name: String
    var baseURLString: String
    var version: String?

    var id: String { baseURLString }

    var url: URL? { URL(string: baseURLString) }
}

struct EmbyCredentials: Codable, Hashable {
    var server: EmbyServer
    var accessToken: String
    var userId: String
    var userName: String
    var deviceId: String
}
