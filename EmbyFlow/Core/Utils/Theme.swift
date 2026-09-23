import SwiftUI

/// Hand-written colour palette: avoids iOS 15+ only initialisers such as
/// `Color(uiColor:)` while keeping a single source of truth for the dark UI.
enum Theme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let surface = Color(red: 0.098, green: 0.106, blue: 0.118)
    static let surfaceElevated = Color(red: 0.145, green: 0.156, blue: 0.172)
    static let placeholder = Color(red: 0.152, green: 0.164, blue: 0.180)
    static let accent = Color(red: 0.322, green: 0.710, blue: 0.294)
    static let secondaryText = Color(white: 0.66)
    static let tertiaryText = Color(white: 0.45)
    static let cardBorder = Color.white.opacity(0.07)
    static let playerGradientTop = Color.black.opacity(0.55)
}

extension View {
    func cardShape(_ radius: CGFloat = 12) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func cardStroke(_ radius: CGFloat = 12) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
    }
}
