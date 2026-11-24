import Foundation

struct TimeRemaining {
    let hours: Int
    let minutes: Int
    let seconds: Int

    init(from timeInterval: TimeInterval) {
        let totalSeconds = Int(timeInterval)
        hours = totalSeconds / Constants.Time.secondsPerHour
        minutes = (totalSeconds % Constants.Time.secondsPerHour) / Constants.Time.secondsPerMinute
        seconds = totalSeconds % Constants.Time.secondsPerMinute
    }

    var longFormat: String {
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    var clockFormat: String {
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
