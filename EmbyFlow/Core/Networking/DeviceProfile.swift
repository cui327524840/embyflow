import Foundation

/// Everything the profile builder needs to describe this session to Emby.
struct PlaybackPreferences {
    var capabilities: DeviceCapabilities
    var mode: PlaybackMode
    var maxStreamingBitrate: Int?

    var forceTranscode: Bool { mode.forcesServerStream }
    var maxHeight: Int? { mode.maxHeight }

    /// The stricter of "mode cap" and "user cap".
    var effectiveBitrate: Int? {
        let caps = [mode.bitrateCap, maxStreamingBitrate].compactMap { $0 }
        return caps.isEmpty ? nil : caps.min()
    }

    /// 设备能吃的分辨率上限：A9（6s）默认就压到 1080p。
    ///
    /// 4K 原画在 6s 上根本放不动（A9 没有 4K 硬解余量，HEVC 更是软解），
    /// 所以「原画播放不了」的正解是让服务器直接给我们 1080p，而不是换播放内核。
    var resolvedMaxHeight: Int? {
        if let explicit = mode.maxHeight { return explicit }
        switch capabilities.decodeClass {
        case .h264Only: return 1080
        case .hevc8Bit: return 1440
        case .hevc10Bit: return nil
        }
    }

    /// 老设备同时限制码率，避免 1080p 高码率也顶不住。
    var resolvedBitrate: Int? {
        let caps = [
            mode.bitrateCap,
            maxStreamingBitrate,
            capabilities.decodeClass == .h264Only ? 20_000_000 : nil
        ].compactMap { $0 }
        return caps.isEmpty ? nil : caps.min()
    }
}

