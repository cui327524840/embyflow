import AVFoundation
import AVKit
import Combine
import Foundation

/// Owns one AVPlayer, one queue and the Emby playback session for it.
///
/// Everything funnels through the same small set of `@Published` values so the
/// player chrome re-renders cheaply, and callbacks coming from AVFoundation or
/// NotificationCenter hop back to the main actor explicitly (iOS 14.5 has no
/// `MainActor.assumeIsolated`).
@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var mediaSource: MediaSourceInfo?
    @Published private(set) var audioTracks: [MediaStreamInfo] = []
    @Published private(set) var subtitleTracks: [MediaStreamInfo] = []
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var currentCue: String?
    @Published private(set) var playbackMethod: PlaybackMethod = .directPlay
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedTime: Double = 0
    @Published private(set) var isBuffering = true
    @Published private(set) var isPlaying = false
    @Published private(set) var isPiPSupported = false
    @Published private(set) var index: Int
    @Published private(set) var errorMessage: String?

    @Published var currentTime: Double = 0
    @Published var scrubPreview: Double?
    @Published var rate: Float = 1
    @Published var showControls = true
    @Published var selectedSubtitleIndex: Int?
    @Published var selectedAudioIndex: Int?

    let queue: [ItemDto]

    private let client: EmbyClient
    private let settings: AppSettings

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var subtitleTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?
    private var pipController: AVPictureInPictureController?

    private var playSessionId: String?
    private var lastReportedTime: Double = -100
    private var scrubBaseTime: Double = 0
    private var isActive = false
    private var didReportStop = false

    init(client: EmbyClient, settings: AppSettings, items: [ItemDto], startIndex: Int) {
        self.client = client
        self.settings = settings
        self.queue = items
        self.index = items.isEmpty ? 0 : min(max(0, startIndex), items.count - 1)
    }

    // MARK: - Derived state

    var hasItems: Bool { !queue.isEmpty }
    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }
    var currentItem: ItemDto { queue[min(index, queue.count - 1)] }

    var displayedTime: Double { scrubPreview ?? currentTime }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayedTime / duration))
    }

    var bufferedProgress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, bufferedTime / duration))
    }

    var isScrubbing: Bool { scrubPreview != nil }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive else { return }
        isActive = true
        configureAudioSession()
        observePlayer()
        await loadCurrent(autoPlay: true)
    }

    func stop() async {
        guard isActive, hasItems else { return }
        isActive = false
        await reportProgress(force: true)
        await reportStopIfNeeded()

        if duration > 60, currentTime / duration >= 0.92, !currentItem.isPlayed {
            try? await client.setPlayed(itemId: currentItem.id, played: true)
        }

        player.pause()
        player.replaceCurrentItem(with: nil)
        subtitleTask?.cancel()
        controlsTask?.cancel()
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Loading

    private func loadCurrent(autoPlay: Bool, resumeOverride: Double? = nil) async {
        guard hasItems else {
            errorMessage = "播放列表为空。"
            isBuffering = false
            return
        }

        isBuffering = true
        errorMessage = nil
        cues = []
        currentCue = nil

        let item = currentItem
        do {
            let startSeconds = resumeOverride ?? Self.resumeStart(for: item)
            let info = try await client.playbackInfo(
                itemId: item.id,
                startTimeTicks: startSeconds.ticksValue,
                audioStreamIndex: selectedAudioIndex,
                subtitleStreamIndex: nil,
                preferences: settings.playbackPreferences
            )

            guard let source = info.mediaSources?.first else {
                throw APIError.transport("服务器没有返回可用的媒体源。")
            }

            mediaSource = source
            playSessionId = info.playSessionId
            audioTracks = source.audioStreams
            subtitleTracks = source.subtitleStreams
            if selectedAudioIndex == nil {
                selectedAudioIndex = source.defaultAudioStreamIndex ?? audioTracks.first?.index
            }
            duration = source.runTimeSeconds ?? item.duration ?? 0
            currentTime = startSeconds
            bufferedTime = startSeconds

            let plan = try PlaybackPlan.make(item: item, source: source, credentials: client.credentials)
            playbackMethod = plan.method

            let asset = AVURLAsset(url: plan.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            if autoPlay {
                player.rate = max(rate, 0.1)
            } else {
                player.pause()
            }

            await reportStart()
            await autoSelectSubtitle()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            isBuffering = false
        } catch {
            errorMessage = error.localizedDescription
            isBuffering = false
        }
    }

    private static func resumeStart(for item: ItemDto) -> Double {
        guard !item.isPlayed, let position = item.resumeSeconds, let total = item.duration else { return 0 }
        if total - position < 30 { return 0 }
        return position
    }

    // MARK: - Transport controls

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        player.rate = max(rate, 0.1)
        isPlaying = true
        showControlsTemporarily()
    }

    func pause() {
        player.pause()
        isPlaying = false
        showControlsTemporarily()
        Task { await self.reportProgress(force: true) }
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    func seek(to seconds: Double, precise: Bool = false) {
        let upperBound = duration > 0 ? max(0, duration - 0.5) : seconds
        let target = min(max(0, seconds), upperBound)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // Coarse seeking first: HLS/remux sources answer far faster without
        // frame-accurate tolerances.
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.15, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = target
        scrubPreview = nil
        showControlsTemporarily()
    }

    func setRate(_ value: Float) {
        rate = value
        if player.timeControlStatus != .paused {
            player.rate = value
        }
        showControlsTemporarily()
    }

    func playNext() async {
        guard hasNext else { return }
        await reportStopIfNeeded()
        index += 1
        selectedSubtitleIndex = nil
        selectedAudioIndex = nil
        await loadCurrent(autoPlay: true)
    }

    func playPrevious() async {
        if currentTime > 5 {
            seek(to: 0, precise: true)
            return
        }
        guard hasPrevious else {
            seek(to: 0, precise: true)
            return
        }
        await reportStopIfNeeded()
        index -= 1
        selectedSubtitleIndex = nil
        selectedAudioIndex = nil
        await loadCurrent(autoPlay: true)
    }

    // MARK: - Scrubbing

    func beginScrubbing() {
        scrubBaseTime = currentTime
        scrubPreview = currentTime
        controlsTask?.cancel()
    }

    func updateScrubbing(delta: Double, width: Double) {
        guard duration > 0, width > 0 else { return }
        let secondsPerPoint = max(duration / width * 0.6, 0.05)
        let target = scrubBaseTime + delta * secondsPerPoint
        scrubPreview = min(max(0, target), duration)
    }

    func commitScrubbing() {
        guard let target = scrubPreview else { return }
        seek(to: target, precise: true)
    }

    func previewScrub(fraction: Double) {
        guard duration > 0 else { return }
        scrubPreview = min(max(0, fraction), 1) * duration
    }

    func commitScrub(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: min(max(0, fraction), 1) * duration, precise: true)
    }

    // MARK: - Track selection

    func selectSubtitle(index newIndex: Int?) async {
        selectedSubtitleIndex = newIndex
        cues = []
        currentCue = nil
        subtitleTask?.cancel()

        guard let newIndex = newIndex, let source = mediaSource else { return }
        guard let stream = subtitleTracks.first(where: { $0.index == newIndex }) else { return }
        guard stream.isTextSubtitle else {
            errorMessage = "这是图形字幕（PGS/VobSub），App 内无法直接渲染，请在服务端选择烧入字幕。"
            return
        }

        let item = currentItem
        let primary = client.subtitleStreamURL(itemId: item.id, mediaSourceId: source.id, index: newIndex, format: "vtt")
        let fallback = client.subtitleStreamURL(itemId: item.id, mediaSourceId: source.id, index: newIndex, format: "srt")
        guard let primaryURL = primary else { return }

        subtitleTask = Task { [weak self] in
            let loaded = await SubtitleService.fetch(primary: primaryURL, fallback: fallback)
            guard let self = self, !Task.isCancelled else { return }
            self.cues = loaded
            if loaded.isEmpty {
                self.errorMessage = "字幕加载失败，可尝试在服务端开启烧入字幕。"
            } else {
                self.errorMessage = nil
            }
        }
    }

    func selectAudio(index newIndex: Int) async {
        guard newIndex != selectedAudioIndex else { return }
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        selectedAudioIndex = newIndex
        await loadCurrent(autoPlay: wasPlaying, resumeOverride: resumeAt)
    }

    private func autoSelectSubtitle() async {
        guard settings.autoSelectSubtitles, !settings.subtitleLanguageOff else { return }
        let textTracks = subtitleTracks.filter { $0.isTextSubtitle }
        guard !textTracks.isEmpty else { return }

        let preferred = settings.subtitleLanguage.lowercased()
        if !preferred.isEmpty,
           let match = textTracks.first(where: { languageMatches($0.language ?? "", preferred: preferred) }) {
            await selectSubtitle(index: match.index)
            return
        }
        if let forced = textTracks.first(where: { $0.isForced == true }) {
            await selectSubtitle(index: forced.index)
        }
    }

    private func languageMatches(_ language: String, preferred: String) -> Bool {
        let value = language.lowercased()
        guard !value.isEmpty else { return false }
        if value.hasPrefix(preferred) || preferred.hasPrefix(value) { return true }
        let aliases: [String: [String]] = [
            "zh": ["chi", "zho", "chs", "cht", "zh-hans", "zh-hant", "cn"],
            "en": ["eng"],
            "ja": ["jpn"],
            "ko": ["kor"]
        ]
        return (aliases[preferred] ?? []).contains { value.hasPrefix($0) }
    }

    // MARK: - Controls visibility

    func toggleControls() {
        if showControls {
            controlsTask?.cancel()
            showControls = false
        } else {
            showControlsTemporarily()
        }
    }

    func showControlsTemporarily() {
        showControls = true
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            if self.isPlaying, !self.isScrubbing {
                self.showControls = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Picture in Picture

    func attach(playerLayer: AVPlayerLayer) {
        Task { @MainActor in
            guard self.pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let controller = AVPictureInPictureController(playerLayer: playerLayer)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            self.pipController = controller
            self.isPiPSupported = true
        }
    }

    func togglePictureInPicture() {
        guard let controller = pipController else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    // MARK: - Observers

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func observePlayer() {
        guard timeObserver == nil else { return }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.handleTimeUpdate(time) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.errorMessage = "播放中断，请重试或切换画质。"
                self?.isBuffering = false
            }
        }
    }

    private func removeObservers() {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver = failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0, !isScrubbing {
            currentTime = seconds
        }

        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }

        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        updateBufferedTime()
        updateCurrentCue()

        if isPlaying, abs(currentTime - lastReportedTime) >= 10 {
            lastReportedTime = currentTime
            Task { await self.reportProgress(force: true) }
        }
    }

    private func updateBufferedTime() {
        guard let range = player.currentItem?.loadedTimeRanges.last?.timeRangeValue else {
            bufferedTime = 0
            return
        }
        let end = (range.start + range.duration).seconds
        bufferedTime = end.isFinite ? max(0, end) : 0
    }

    private func updateCurrentCue() {
        guard !cues.isEmpty else {
            if currentCue != nil { currentCue = nil }
            return
        }
        let text = SubtitleService.cueText(at: currentTime, in: cues)
        if text != currentCue {
            currentCue = text
        }
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        showControls = true
        let finished = currentItem
        Task {
            try? await self.client.setPlayed(itemId: finished.id, played: true)
            if self.settings.autoPlayNext, self.hasNext {
                await self.playNext()
            }
        }
    }

    // MARK: - Session reporting

    private func reportStart() async {
        guard let source = mediaSource else { return }
        try? await client.reportPlaybackStart(
            itemId: currentItem.id,
            mediaSourceId: source.id,
            positionTicks: currentTime.ticksValue,
            playSessionId: playSessionId,
            playMethod: playbackMethod.apiValue
        )
        lastReportedTime = currentTime
        didReportStop = false
    }

    private func reportProgress(force: Bool) async {
        guard let source = mediaSource else { return }
        if !force, abs(currentTime - lastReportedTime) < 10 { return }
        lastReportedTime = currentTime
        try? await client.reportPlaybackProgress(
            itemId: currentItem.id,
            mediaSourceId: source.id,
            positionTicks: currentTime.ticksValue,
            isPaused: !isPlaying,
            playSessionId: playSessionId,
            playMethod: playbackMethod.apiValue
        )
    }

    private func reportStopIfNeeded() async {
        guard let source = mediaSource, !didReportStop else { return }
        didReportStop = true
        try? await client.reportPlaybackStopped(
            itemId: currentItem.id,
            mediaSourceId: source.id,
            positionTicks: currentTime.ticksValue,
            playSessionId: playSessionId,
            playMethod: playbackMethod.apiValue
        )
    }
}
