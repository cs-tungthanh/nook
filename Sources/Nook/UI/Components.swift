import SwiftUI
import AppKit

/// A segmented control drawn in SwiftUI. AppKit's segmented control can lose
/// its segment widths when the island hides it and lays it out again, leaving
/// one squashed "…" segment, so Nook draws its own.
struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selection = option
            }
        }) {
            Text(title(option))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A few presets plus Custom, on one compact row: `20m · 25m · 50m · Custom`.
/// Picking Custom turns that segment into its own `− 30m +` stepper.
struct PresetPicker: View {
    @Binding var value: Int
    @Binding var custom: CustomValue
    let presets: [Int]
    let customRange: ClosedRange<Int>
    /// What one step of the stepper is worth: 1 for minutes, 60 for seconds
    var unit = 1
    let title: (Int) -> String
    @Namespace private var namespace

    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(presets, id: \.self) { preset in
                Button(action: {
                    withAnimation(Self.spring) {
                        custom.isSelected = false
                        value = preset
                    }
                }) {
                    label(title(preset), isSelected: !custom.isSelected && value == preset)
                }
                .buttonStyle(.plain)
            }
            if custom.isSelected {
                stepper
            } else {
                Button(action: { withAnimation(Self.spring) { custom.isSelected = true } }) {
                    label("Custom", isSelected: false)
                }
                .buttonStyle(.plain)
                .help("Choose your own")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }

    private func label(_ text: String, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .white : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
    }

    /// Steps by one unit up to `Constants.Stepper.step` units, then by that step
    private var stepper: some View {
        let step = Constants.Stepper.step
        let units = custom.value / unit
        let lower = customRange.lowerBound, upper = customRange.upperBound
        return HStack(spacing: 2) {
            stepButton("minus", label: "Shorter", enabled: custom.value > lower) {
                custom.value = max(lower, (units - (units > step ? step : 1)) * unit)
            }
            Text(title(custom.value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 30)
            stepButton("plus", label: "Longer", enabled: custom.value < upper) {
                custom.value = min(upper, (units + (units >= step ? step : 1)) * unit)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(Color.accentColor)
                .matchedGeometryEffect(id: "selection", in: namespace)
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(enabled ? 0.9 : 0.35))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Picks a value by clicking or dragging along a ruler of ticks. Ticks up to
/// the value glow, the rest stay dim, and a pointer sits under the value.
struct TickRuler: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// Ticks whose value is a multiple of this get a number above them
    let labelEvery: Int
    let tint: Color

    private let tickWidth: CGFloat = 3
    private let tickGap: CGFloat = 5
    private let tickHeight: CGFloat = 26
    private let labelWidth: CGFloat = 28
    private let pointerSize = CGSize(width: 10, height: 7)

    private var ticks: [Int] {
        Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
    }

    private var pitch: CGFloat { tickWidth + tickGap }
    private var width: CGFloat { CGFloat(ticks.count) * pitch - tickGap }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .leading) {
                ForEach(Array(ticks.enumerated()), id: \.element) { index, tick in
                    if tick % labelEvery == 0 {
                        Text("\(tick)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(tint.opacity(tick <= value ? 1 : 0.35))
                            .frame(width: labelWidth)
                            .offset(x: center(of: index) - labelWidth / 2)
                    }
                }
            }
            .frame(width: width, height: 12, alignment: .leading)

            HStack(spacing: tickGap) {
                ForEach(ticks, id: \.self) { tick in
                    Capsule()
                        .fill(tick <= value ? tint : tint.opacity(0.22))
                        .frame(width: tickWidth, height: tickHeight)
                }
            }

            Triangle()
                .fill(tint)
                .frame(width: pointerSize.width, height: pointerSize.height)
                .offset(x: center(of: ticks.firstIndex(of: value) ?? 0) - pointerSize.width / 2)
                .frame(width: width, alignment: .leading)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            select(at: drag.location.x)
        })
        .accessibilityElement()
        .accessibilityValue("\(value) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func center(of index: Int) -> CGFloat {
        CGFloat(index) * pitch + tickWidth / 2
    }

    private func select(at x: CGFloat) {
        let index = Int((x / pitch).rounded(.down))
        let tick = ticks[max(0, min(ticks.count - 1, index))]
        guard tick != value else { return }
        value = tick
        // A light tick on the trackpad for each step, like a physical dial
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// A small triangle pointing up.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
