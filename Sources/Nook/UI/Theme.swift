import SwiftUI

/// Colors and labels for each Pomodoro phase: tomato for focus, mint for breaks.
struct PomodoroTheme {
    let colors: [Color]
    let label: String
    let symbol: String

    static let focusColors = [Color(red: 0.93, green: 0.27, blue: 0.24), Color(red: 0.98, green: 0.55, blue: 0.22)]
    static let breakColors = [Color(red: 0.07, green: 0.6, blue: 0.5), Color(red: 0.2, green: 0.72, blue: 0.85)]
    static let pausedColors = [Color(red: 0.4, green: 0.42, blue: 0.55), Color(red: 0.55, green: 0.57, blue: 0.68)]

    init(phase: Pomodoro.Phase) {
        switch phase {
        case .focusing:
            colors = Self.focusColors
            label = "FOCUS"
            symbol = "flame.fill"
        case .onBreak:
            colors = Self.breakColors
            label = "BREAK"
            symbol = "cup.and.saucer.fill"
        case .paused:
            colors = Self.pausedColors
            label = "PAUSED"
            symbol = "pause.fill"
        case .off:
            colors = Self.focusColors
            label = ""
            symbol = "flame.fill"
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The Music card's colors: vivid while playing, muted while paused or stopped
enum MusicTheme {
    static let playingColors = [Color(red: 0.49, green: 0.30, blue: 0.95), Color(red: 0.93, green: 0.33, blue: 0.62)]
    static let restingColors = [Color(red: 0.30, green: 0.26, blue: 0.48), Color(red: 0.45, green: 0.28, blue: 0.46)]
}
