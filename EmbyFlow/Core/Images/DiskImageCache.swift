import Foundation

/// Actor-isolated disk cache for original image bytes.
/// Writes are trimmed with a simple LRU pass every N writes, which keeps
/// scrolling free of file-system work on the caller's thread.
actor DiskImageCache {
    private let directory: URL
    private let fileManager = FileManager.default
    private let byteLimit: Int64
    private var writeCount = 0

    init(name: String = "ImageCache", byteLimit: Int64 = 512 * 1024 * 1024) {
        self.byteLimit = byteLimit
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = caches.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        self.directory = folder
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key), options: [.mappedIfSafe])
    }

    func store(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
        writeCount += 1
        if writeCount % 40 == 0 {
            trimIfNeeded()
        }
    }

    func totalSize() -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        writeCount = 0
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key + ".img")
    }

    private func trimIfNeeded() {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            entries.append((url, size, values.contentModificationDate ?? Date.distantPast))
        }
        guard total > byteLimit else { return }

        var remaining = total
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if remaining <= byteLimit { break }
            try? fileManager.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }
}
