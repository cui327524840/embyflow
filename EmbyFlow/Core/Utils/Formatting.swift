import Foundation

/// `00:00` / `0:00:00`, always safe for live or unknown durations.
func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "00:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

func formatRemaining(current: Double, duration: Double) -> String {
    let remaining = max(0, duration - current)
    return "-" + formatTimecode(remaining)
}

func formatRuntime(_ seconds: Double?) -> String? {
    guard let seconds = seconds, seconds > 0 else { return nil }
    let minutes = Int((seconds / 60).rounded())
    let hours = minutes / 60
    let rest = minutes % 60
    if hours > 0 {
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }
    return "\(rest) 分钟"
}

func formatBitrate(_ bitsPerSecond: Int?) -> String? {
    guard let bitsPerSecond = bitsPerSecond, bitsPerSecond > 0 else { return nil }
    let mbps = Double(bitsPerSecond) / 1_000_000
    return String(format: "%.1f Mbps", mbps)
}

func formatFileSize(_ bytes: Int64?) -> String? {
    guard let bytes = bytes, bytes > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension Int64 {
    /// Emby reports timeline positions in 100-nanosecond ticks.
    var secondsFromTicks: Double { Double(self) / 10_000_000 }
}

extension Double {
    var ticksValue: Int64 { Int64((self * 10_000_000).rounded()) }
}
