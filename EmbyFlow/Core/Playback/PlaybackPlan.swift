import Foundation

enum PlaybackMethod: String {
    case directPlay
    case directStream
    case transcode

    /// Value Emby expects when reporting a playback session.
    var apiValue: String {
        switch self {
        case .directPlay: return "DirectPlay"
        case .directStream: return "DirectStream"
        case .transcode: return "Transcode"
        }
    }

    var displayName: String {
        switch self {
        case .directPlay: return "原画直连"
        case .directStream: return "直接串流（不转码）"
        case .transcode: return "服务端转码"
        }
    }
}

/// Chooses the best URL for the current device: untouched original file when
/// AVFoundation can play it, otherwise the server's HLS stream.
struct PlaybackPlan {
    let url: URL
    let method: PlaybackMethod

    static func make(item: ItemDto, source: MediaSourceInfo, credentials: EmbyCredentials) throws -> PlaybackPlan {
        if source.supportsDirectPlay == true,
           let raw = source.directStreamUrl,
           let url = resolve(raw, credentials: credentials) {
            return PlaybackPlan(url: url, method: .directPlay)
        }

        if let raw = source.transcodingUrl, let url = resolve(raw, credentials: credentials) {
            let method: PlaybackMethod = source.supportsDirectStream == true ? .directStream : .transcode
            return PlaybackPlan(url: url, method: method)
        }

        if let raw = source.directStreamUrl, let url = resolve(raw, credentials: credentials) {
            return PlaybackPlan(url: url, method: .directStream)
        }

        throw APIError.transport("服务端没有返回可用的播放地址，请检查该媒体的转码设置。")
    }

    private static func resolve(_ raw: String, credentials: EmbyCredentials) -> URL? {
        let lowercased = raw.lowercased()
        var resolved: URL?

        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            resolved = URL(string: raw)
        } else if let baseURL = credentials.server.url,
                  var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            var basePath = components.path
            if basePath.hasSuffix("/") { basePath.removeLast() }
            let path = raw.hasPrefix("/") ? raw : "/" + raw

            if let queryIndex = path.firstIndex(of: "?") {
                let pathOnly = String(path[path.startIndex..<queryIndex])
                let queryPart = String(path[path.index(after: queryIndex)...])
                components.path = basePath + pathOnly
                components.percentEncodedQuery = queryPart
            } else {
                components.path = basePath + path
            }
            resolved = components.url
        }

        guard let url = resolved else { return nil }
        return appendingAPIKey(url, token: credentials.accessToken)
    }

    private static func appendingAPIKey(_ url: URL, token: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        let hasToken = items.contains {
            let name = $0.name.lowercased()
            return name == "api_key" || name == "x-emby-token"
        }
        if !hasToken {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = items
        return components.url ?? url
    }
}
