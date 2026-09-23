import CryptoKit
import Foundation
import ImageIO
import UIKit

/// `UIImage` is not `Sendable`; wrapping it keeps the concurrency checker quiet
/// without giving up the off-main-thread decode.
struct SendableImage: @unchecked Sendable {
    let image: UIImage
}

/// Poster loading, the way it has to be done to stay at 120fps:
/// memory cache for decoded bitmaps, disk cache for original bytes,
/// downsampling through ImageIO, and de-duplicated in-flight requests.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // A 2GB A9 device cannot afford the same decoded-bitmap budget as a
        // current phone, so the cache shrinks with the hardware.
        let constrained = DeviceCapabilities.current.isMemoryConstrained
        cache.countLimit = constrained ? 240 : 600
        cache.totalCostLimit = (constrained ? 36 : 80) * 1024 * 1024
        return cache
    }()

    private let disk: DiskImageCache
    private let session: URLSession
    private let semaphore = AsyncSemaphore(limit: 6)
    private let lock = NSLock()
    private var inFlight: [String: Task<SendableImage?, Never>] = [:]

    private init() {
        disk = DiskImageCache(
            byteLimit: DeviceCapabilities.current.isMemoryConstrained
                ? 384 * 1024 * 1024
                : 512 * 1024 * 1024
        )

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        // Never get killed in the background for holding on to bitmaps.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.memory.removeAllObjects()
        }
    }

    // MARK: - Public API

    /// Synchronous hit used on the very first frame of a cell so re-appearing
    /// cards never flash a placeholder.
    func cachedImage(for url: URL?, target: CGSize, scale: CGFloat) -> UIImage? {
        guard let url = url else { return nil }
        return memory.object(forKey: memoryKey(url: url, target: target, scale: scale) as NSString)
    }

    func image(for url: URL, target: CGSize, scale: CGFloat) async -> UIImage? {
        let key = memoryKey(url: url, target: target, scale: scale)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let task = taskIfNeeded(for: key) {
            makeTask(url: url, target: target, scale: scale, memoryKey: key)
        }
        return await task.value?.image
    }

    /// Warms the cache for the next few cards. Failures are silent.
    func prefetch(_ urls: [URL?], target: CGSize, scale: CGFloat, limit: Int = 10) {
        let pending = urls
            .compactMap { $0 }
            .filter { memory.object(forKey: memoryKey(url: $0, target: target, scale: scale) as NSString) == nil }
        guard !pending.isEmpty else { return }
        for url in pending.prefix(limit) {
            _ = Task { _ = await self.image(for: url, target: target, scale: scale) }
        }
    }

    func diskSize() async -> Int64 {
        await disk.totalSize()
    }

    func clear() async {
        memory.removeAllObjects()
        await disk.removeAll()
    }

    // MARK: - Internals

    private func makeTask(url: URL, target: CGSize, scale: CGFloat, memoryKey: String) -> Task<SendableImage?, Never> {
        let diskKey = Self.diskKey(for: url)
        let pipeline = self
        return Task<SendableImage?, Never> {
            defer { pipeline.finish(memoryKey: memoryKey) }

            if let cachedData = await pipeline.disk.data(forKey: diskKey),
               let image = Self.downsample(data: cachedData, to: target, scale: scale) {
                pipeline.memory.setObject(image, forKey: memoryKey as NSString, cost: cachedData.count)
                return SendableImage(image: image)
            }

            await pipeline.semaphore.acquire()
            var payload: Data?
            do {
                payload = try await pipeline.download(url)
            } catch {
                payload = nil
            }
            await pipeline.semaphore.release()

            guard let data = payload,
                  let image = Self.downsample(data: data, to: target, scale: scale) else {
                return nil
            }

            await pipeline.disk.store(data, forKey: diskKey)
            pipeline.memory.setObject(image, forKey: memoryKey as NSString, cost: data.count)
            return SendableImage(image: image)
        }
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, _) = try await HTTPClient.shared.data(for: request, session: session)
        return data
    }

    private func finish(memoryKey: String) {
        lock.lock()
        inFlight[memoryKey] = nil
        lock.unlock()
    }

    /// Locking lives in synchronous helpers so no lock is ever taken from an
    /// async context (that is a warning today and an error in Swift 6).
    /// Atomic "get existing or create": keeps concurrent requests for the same
    /// poster down to a single download without locking in an async context.
    private func taskIfNeeded(
        for key: String,
        create: () -> Task<SendableImage?, Never>
    ) -> Task<SendableImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[key] { return existing }
        let created = create()
        inFlight[key] = created
        return created
    }

    private func memoryKey(url: URL, target: CGSize, scale: CGFloat) -> String {
        let width = Int(target.width.rounded())
        let height = Int(target.height.rounded())
        let scaleText = String(format: "%.2f", scale)
        return "\(url.absoluteString)|\(width)x\(height)@\(scaleText)"
    }

    private static func diskKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Decode + scale in one pass. This is what keeps a fast scroll from
    /// stacking full-size bitmap decodes on the main thread.
    private static func downsample(data: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let maxPixel = max(pointSize.width, pointSize.height) * max(1, scale)
        guard maxPixel > 2 else { return UIImage(data: data) }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
