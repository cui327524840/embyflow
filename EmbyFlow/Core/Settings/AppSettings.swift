import Combine
import Foundation

/// Playback preferences. Values are stored through explicit setters so the UI
/// stays reactive while UserDefaults stays the source of truth.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let maxStreamingBitrate = "embyflow.settings.maxStreamingBitrate"
        static let subtitleLanguage = "embyflow.settings.subtitleLanguage"
        static let autoSelectSubtitles = "embyflow.settings.autoSelectSubtitles"
        static let autoPlayNext = "embyflow.settings.autoPlayNext"
        static let playbackMode = "embyflow.settings.playbackMode"
    }

    @Published private(set) var maxStreamingBitrate: Int
    @Published private(set) var subtitleLanguage: String
    @Published private(set) var autoSelectSubtitles: Bool
    @Published private(set) var autoPlayNext: Bool
    @Published private(set) var playbackMode: PlaybackMode

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.maxStreamingBitrate = defaults.integer(forKey: Keys.maxStreamingBitrate)
        self.subtitleLanguage = defaults.object(forKey: Keys.subtitleLanguage) as? String ?? "zh"
        self.autoSelectSubtitles = defaults.object(forKey: Keys.autoSelectSubtitles) as? Bool ?? true
        self.autoPlayNext = defaults.object(forKey: Keys.autoPlayNext) as? Bool ?? true
        let storedMode = defaults.string(forKey: Keys.playbackMode) ?? ""
        self.playbackMode = PlaybackMode(rawValue: storedMode) ?? .auto
    }

    /// 0 means "unlimited / server default".
    var bitrateLimit: Int? {
        maxStreamingBitrate > 0 ? maxStreamingBitrate : nil
    }

    /// What actually gets sent to Emby: device capability + mode + user limit.
    var playbackPreferences: PlaybackPreferences {
        PlaybackPreferences(
            capabilities: .current,
            mode: playbackMode,
            maxStreamingBitrate: bitrateLimit
        )
    }

    var deviceCapabilities: DeviceCapabilities { .current }

    var subtitleLanguageForcesSelection: Bool {
        autoSelectSubtitles && !subtitleLanguage.isEmpty
    }

    var subtitleLanguageOff: Bool { subtitleLanguage == "__off__" }

    func updateMaxStreamingBitrate(_ value: Int) {
        maxStreamingBitrate = value
        defaults.set(value, forKey: Keys.maxStreamingBitrate)
    }

    func updateSubtitleLanguage(_ value: String) {
        subtitleLanguage = value
        defaults.set(value, forKey: Keys.subtitleLanguage)
    }

    func updateAutoSelectSubtitles(_ value: Bool) {
        autoSelectSubtitles = value
        defaults.set(value, forKey: Keys.autoSelectSubtitles)
    }

    func updateAutoPlayNext(_ value: Bool) {
        autoPlayNext = value
        defaults.set(value, forKey: Keys.autoPlayNext)
    }

    func updatePlaybackMode(_ value: PlaybackMode) {
        playbackMode = value
        defaults.set(value.rawValue, forKey: Keys.playbackMode)
    }
}
