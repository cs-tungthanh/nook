import SwiftUI
import AppKit

final class BreakOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class BreakOverlayController {
    private var windows: [NSWindow] = []

    func show(pomodoro: Pomodoro) {
        hide()
        windows = NSScreen.screens.map { screen in
            let window = BreakOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Floating level keeps the menu bar and Dock visible above the overlay
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BreakOverlayView(pomodoro: pomodoro))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKey()
    }

    func hide() {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        // Hand focus back to the app that was active before the break
        NSApp.hide(nil)
    }
}

struct BreakOverlayView: View {
    @ObservedObject var pomodoro: Pomodoro

    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: PomodoroTheme.breakColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.55)

            VStack(spacing: 28) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 56))

                VStack(spacing: 8) {
                    Text("Break Time")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Let's relax — look away from the screen, stretch, breathe.")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                }

                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    countdownRing
                }

                HStack(spacing: 12) {
                    overlayButton("Snooze \(Constants.Pomodoro.snoozeMinutes)m", systemImage: "moon.zzz.fill", action: pomodoro.snooze)
                    overlayButton("Back to focus", systemImage: "bolt.fill", action: pomodoro.skipBreak)
                        .keyboardShortcut(.cancelAction)
                }

                Text("Press Esc to get back to focus")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .foregroundColor(.white)
        }
    }

    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: Constants.Time.updateInterval), value: pomodoro.progress)
            Text(TimeRemaining(from: pomodoro.timeRemaining ?? 0).clockFormat)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
        }
        .frame(width: 180, height: 180)
    }

    private func overlayButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.18))
            .cornerRadius(10)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}
