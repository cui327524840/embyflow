import AVFoundation
import Foundation

/// AVFoundation 用自己的网络栈，**不认自签名/证书链不完整的证书**：
/// 表现就是「登录能进、点播放进度条一直不动」。
///
/// 这里把播放请求接管过来：URL 换成自定义 scheme → AVFoundation 把请求交给我们 →
/// 我们用已经信任服务器证书的 URLSession 去取数据，再回填给播放器。
/// HLS 的主播放列表、子列表、分片都会走这条通道，所以转码流一样有效。
final class TrustedResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "embytrusted"

    private let session: URLSession
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()

    init(session: URLSession = HTTPClient.shared.images) {
        self.session = session
        super.init()
    }

    /// 只有 https 需要接管；http 直连不涉及证书。
    static func trustedURL(from url: URL) -> URL {
        guard url.scheme?.lowercased() == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = scheme
        return components.url ?? url
    }

    static func originalURL(from url: URL) -> URL {
        guard url.scheme == scheme,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    func cancelAll() {
        lock.lock()
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requested = loadingRequest.request.url else { return false }
        let target = Self.originalURL(from: requested)
        var request = URLRequest(url: target)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            let end = start + Int64(max(0, dataRequest.requestedLength - 1))
            if dataRequest.requestsAllDataToEndOfResource == false && end > 0 {
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.removeTask(key)

            if let error = error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }

            if let info = loadingRequest.contentInformationRequest {
                // 播放列表要保留服务器给的真实 MIME（HLS 是 application/vnd.apple.mpegurl），
                // 统一写成 video/mp4 会让 AVFoundation 把播放列表当媒体解析而失败。
                info.contentType = http.mimeType ?? "video/mp4"
                info.isByteRangeAccessSupported = true
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = range.split(separator: "/").last,
                   let length = Int64(total) {
                    info.contentLength = length
                } else {
                    info.contentLength = http.expectedContentLength
                }
            }

            if let dataRequest = loadingRequest.dataRequest, let data = data {
                dataRequest.respond(with: data)
            }
            loadingRequest.finishLoading()
        }

        lock.lock()
        tasks[key] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    private func removeTask(_ key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = nil
        lock.unlock()
    }
}
