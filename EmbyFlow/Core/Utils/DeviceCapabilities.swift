import Darwin
import Foundation
import UIKit

/// Which video codecs the device can decode **in hardware**.
///
/// This is the single most important knob for an iPhone 6s: the A9 has no HEVC
/// hardware decoder, so feeding it HEVC means software decoding, dropped frames
/// and a hot phone. Detecting this lets us ask the server for H.264 instead.
enum VideoDecodeClass: String {
    /// A9 and older — iPhone 6s / 6s Plus / SE (1st gen) and anything below.
    case h264Only
    /// A10 — iPhone 7 / 7 Plus: HEVC up to 8 bit.
    case hevc8Bit
    /// A11 and newer: HEVC Main10 / HDR.
    case hevc10Bit

    var supportsHEVC: Bool { self != .h264Only }

    var maxDecodableBitDepth: Int {
        switch self {
        case .h264Only: return 8
        case .hevc8Bit: return 8
        case .hevc10Bit: return 10
        }
    }

    var displayName: String {
        switch self {
        case .h264Only: return "H.264 硬解（无 HEVC 硬解）"
        case .hevc8Bit: return "H.264 + HEVC 8bit 硬解"
        case .hevc10Bit: return "H.264 + HEVC 10bit 硬解"
        }
    }
}

/// How aggressively playback should be pushed to the server.
enum PlaybackMode: String, CaseIterable, Identifiable {
    /// Pick direct play / remux / transcode from the device capability.
    case auto
    /// Never cap quality; still respects codecs the device physically lacks.
    case quality
    /// Force a server-side HLS stream: H.264, 8 bit, at most 8 Mbps.
    case transcode
    /// Same as `transcode`, but 720p / 4 Mbps. Best for an iPhone 6s on battery.
    case lowPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .quality: return "画质优先"
        case .transcode: return "省电（服务端转码）"
        case .lowPower: return "极限省电（720p）"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "按设备能力自动选择：能直连就直连，放不了的编码交给服务器转码。"
        case .quality:
            return "尽量原画直连，不限制分辨率。设备不支持的编码仍然会转码。"
        case .transcode:
            return "始终由服务器输出 H.264 / 8bit / 最高 8Mbps 的流，手机只做 H.264 硬解，最不容易发烫。"
        case .lowPower:
            return "在省电模式基础上再降到 720p / 4Mbps，流量与耗电最低。"
        }
    }

    /// When true the server must build the stream instead of handing over the file.
    var forcesServerStream: Bool {
        self == .transcode || self == .lowPower
    }

    var maxHeight: Int? {
        switch self {
        case .lowPower: return 720
        case .transcode: return 1080
        case .auto, .quality: return nil
        }
    }

    var bitrateCap: Int? {
        switch self {
        case .lowPower: return 4_000_000
        case .transcode: return 8_000_000
        case .auto, .quality: return nil
        }
    }
}

struct DeviceCapabilities {
    let machine: String
    let decodeClass: VideoDecodeClass
    let isMemoryConstrained: Bool

    static let current = DeviceCapabilities()

    init(machine machineOverride: String? = nil, decodeClass decodeClassOverride: VideoDecodeClass? = nil) {
        let identifier = machineOverride ?? Self.machineIdentifier()
        self.machine = identifier
        self.decodeClass = decodeClassOverride ?? Self.decodeClass(for: identifier)
        self.isMemoryConstrained = Self.isMemoryConstrained(for: identifier)
    }

    /// `hw.machine`, e.g. "iPhone8,1" for an iPhone 6s.
    static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { continue }
            identifier.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static func decodeClass(for identifier: String) -> VideoDecodeClass {
        if a9AndOlder.contains(identifier) { return .h264Only }
        if a10Devices.contains(identifier) { return .hevc8Bit }
        // Unknown/newer hardware is assumed capable; the manual override in
        // Settings covers anything exotic.
        return .hevc10Bit
    }

    static func isMemoryConstrained(for identifier: String) -> Bool {
        !a11AndNewer.contains(identifier)
    }

    /// A9 and older: iPhone 6s / 6s Plus / SE (1st) and everything before it.
    private static let a9AndOlder: Set<String> = [
        "iPhone8,1", "iPhone8,2", "iPhone8,4",              // 6s / 6s Plus / SE (A9)
        "iPhone7,1", "iPhone7,2",                           // 6 Plus / 6 (A8)
        "iPhone6,1", "iPhone6,2",                           // 5s (A7)
        "iPhone5,1", "iPhone5,2", "iPhone5,3", "iPhone5,4", // 5 / 5c
        "iPhone4,1", "iPhone3,1", "iPhone3,2", "iPhone3,3", // 4s and older
        "iPad4,1", "iPad4,2", "iPad4,3", "iPad4,4", "iPad4,5", "iPad4,6", "iPad4,7", "iPad4,8", "iPad4,9",
        "iPad5,1", "iPad5,2", "iPad5,3", "iPad5,4",
        "iPad6,3", "iPad6,4", "iPad6,7", "iPad6,8", "iPad6,11", "iPad6,12",
        "iPod7,1"
    ]

    /// A10 / A10X: HEVC 8 bit only. iPhone 7 era.
    private static let a10Devices: Set<String> = [
        "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",
        "iPad7,1", "iPad7,2", "iPad7,3", "iPad7,4", "iPad7,5", "iPad7,6", "iPad7,11", "iPad7,12",
        "iPod9,1"
    ]

    private static let a11AndNewer: Set<String> = [
        "iPhone10,1", "iPhone10,2", "iPhone10,3", "iPhone10,4", "iPhone10,5", "iPhone10,6",
        "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8",
        "iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8",
        "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4",
        "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5", "iPhone14,6", "iPhone14,7", "iPhone14,8",
        "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
        "iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4",
        "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4", "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8",
        "iPad8,9", "iPad8,10", "iPad8,11", "iPad8,12",
        "iPad13,1", "iPad13,2", "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7",
        "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", "iPad13,16", "iPad13,17", "iPad13,18", "iPad13,19",
        "iPad14,1", "iPad14,2", "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6",
        "iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6"
    ]
}