/// The capability handshake Emby needs before it decides between
/// direct play / direct stream (remux) / full transcode.
///
/// The whitelists are built from the device's real hardware decoders, which is
/// what keeps an iPhone 6s from ever receiving an HEVC stream.
struct DeviceProfile: Encodable {
    var name: String
    var maxStreamingBitrate: Int?
    var directPlayProfiles: [DirectPlayProfile]
    var transcodingProfiles: [TranscodingProfile]
    var subtitleProfiles: [SubtitleProfile]
    var codecProfiles: [CodecProfile]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case subtitleProfiles = "SubtitleProfiles"
        case codecProfiles = "CodecProfiles"
    }

    /// Hand written so optional numbers are omitted instead of sent as `null`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(maxStreamingBitrate, forKey: .maxStreamingBitrate)
        try container.encode(directPlayProfiles, forKey: .directPlayProfiles)
        try container.encode(transcodingProfiles, forKey: .transcodingProfiles)
        try container.encode(subtitleProfiles, forKey: .subtitleProfiles)
        if !codecProfiles.isEmpty {
            try container.encode(codecProfiles, forKey: .codecProfiles)
        }
    }

    static func make(preferences: PlaybackPreferences) -> DeviceProfile {
        let decodeClass = preferences.capabilities.decodeClass
        let videoCodecs = decodeClass.supportsHEVC ? "h264,hevc" : "h264"

        var directPlayProfiles: [DirectPlayProfile] = []
        if !preferences.forceTranscode {
            // AVFoundation plays these containers untouched.
            directPlayProfiles.append(
                DirectPlayProfile(
                    container: "mp4,m4v,mov",
                    audioCodec: "aac,mp3,alac,ac3,eac3",
                    videoCodec: videoCodecs,
                    type: "Video"
                )
            )
        }

        var transcodingProfiles: [TranscodingProfile] = []
        if !preferences.forceTranscode {
            // 1st choice: remux only (video/audio copied) — the server barely works,
            // and an H.264 source still lands in the phone's hardware decoder.
            transcodingProfiles.append(
                TranscodingProfile(
                    container: "ts",
                    type: "Video",
                    videoCodec: videoCodecs,
                    audioCodec: "aac,ac3,eac3,mp3",
                    protocols: "hls",
                    context: "Streaming",
                    maxAudioChannels: "6",
                    copyTimestamps: true,
                    minSegments: 1,
                    breakOnNonKeyFrames: true
                )
            )
        }
        // 2nd choice (and the only one in power-saving modes): real transcode to
        // H.264 8 bit + AAC, which every iOS device decodes in hardware.
        transcodingProfiles.append(
            TranscodingProfile(
                container: "ts",
                type: "Video",
                videoCodec: "h264",
                audioCodec: "aac",
                protocols: "hls",
                context: "Streaming",
                maxAudioChannels: "2",
                copyTimestamps: false,
                minSegments: 1,
                breakOnNonKeyFrames: true
            )
        )

        return DeviceProfile(
            name: "EmbyFlow",
            maxStreamingBitrate: preferences.resolvedBitrate,
            directPlayProfiles: directPlayProfiles,
            transcodingProfiles: transcodingProfiles,
            subtitleProfiles: defaultSubtitleProfiles(),
            codecProfiles: codecProfiles(preferences: preferences)
        )
    }

    private static func defaultSubtitleProfiles() -> [SubtitleProfile] {
        [
            // Text subtitles are fetched as files and drawn by the app:
            // no re-encode, instant switching.
            SubtitleProfile(format: "srt", method: "External"),
            SubtitleProfile(format: "subrip", method: "External"),
            SubtitleProfile(format: "vtt", method: "External"),
            SubtitleProfile(format: "webvtt", method: "External"),
            // Styling heavy or image based subtitles must be burned in.
            SubtitleProfile(format: "ass", method: "Encode"),
            SubtitleProfile(format: "ssa", method: "Encode"),
            SubtitleProfile(format: "pgs", method: "Encode"),
            SubtitleProfile(format: "pgssub", method: "Encode"),
            SubtitleProfile(format: "dvdsub", method: "Encode"),
            SubtitleProfile(format: "vobsub", method: "Encode")
        ]
    }

    private static func codecProfiles(preferences: PlaybackPreferences) -> [CodecProfile] {
        var profiles: [CodecProfile] = []
        let decodeClass = preferences.capabilities.decodeClass

        // 1. AVFoundation never decodes H.264 High 10 Profile (Hi10P) — common in
        //    anime remuxes. Cap H.264 at 8 bit so the server transcodes those.
        profiles.append(
            CodecProfile(
                type: "Video",
                codec: "h264",
                conditions: [
                    CodecCondition(condition: "LessThanEqual", property: "VideoBitDepth", value: "8", isRequired: false)
                ]
            )
        )

        // 2. A10 silicon only has an 8 bit HEVC decoder.
        if decodeClass == .hevc8Bit {
            profiles.append(
                CodecProfile(
                    type: "Video",
                    codec: "hevc",
                    conditions: [
                        CodecCondition(condition: "LessThanEqual", property: "VideoBitDepth", value: "8", isRequired: false)
                    ]
                )
            )
        }

        // 3. Power-saving modes cap the resolution so 4K sources are downscaled
        //    (a 6s screen is 750p; decoding 4K is pure waste).
        if let maxHeight = preferences.resolvedMaxHeight {
            profiles.append(
                CodecProfile(
                    type: "Video",
                    codec: "h264,hevc",
                    conditions: [
                        CodecCondition(
                            condition: "LessThanEqual",
                            property: "Height",
                            value: String(maxHeight),
                            isRequired: false
                        )
                    ]
                )
            )
        }

        return profiles
    }
}

struct DirectPlayProfile: Encodable {
    var container: String
    var audioCodec: String
    var videoCodec: String
    var type: String

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
    }
}

struct TranscodingProfile: Encodable {
    var container: String
    var type: String
    var videoCodec: String
    var audioCodec: String
    var protocols: String
    var context: String
    var maxAudioChannels: String
    var copyTimestamps: Bool
    var minSegments: Int
    var breakOnNonKeyFrames: Bool

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case protocols = "Protocol"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case copyTimestamps = "CopyTimestamps"
        case minSegments = "MinSegments"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
    }
}

struct SubtitleProfile: Encodable {
    var format: String
    var method: String

    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}

struct CodecProfile: Encodable {
    var type: String
    var codec: String
    var conditions: [CodecCondition]

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case conditions = "Conditions"
    }
}

struct CodecCondition: Encodable {
    var condition: String
    var property: String
    var value: String
    var isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case property = "Property"
        case value = "Value"
        case isRequired = "IsRequired"
    }
}
