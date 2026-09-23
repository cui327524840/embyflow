import Foundation
import UIKit

private struct AuthenticateRequest: Encodable {
    var username: String
    var password: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

/// All Emby traffic goes through here. Every method is main-actor isolated so
/// callers can mutate `ObservableObject` state without hopping threads, while
/// JSON decoding happens on a background executor inside `HTTPClient`.
@MainActor
final class EmbyClient {
    let credentials: EmbyCredentials
    private let http: HTTPClient

    static let clientName = "EmbyFlow"
    static let clientVersion = "1.0"

    private static let deviceIdKey = "embyflow.deviceId"

    /// Stable per-install device id: Emby uses it to keep playback sessions apart.
    static var deviceId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: deviceIdKey)
        return created
    }

    /// 必须是纯 ASCII：Emby 会把设备名写进它自己的数据库，
    /// 非 ASCII（例如「幽灵的 iPhone」）在部分服务器上会直接抛 SQLite 异常，
    /// 表现就是"同一个账号别的客户端能登、我们报服务器异常"。
    static var deviceDescription: String {
        let raw = UIDevice.current.name
        let ascii = String(raw.unicodeScalars.filter { $0.isASCII }.map(Character.init))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ascii.isEmpty { return "iPhone" }
        return String(ascii.prefix(40))
    }

    /// The fields we always ask Emby for. Requesting thumbnails of the parent
    /// item is what makes episode lists look right without extra round trips.
    static let itemFields = [
        "Overview", "Genres", "Taglines", "PrimaryImageAspectRatio", "ProductionYear",
        "CommunityRating", "OfficialRating", "ChildCount", "RecursiveItemCount",
        "MediaSources", "MediaStreams", "UserData", "RunTimeTicks",
        "ParentThumbItemId", "ParentThumbImageTag", "ParentBackdropItemId",
        "ParentBackdropImageTags", "SeriesPrimaryImageTag"
    ].joined(separator: ",")

    init(credentials: EmbyCredentials, http: HTTPClient = .shared) {
        self.credentials = credentials
        self.http = http
    }

    // MARK: - Static helpers (login screen)

    /// Accepts "192.168.1.10:8096", "emby.example.com/emby" … and returns a clean URL string.
    static func normalizeServerAddress(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return text
    }

    static func buildURL(base: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    static func clientAuthorization(deviceId: String) -> String {
        "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceDescription)\", "
            + "DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
    }

    static func probe(baseURLString: String) async throws -> EmbyServer {
        guard let base = URL(string: baseURLString) else { throw APIError.invalidURL }
        let url = try buildURL(base: base, path: "/System/Info/Public")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientAuthorization(deviceId: deviceId), forHTTPHeaderField: "X-Emby-Authorization")
        let (data, _) = try await HTTPClient.shared.data(for: request, session: HTTPClient.shared.api)
        let info = try await HTTPClient.shared.decode(PublicSystemInfo.self, from: data)
        let name = info.serverName ?? base.host ?? "Emby"
        return EmbyServer(name: name, baseURLString: baseURLString, version: info.version)
    }

    static func authenticate(server: EmbyServer, username: String, password: String) async throws -> EmbyCredentials {
        guard let base = server.url else { throw APIError.invalidURL }
        let url = try buildURL(base: base, path: "/Users/AuthenticateByName")
        let device = deviceId
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientAuthorization(deviceId: device), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONEncoder().encode(AuthenticateRequest(username: username, password: password))
        let (data, _) = try await HTTPClient.shared.data(for: request, session: HTTPClient.shared.api)
        let result = try await HTTPClient.shared.decode(AuthenticateResponse.self, from: data)
        return EmbyCredentials(
            server: server,
            accessToken: result.accessToken,
            userId: result.user.id,
            userName: result.user.name ?? username,
            deviceId: device
        )
    }

    // MARK: - Request plumbing

    private func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = credentials.server.url else { throw APIError.invalidURL }
        return try Self.buildURL(base: base, path: path, query: query)
    }

    private func makeRequest(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = method
        request.setValue(Self.clientAuthorization(deviceId: credentials.deviceId), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(Self.clientName)/\(Self.clientVersion)", forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        let request = try makeRequest(method, path: path, query: query, body: body)
        let (data, _) = try await http.data(for: request, session: http.api)
        return try await http.decode(T.self, from: data)
    }

    private func sendIgnoringResponse(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws {
        let request = try makeRequest(method, path: path, query: query, body: body)
        _ = try await http.data(for: request, session: http.api)
    }

    // MARK: - Browsing

    func userViews() async throws -> [ItemDto] {
        let result: ItemsQueryResult = try await send("GET", "/Users/\(credentials.userId)/Views")
        return result.items
    }

    func items(
        parentId: String? = nil,
        includeItemTypes: [String]? = nil,
        recursive: Bool = true,
        startIndex: Int = 0,
        limit: Int = 60,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        filters: [String]? = nil,
        searchTerm: String? = nil,
        isFolder: Bool? = nil
    ) async throws -> ItemsQueryResult {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo")
        ]
        if let parentId = parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let includeItemTypes = includeItemTypes, !includeItemTypes.isEmpty {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes.joined(separator: ",")))
        }
        if let filters = filters, !filters.isEmpty {
            query.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ",")))
        }
        if let searchTerm = searchTerm, !searchTerm.isEmpty {
            query.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }
        if let isFolder = isFolder {
            query.append(URLQueryItem(name: "IsFolder", value: isFolder ? "true" : "false"))
        }
        return try await send("GET", "/Users/\(credentials.userId)/Items", query: query)
    }

    func latest(parentId: String, limit: Int = 16) async throws -> [ItemDto] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo")
        ]
        return try await send("GET", "/Users/\(credentials.userId)/Items/Latest", query: query)
    }

    func resumeItems(limit: Int = 12) async throws -> [ItemDto] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo")
        ]
        let result: ItemsQueryResult = try await send("GET", "/Users/\(credentials.userId)/Items/Resume", query: query)
        return result.items
    }

    func nextUp(limit: Int = 12, seriesId: String? = nil) async throws -> [ItemDto] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: credentials.userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop")
        ]
        if let seriesId = seriesId { query.append(URLQueryItem(name: "SeriesId", value: seriesId)) }
        let result: ItemsQueryResult = try await send("GET", "/Shows/NextUp", query: query)
        return result.items
    }

    func item(id: String) async throws -> ItemDto {
        try await send(
            "GET",
            "/Users/\(credentials.userId)/Items/\(id)",
            query: [URLQueryItem(name: "Fields", value: Self.itemFields)]
        )
    }

    func seasons(seriesId: String) async throws -> [ItemDto] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: credentials.userId),
            URLQueryItem(name: "Fields", value: Self.itemFields)
        ]
        let result: ItemsQueryResult = try await send("GET", "/Shows/\(seriesId)/Seasons", query: query)
        return result.items
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [ItemDto] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: credentials.userId),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop")
        ]
        if let seasonId = seasonId { query.append(URLQueryItem(name: "SeasonId", value: seasonId)) }
        let result: ItemsQueryResult = try await send("GET", "/Shows/\(seriesId)/Episodes", query: query)
        return result.items.sorted {
            ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0)
        }
    }

    func search(term: String, limit: Int = 60) async throws -> [ItemDto] {
        let result = try await items(
            includeItemTypes: ["Movie", "Series", "Episode", "BoxSet", "Video"],
            recursive: true,
            startIndex: 0,
            limit: limit,
            sortBy: "SortName",
            searchTerm: term
        )
        return result.items
    }

    // MARK: - User data

    func setPlayed(itemId: String, played: Bool) async throws {
        let path = "/Users/\(credentials.userId)/PlayedItems/\(itemId)"
        try await sendIgnoringResponse(played ? "POST" : "DELETE", path)
    }

    func setFavorite(itemId: String, favorite: Bool) async throws {
        let path = "/Users/\(credentials.userId)/FavoriteItems/\(itemId)"
        try await sendIgnoringResponse(favorite ? "POST" : "DELETE", path)
    }

    // MARK: - Playback session

    func playbackInfo(
        itemId: String,
        startTimeTicks: Int64,
        audioStreamIndex: Int?,
        subtitleStreamIndex: Int?,
        preferences: PlaybackPreferences,
        mediaSourceId: String? = nil
    ) async throws -> PlaybackInfoResponse {
        let profile = DeviceProfile.make(preferences: preferences)
        // In the power saving modes we never let the server hand over the file:
        // it has to build a stream that the phone can hardware decode.
        let allowFileHandover = !preferences.forceTranscode
        let payload = PlaybackInfoRequest(
            userId: credentials.userId,
            startTimeTicks: max(0, startTimeTicks),
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            maxStreamingBitrate: preferences.effectiveBitrate,
            mediaSourceId: mediaSourceId,
            enableDirectPlay: allowFileHandover,
            enableDirectStream: true,
            enableTranscoding: true,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true,
            autoOpenLiveStream: true,
            deviceProfile: profile
        )
        let body = try JSONEncoder().encode(payload)
        let query = [URLQueryItem(name: "UserId", value: credentials.userId)]
        return try await send("POST", "/Items/\(itemId)/PlaybackInfo", query: query, body: body)
    }

    func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String?,
        positionTicks: Int64,
        playSessionId: String?,
        playMethod: String
    ) async throws {
        let payload = PlaybackProgressRequest(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            positionTicks: positionTicks,
            isPaused: false,
            isMuted: false,
            playMethod: playMethod,
            playSessionId: playSessionId,
            canSeek: true
        )
        try await sendIgnoringResponse("POST", "/Sessions/Playing", body: try JSONEncoder().encode(payload))
    }

    func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String?,
        positionTicks: Int64,
        isPaused: Bool,
        playSessionId: String?,
        playMethod: String
    ) async throws {
        let payload = PlaybackProgressRequest(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            positionTicks: positionTicks,
            isPaused: isPaused,
            isMuted: false,
            playMethod: playMethod,
            playSessionId: playSessionId,
            canSeek: true
        )
        try await sendIgnoringResponse("POST", "/Sessions/Playing/Progress", body: try JSONEncoder().encode(payload))
    }

    func reportPlaybackStopped(
        itemId: String,
        mediaSourceId: String?,
        positionTicks: Int64,
        playSessionId: String?,
        playMethod: String
    ) async throws {
        let payload = PlaybackProgressRequest(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            positionTicks: positionTicks,
            isPaused: true,
            isMuted: false,
            playMethod: playMethod,
            playSessionId: playSessionId,
            canSeek: true
        )
        try await sendIgnoringResponse("POST", "/Sessions/Playing/Stopped", body: try JSONEncoder().encode(payload))
    }

    // MARK: - Images & subtitles

    func imageURL(itemId: String, type: String, tag: String?, maxWidth: Int?, quality: Int = 88) -> URL? {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "quality", value: String(quality)),
            URLQueryItem(name: "api_key", value: credentials.accessToken)
        ]
        if let maxWidth = maxWidth { query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let tag = tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        return try? makeURL(path: "/Items/\(itemId)/Images/\(type)", query: query)
    }

    /// Poster (2:3). Falls back to the parent thumbnail for episodes without art.
    func posterImageURL(for item: ItemDto, maxWidth: Int) -> URL? {
        if let tag = item.imageTags?["Primary"] {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: maxWidth)
        }
        if let parentId = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(itemId: parentId, type: "Thumb", tag: tag, maxWidth: maxWidth)
        }
        if let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemId: seriesId, type: "Primary", tag: tag, maxWidth: maxWidth)
        }
        return nil
    }

    /// Landscape art (16:9) used by rows, episode lists and the player.
    func landscapeImageURL(for item: ItemDto, maxWidth: Int) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.imageTags?["Thumb"] {
            return imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: maxWidth)
        }
        if let parentId = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parentId, type: "Backdrop", tag: tag, maxWidth: maxWidth)
        }
        if let tag = item.imageTags?["Primary"] {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: maxWidth)
        }
        return posterImageURL(for: item, maxWidth: maxWidth)
    }

    func logoImageURL(for item: ItemDto, maxWidth: Int = 400) -> URL? {
        guard let tag = item.imageTags?["Logo"] else { return nil }
        return imageURL(itemId: item.id, type: "Logo", tag: tag, maxWidth: maxWidth)
    }

    func subtitleStreamURL(itemId: String, mediaSourceId: String, index: Int, format: String) -> URL? {
        let query = [URLQueryItem(name: "api_key", value: credentials.accessToken)]
        return try? makeURL(
            path: "/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/Stream.\(format)",
            query: query
        )
    }
}
