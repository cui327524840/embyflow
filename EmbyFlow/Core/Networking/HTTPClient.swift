import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case http(status: Int, message: String?)
    case decoding(String)
    case transport(String)
    case cancelled
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效，请检查后重试。"
        case .unauthorized:
            return "登录已失效，请重新登录。"
        case .http(let status, let message):
            if let message = message, !message.isEmpty { return message }
            return "服务器返回错误（HTTP \(status)）。"
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .transport(let detail):
            return detail
        case .cancelled:
            return "已取消请求。"
        case .notConfigured:
            return "尚未连接到 Emby 服务器。"
        }
    }
}

extension URLSession {
    /// `URLSession.data(for:)` is iOS 15+, so wrap the classic completion API
    /// with a continuation to keep async/await usable on iOS 14.5.
    func embyData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

/// Two sessions: a small-payload API session and a separate image session.
/// Keeping them apart stops poster downloads from queueing behind JSON calls.
final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    let api: URLSession
    let images: URLSession

    private init() {
        let apiConfig = URLSessionConfiguration.default
        apiConfig.timeoutIntervalForRequest = 20
        apiConfig.timeoutIntervalForResource = 60
        apiConfig.httpMaximumConnectionsPerHost = 6
        apiConfig.waitsForConnectivity = true
        apiConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        apiConfig.urlCache = nil
        api = URLSession(configuration: apiConfig)

        let imageConfig = URLSessionConfiguration.default
        imageConfig.timeoutIntervalForRequest = 20
        imageConfig.timeoutIntervalForResource = 60
        imageConfig.httpMaximumConnectionsPerHost = 8
        imageConfig.requestCachePolicy = .returnCacheDataElseLoad
        imageConfig.urlCache = nil
        images = URLSession(configuration: imageConfig)
    }

    func data(for request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.embyData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("服务器响应无效。")
            }
            switch http.statusCode {
            case 200..<300:
                return (data, http)
            case 401, 403:
                throw APIError.unauthorized
            default:
                throw APIError.http(status: http.statusCode, message: Self.errorMessage(from: data))
            }
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(T.self, from: data)
            }.value
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func imageData(from url: URL) async throws -> Data {
        let (data, _) = try await data(for: URLRequest(url: url), session: images)
        return data
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["Message"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 300 else { return nil }
        return trimmed
    }
}
