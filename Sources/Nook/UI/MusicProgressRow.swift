import SwiftUI

/// Rewind, a seek bar with the time on either side, and forward. Shown only
/// while a video that can be seeked is playing; live streams hide it.
struct MusicProgressRow: View {
    let music: MusicPlayer
    @ObservedObject var progress: MusicProgress
    /// Where the knob is while it's being dragged; the player's own reports
    /// would otherwise pull it back mid-drag
    @State private var dragTime: Double?
    @State private var isHovering = false

    var body: some View {
        if progress.canSeek {
            HStack(spacing: 6) {
                skipButton("gobackward.10", label: "Back 10 seconds", by: -Constants.Music.seekStepSeconds)
                timeLabel(dragTime ?? progress.time)
                seekBar
                timeLabel(progress.duration)
                skipButton("goforward.10", label: "Forward 10 seconds", by: Constants.Music.seekStepSeconds)
            }
        } else if progress.isLive {
            // Says why there's no seek bar, at the bar's height so the tile
            // doesn't jump when switching between a stream and a video
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("LIVE")
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                Text("Live stream · always plays the latest moment")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            .accessibilityElement(children: .combine)
        }
    }

    /// Click anywhere on the bar to jump there, or drag to scrub. The jump
    /// happens on release, so scrubbing doesn't seek on every pixel.
    private var seekBar: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = CGFloat(min(max((dragTime ?? progress.time) / progress.duration, 0), 1))
            let isActive = isHovering || dragTime != nil
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: isActive ? 5 : 3)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * fraction, height: isActive ? 5 : 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .offset(x: width * fraction - 5)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragTime = Double(min(max(value.location.x / width, 0), 1)) * progress.duration
                    }
                    .onEnded { value in
                        music.seek(to: Double(min(max(value.location.x / width, 0), 1)) * progress.duration)
                        dragTime = nil
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(TimeRemaining(from: progress.time).clockFormat)
        .accessibilityAdjustableAction { direction in
            let step = Constants.Music.seekStepSeconds
            music.skip(by: direction == .increment ? step : -step)
        }
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(TimeRemaining(from: seconds).clockFormat)
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
            .frame(minWidth: 30)
    }

    private func skipButton(_ symbol: String, label: String, by seconds: Double) -> some View {
        Button(action: { music.skip(by: seconds) }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(CustomPlainButtonStyle())
        .cornerRadius(5)
        .accessibilityLabel(label)
    }
}
