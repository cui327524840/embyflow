import Foundation

struct MediaStreamInfo: Codable, Hashable, Identifiable {
    var index: Int
    var type: String
    var codec: String?
    var language: String?
    var displayTitle: String?
    var title: String?
    var isDefault: Bool?
    var isExternal: Bool?
    var isForced: Bool?
    var isInterlaced: Bool?
    var width: Int?
    var height: Int?
    var bitRate: Int?
    var channels: Int?
    var channelLayout: String?
    var deliveryMethod: String?
    var deliveryUrl: String?
    var profile: String?
    var videoRange: String?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index = "Index", type = "Type", codec = "Codec", language = "Language"
        case displayTitle = "DisplayTitle", title = "Title", isDefault = "IsDefault"
        case isExternal = "IsExternal", isForced = "IsForced", isInterlaced = "IsInterlaced"
        case width = "Width", height = "Height", bitRate = "BitRate", channels = "Channels"
        case channelLayout = "ChannelLayout", deliveryMethod = "DeliveryMethod"
        case deliveryUrl = "DeliveryUrl", profile = "Profile", videoRange = "VideoRange"
    }
}

extension MediaStreamInfo {
    var isVideo: Bool { type.caseInsensitiveCompare("Video") == .orderedSame }
    var isAudio: Bool { type.caseInsensitiveCompare("Audio") == .orderedSame }
    var isSubtitle: Bool { type.caseInsensitiveCompare("Subtitle") == .orderedSame }

    /// Image based subtitles (PGS / VobSub) can only be shown by burning them in server side.
    var isTextSubtitle: Bool {
        guard isSubtitle else { return false }
        let value = (codec ?? "").lowercased()
        let imageBased: Set<String> = [
            "pgs", "pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle",
            "vobsub", "xsub", "dvb_subtitle", "dvb_teletext", "sub"
        ]
        return !imageBased.contains(value)
    }

    var resolutionLabel: String? {
        guard let height = height, height > 0 else { return nil }
        if height < 500 { return "480P" }
        if height < 700 { return "720P" }
        if height < 1000 { return "1080P" }
        if height < 1300 { return "1440P" }
        if height < 2000 { return "4K" }
        return "8K"
    }

    var displayLabel: String {
        if let title = title, !title.isEmpty { return title }
        if let displayTitle = displayTitle, !displayTitle.isEmpty { return displayTitle }
        let codecName = (codec ?? type).uppercased()
        if isVideo, let resolution = resolutionLabel {
            return "\(codecName) · \(resolution)"
        }
        if isAudio, let layout = channelLayout, !layout.isEmpty {
            return "\(codecName) · \(layout)"
        }
        return codecName
    }
}

struct MediaSourceInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String?
    var container: String?
    var path: String?
    var size: Int64?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var isInfiniteStream: Bool?
    var directStreamUrl: String?
    var transcodingUrl: String?
    var transcodingSubProtocol: String?
    var transcodingContainer: String?
    var videoType: String?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var mediaStreams: [MediaStreamInfo]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", container = "Container", path = "Path", size = "Size"
        case bitrate = "Bitrate", runTimeTicks = "RunTimeTicks"
        case supportsDirectPlay = "SupportsDirectPlay", supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding", isInfiniteStream = "IsInfiniteStream"
        case directStreamUrl = "DirectStreamUrl", transcodingUrl = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol", transcodingContainer = "TranscodingContainer"
        case videoType = "VideoType", defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex", mediaStreams = "MediaStreams"
    }

    var videoStream: MediaStreamInfo? { mediaStreams?.first { $0.isVideo } }
    var audioStreams: [MediaStreamInfo] { mediaStreams?.filter { $0.isAudio } ?? [] }
    var subtitleStreams: [MediaStreamInfo] { mediaStreams?.filter { $0.isSubtitle } ?? [] }

    var runTimeSeconds: Double? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return ticks.secondsFromTicks
    }

    var summaryLine: String {
        var parts: [String] = []
        if let container = container, !container.isEmpty { parts.append(container.uppercased()) }
        if let bitrateText = formatBitrate(bitrate) { parts.append(bitrateText) }
        if let sizeText = formatFileSize(size) { parts.append(sizeText) }
        return parts.joined(separator: " · ")
    }
}

struct PlaybackInfoResponse: Codable {
    var mediaSources: [MediaSourceInfo]?
    var playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

struct PlaybackInfoRequest: Encodable {
    var userId: String
    var startTimeTicks: Int64
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    var maxStreamingBitrate: Int?
    var mediaSourceId: String?
    var enableDirectPlay: Bool
    var enableDirectStream: Bool
    var enableTranscoding: Bool
    var allowVideoStreamCopy: Bool
    var allowAudioStreamCopy: Bool
    var autoOpenLiveStream: Bool
    var deviceProfile: DeviceProfile

    enum CodingKeys: String, CodingKey {
        case userId = "UserId", startTimeTicks = "StartTimeTicks", audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex", maxStreamingBitrate = "MaxStreamingBitrate"
        case mediaSourceId = "MediaSourceId", enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream", enableTranscoding = "EnableTranscoding"
        case allowVideoStreamCopy = "AllowVideoStreamCopy", allowAudioStreamCopy = "AllowAudioStreamCopy"
        case autoOpenLiveStream = "AutoOpenLiveStream", deviceProfile = "DeviceProfile"
    }
}

struct PlaybackProgressRequest: Encodable {
    var itemId: String
    var mediaSourceId: String?
    var positionTicks: Int64
    var isPaused: Bool
    var isMuted: Bool
    var playMethod: String
    var playSessionId: String?
    var canSeek: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId", mediaSourceId = "MediaSourceId", positionTicks = "PositionTicks"
        case isPaused = "IsPaused", isMuted = "IsMuted", playMethod = "PlayMethod"
        case playSessionId = "PlaySessionId", canSeek = "CanSeek"
    }
}
