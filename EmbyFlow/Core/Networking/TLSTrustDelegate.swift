import Foundation
import Security

/// 自建 Emby 服务器（反代证书链不完整、自签名、内网 CA）在 iOS 上会被系统拒绝，
/// 而 Forward / VidHub / Fileball 这类客户端都会在系统判定失败时选择「信任」。
/// 行为保持一致，否则同一个地址在那些 App 能登、在我们这里报 SSL error。
final class TLSTrustDelegate: NSObject, URLSessionDelegate {
    static let shared = TLSTrustDelegate()

    private override init() {
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 证书本身没问题就用系统默认判断；只有系统判失败时才兜底信任。
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
