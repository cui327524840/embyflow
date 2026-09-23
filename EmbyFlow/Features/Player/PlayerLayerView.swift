import AVFoundation
import SwiftUI
import UIKit

/// A UIView that owns the `AVPlayerLayer` so we can drive playback with plain
/// UIKit gestures: instant taps, and a pan that scrubs without waiting for
/// SwiftUI's gesture arbitration.
final class PlayerHostView: UIView {
    let playerLayer = AVPlayerLayer()

    var onSingleTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((CGFloat) -> Void)?
    var onScrubEnded: (() -> Void)?

    private let panGesture = UIPanGestureRecognizer()
    private var isScrubbing = false

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        setUpGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Resizing must not animate: implicit CABasicAnimation on frame
        // changes is a classic source of one blurred/overshot frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setScrubGestureEnabled(_ enabled: Bool) {
        panGesture.isEnabled = enabled
    }

    private func setUpGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(panGesture)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onDoubleTap?(gesture.location(in: self))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            isScrubbing = abs(translation.x) > 8 && abs(translation.x) > abs(translation.y)
            if isScrubbing { onScrubBegan?() }

        case .changed:
            if !isScrubbing, abs(translation.x) > 18, abs(translation.x) > abs(translation.y) * 1.2 {
                isScrubbing = true
                onScrubBegan?()
            }
            if isScrubbing { onScrubChanged?(translation.x) }

        case .ended, .cancelled, .failed:
            if isScrubbing { onScrubEnded?() }
            isScrubbing = false

        default:
            break
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var isScrubGestureEnabled: Bool = true
    var onLayerReady: ((AVPlayerLayer) -> Void)?
    var onSingleTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubChanged: ((CGFloat) -> Void)?
    var onScrubEnded: (() -> Void)?

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.player = player
        applyCallbacks(to: view)
        view.setScrubGestureEnabled(isScrubGestureEnabled)
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        applyCallbacks(to: uiView)
        uiView.setScrubGestureEnabled(isScrubGestureEnabled)
    }

    private func applyCallbacks(to view: PlayerHostView) {
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        view.onScrubBegan = onScrubBegan
        view.onScrubChanged = onScrubChanged
        view.onScrubEnded = onScrubEnded
    }
}
