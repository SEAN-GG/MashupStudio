import SwiftUI

/// Dark studio look. Clip colors rotate per lane.
enum Theme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.08)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let surfaceRaised = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.72)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let playhead = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let ruler = Color.white.opacity(0.35)

    static let clipPalette: [Color] = [
        Color(red: 0.33, green: 0.55, blue: 0.95),
        Color(red: 0.62, green: 0.42, blue: 0.95),
        Color(red: 0.22, green: 0.72, blue: 0.60),
        Color(red: 0.95, green: 0.55, blue: 0.33),
        Color(red: 0.90, green: 0.38, blue: 0.62),
        Color(red: 0.35, green: 0.72, blue: 0.88)
    ]

    static func clipColor(lane: Int) -> Color {
        clipPalette[((lane % clipPalette.count) + clipPalette.count) % clipPalette.count]
    }
}
