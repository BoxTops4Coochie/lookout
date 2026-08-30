import SwiftUI

enum Theme {
    static let accent = Color(red: 0.35, green: 0.78, blue: 1.0)
    static let bg = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let card = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let cardStroke = Color.white.opacity(0.06)
    static let textDim = Color.secondary
    static let live = Color(red: 1.0, green: 0.35, blue: 0.4)

    static let corner: CGFloat = 16

    static func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(card)
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(cardStroke))
    }
}

/// Hermex-flavored: subtle spring transitions, generous corners, minimal chrome.
extension View {
    func cardStyle() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.cardStroke)
            )
    }

    func fluidSpring() -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97)).animation(.spring(duration: 0.3)),
            removal: .opacity.combined(with: .scale(scale: 0.99)).animation(.spring(duration: 0.2))
        )
    }
}

func relativeTime(_ ts: Double) -> String {
    let date = Date(timeIntervalSince1970: ts)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: .now)
}

func timeString(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: Date(timeIntervalSince1970: ts))
}
