import SwiftUI
import UIKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let items: [ItemDto]
    let startIndex: Int
}

struct PlayerView: View {
    let request: PlaybackRequest

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode

    @State private var controller: PlaybackController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller = controller {
                PlayerSurface(controller: controller, onClose: close)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .statusBar(hidden: true)
        .onAppear(perform: beginIfNeeded)
        .onDisappear(perform: endPlayback)
    }

    private func beginIfNeeded() {
        UIApplication.shared.isIdleTimerDisabled = true
        // 进播放器自动横屏
        OrientationController.enterLandscape()
        guard controller == nil, let client = session.client, !request.items.isEmpty else { return }
        let created = PlaybackController(
            client: client,
            settings: settings,
            items: request.items,
            startIndex: request.startIndex
        )
        controller = created
        Task { await created.start() }
    }

    private func endPlayback() {
        UIApplication.shared.isIdleTimerDisabled = false
        // 退出播放器转回竖屏
        OrientationController.exitToPortrait()
        guard let controller = controller else { return }
        Task { await controller.stop() }
    }

    private func close() {
        endPlayback()
        presentationMode.wrappedValue.dismiss()
    }
}

private struct PlayerSurface: View {
    @ObservedObject var controller: PlaybackController
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlayerLayerView(
                    player: controller.player,
                    isScrubGestureEnabled: !controller.showControls,
                    onLayerReady: { controller.attach(playerLayer: $0) },
                    onSingleTap: { controller.toggleControls() },
                    onDoubleTap: { location in
                        handleDoubleTap(at: location, width: proxy.size.width)
                    },
                    onScrubBegan: { controller.beginScrubbing() },
                    onScrubChanged: { delta in
                        controller.updateScrubbing(delta: Double(delta), width: Double(proxy.size.width))
                    },
                    onScrubEnded: { controller.commitScrubbing() }
                )
                .ignoresSafeArea()

                if let cue = controller.currentCue {
                    SubtitleOverlay(text: cue)
                }

                PlayerControlsView(controller: controller, onClose: onClose)
                    .opacity(controller.showControls ? 1 : 0)
                    .allowsHitTesting(controller.showControls)
            }
        }
    }

    private func handleDoubleTap(at location: CGPoint, width: CGFloat) {
        if width > 0, location.x < width * 0.35 {
            controller.skip(-15)
        } else if width > 0, location.x > width * 0.65 {
            controller.skip(15)
        } else {
            controller.togglePlayPause()
        }
    }
}

private struct SubtitleOverlay: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.45))
                .cornerRadius(6)
                .padding(.horizontal, 24)
                .padding(.bottom, 110)
        }
        .allowsHitTesting(false)
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var controller: PlaybackController
    let onClose: () -> Void

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            VStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color.black.opacity(0.65), Color.black.opacity(0)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)
                Spacer(minLength: 0)
                LinearGradient(
                    gradient: Gradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centerControls
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .foregroundColor(.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.currentItem.seriesName ?? controller.currentItem.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if controller.currentItem.seriesName != nil {
                    Text(controller.currentItem.name)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(controller.playbackMethod.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)

            if controller.isPiPSupported {
                Button { controller.togglePictureInPicture() } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
            }

            Menu {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: { controller.setRate(speed) }) {
                        Text("\(speedText(speed))x")
                    }
                }
            } label: {
                Text(controller.rate == 1 ? "倍速" : "\(speedText(controller.rate))x")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 40, minHeight: 36)
            }
        }
    }

    private var centerControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 54) {
                Button { controller.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 30, weight: .regular))
                }
                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42, weight: .regular))
                        .frame(width: 48, height: 48)
                }
                Button { controller.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.system(size: 30, weight: .regular))
                }
            }

            if controller.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(6)
                    .padding(.horizontal, 30)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ScrubberView(
                progress: controller.progress,
                buffered: controller.bufferedProgress,
                onScrubChanged: { controller.previewScrub(fraction: $0) },
                onScrubEnded: { controller.commitScrub(fraction: $0) }
            )

            HStack(spacing: 16) {
                Text(formatTimecode(controller.displayedTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text(formatRemaining(current: controller.displayedTime, duration: controller.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Spacer(minLength: 0)

                subtitleMenu
                audioMenu

                if controller.hasNext {
                    Button { Task { await controller.playNext() } } label: {
                        Text("下一集").font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button("关闭字幕") { Task { await controller.selectSubtitle(index: nil) } }
            ForEach(controller.subtitleTracks) { track in
                Button(track.displayLabel) { Task { await controller.selectSubtitle(index: track.index) } }
            }
        } label: {
            Text(controller.selectedSubtitleIndex == nil ? "字幕" : "字幕已开")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(controller.audioTracks) { track in
                Button(track.displayLabel) { Task { await controller.selectAudio(index: track.index) } }
            }
        } label: {
            Text("音轨").font(.system(size: 13, weight: .semibold))
        }
    }

    private func speedText(_ speed: Float) -> String {
        if speed == speed.rounded() { return String(format: "%.0f", speed) }
        return String(format: "%.2f", speed).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
}

private struct ScrubberView: View {
    let progress: Double
    let buffered: Double
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let value = isDragging ? dragFraction : clamped(progress)
            let knobSize: CGFloat = isDragging ? 18 : 12

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.42))
                    .frame(width: width * CGFloat(clamped(buffered)), height: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * CGFloat(value), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: width * CGFloat(value) - knobSize / 2)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let fraction = clamped(Double(gesture.location.x / width))
                        dragFraction = fraction
                        onScrubChanged(fraction)
                    }
                    .onEnded { gesture in
                        let fraction = clamped(Double(gesture.location.x / width))
                        dragFraction = fraction
                        isDragging = false
                        onScrubEnded(fraction)
                    }
            )
        }
        .frame(height: 26)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
