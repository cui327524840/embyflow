import CoreFoundation
import Foundation

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Text subtitles are fetched as VTT/SRT and rendered by the app.
/// That means no re-encode, instant switching and full styling control.
enum SubtitleService {
    static func fetch(primary: URL, fallback: URL?) async -> [SubtitleCue] {
        if let data = try? await HTTPClient.shared.imageData(from: primary) {
            let cues = parse(decode(data))
            if !cues.isEmpty { return cues }
        }
        if let fallback = fallback, let data = try? await HTTPClient.shared.imageData(from: fallback) {
            return parse(decode(data))
        }
        return []
    }

    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count >= 2, let start = parseTime(parts[0]) else { continue }

            let endComponent = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .first ?? parts[1]
            let end = parseTime(endComponent) ?? (start + 4)

            guard timingIndex + 1 <= lines.count else { continue }
            let textLines = lines[(timingIndex + 1)...]
                .map { clean($0) }
                .filter { !$0.isEmpty }
            guard !textLines.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: textLines.joined(separator: "\n")))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Binary search: the player asks for the current cue four times a second.
    static func cueText(at time: Double, in cues: [SubtitleCue]) -> String? {
        guard !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start {
                high = mid - 1
            } else if time > cue.end {
                low = mid + 1
            } else {
                return cue.text
            }
        }
        return nil
    }

    // MARK: - Parsing helpers

    private static func parseTime(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var seconds = 0.0
        for component in trimmed.components(separatedBy: ":") {
            let cleaned = component.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(cleaned) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func clean(_ line: String) -> String {
        var text = line
        while let start = text.firstIndex(of: "<"), let end = text[start...].firstIndex(of: ">") {
            text.removeSubrange(start...end)
        }
        while let start = text.firstIndex(of: "{"), let end = text[start...].firstIndex(of: "}") {
            text.removeSubrange(start...end)
        }
        text = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Chinese subtitles are often GB18030 rather than UTF-8.
    private static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
