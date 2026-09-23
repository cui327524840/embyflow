import SwiftUI
import UIKit

/// Drop-in replacement for `AsyncImage` that works on iOS 14.5 and renders a
/// decoded, correctly sized bitmap from the shared pipeline.
struct RemoteImage: View {
    let url: URL?
    let targetSize: CGSize
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        // A flexible base colour owns the size, the image sits on top and is
        // clipped to the base. This is what keeps `.fill` art from spilling
        // outside its cell (and from fighting the layout).
        Theme.placeholder
            .overlay(content)
            .clipped()
            .onAppear(perform: load)
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
            }
            .onChange(of: url) { _ in load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image = image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Theme.tertiaryText)
        }
    }

    private func load() {
        guard let url = url else {
            image = nil
            return
        }
        let scale = displayScale
        if let cached = ImagePipeline.shared.cachedImage(for: url, target: targetSize, scale: scale) {
            image = cached
            return
        }
        loadTask?.cancel()
        loadTask = Task {
            let loaded = await ImagePipeline.shared.image(for: url, target: targetSize, scale: scale)
            guard !Task.isCancelled else { return }
            self.image = loaded
        }
    }
}
