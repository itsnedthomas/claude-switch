import AppKit
import SwiftUI

/// Design tokens, light and dark.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    static let surface = dynamic(0xFFFFFF, 0x191A1C)
    static let sunken = dynamic(0xF6F7F9, 0x222327)
    static let line = dynamic(0xDEE3E8, 0x36383E)
    static let lineSoft = dynamic(0xEAEDF1, 0x2E3037)
    static let ink = dynamic(0x252731, 0xFFFFFF)
    static let muted = dynamic(0x5B5D64, 0xB4B6BF)
    static let subtle = dynamic(0x888A93, 0x81838F)
    static let signal = Color(red: 0xE8 / 255, green: 0x87 / 255, blue: 0x3B / 255)
    static let accent = dynamic(0x348CFF, 0x59A3FF)
    static let danger = dynamic(0xE5484D, 0xFF6369)
    static let successSurface = dynamic(0xF2FBF5, 0x0B2415)
    static let successLine = dynamic(0xA9DFBB, 0x1F5A35)
    static let successInk = dynamic(0x1D7A3E, 0x8FE0AA)
    static let successDot = Color(red: 0.2, green: 0.7, blue: 0.4)
    static let warnSurface = dynamic(0xFFF6EE, 0x2A1A0C)
    static let warnLine = dynamic(0xF5C89A, 0x6B3D17)
    static let warnInk = dynamic(0xB2561A, 0xF5B27A)

    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 11)
}

/// The design system's status chip: tinted, 1px border, a dot.
struct Chip: View {
    enum Tone { case success, warn, neutral }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            if tone == .success { Circle().fill(Theme.successDot).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tone == .success ? Theme.successInk : tone == .warn ? Theme.warnInk : Theme.muted)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(tone == .success ? Theme.successSurface : tone == .warn ? Theme.warnSurface : Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tone == .success ? Theme.successLine : tone == .warn ? Theme.warnLine : Theme.line))
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.sunken : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .contentShape(Rectangle())
    }
}

enum HoverTone {
    case accent, danger
    var color: Color { self == .danger ? Theme.danger : Theme.accent }
}

/// Every link: an icon and text. On hover the colour eases to its tone and the
/// icon morphs (an arrow into a cross, a plus into a filled plus).
struct HoverLink: View {
    let icon: String
    var hoverIcon: String? = nil
    let text: String
    var tone: HoverTone = .accent
    var rest: Color = Theme.muted
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: hover ? (hoverIcon ?? icon) : icon)
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 12)
                Text(text)
            }
            .foregroundStyle(hover ? tone.color : rest)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

/// Every button: a bordered pill. On hover it takes its tone's colour and its
/// icon slides in beside the label.
struct HoverButton: View {
    let title: String
    var icon: String? = nil
    var tone: HoverTone = .accent
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: hover && icon != nil ? 4 : 0) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                        .frame(width: hover ? 11 : 0).opacity(hover ? 1 : 0)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hover ? tone.color : Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? tone.color.opacity(0.07) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hover ? tone.color.opacity(0.45) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

/// A light press: shrinks a touch while held.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Small outline icon in the muted ink, turning blue on hover, no box behind it.
struct QuietIcon: View {
    let system: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Theme.accent : Theme.subtle)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .help(help)
    }
}

/// One bordered box of rows split by hairlines.
struct Box<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
}

/// A settings row: an icon, the label, the control on the right. No hint lines.
struct Row<Control: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .frame(width: 16)
            Text(label).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

/// A small capsule switch, blue when on.
struct OToggle: View {
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Theme.line)
                Circle().fill(.white).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 28, height: 16)
            .brightness(hover ? 0.04 : 0)
            .scaleEffect(hover ? 1.06 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

/// Two-handled slider for a time range in minutes, snapping to `step`.
struct RangeSlider: View {
    @Binding var lower: Int
    @Binding var upper: Int
    var bounds: ClosedRange<Int> = 0...1440
    var step = 30

    var body: some View {
        GeometryReader { g in
            let w = g.size.width - 14
            let x = { (v: Int) in CGFloat(v - bounds.lowerBound) / CGFloat(bounds.upperBound - bounds.lowerBound) * w }
            let value = { (px: CGFloat) -> Int in
                let raw = Double(px / w) * Double(bounds.upperBound - bounds.lowerBound) + Double(bounds.lowerBound)
                return min(bounds.upperBound, max(bounds.lowerBound, Int((raw / Double(step)).rounded()) * step))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.lineSoft).frame(height: 4).padding(.horizontal, 7)
                Capsule().fill(Theme.accent).frame(width: max(0, x(upper) - x(lower)), height: 4).offset(x: x(lower) + 7)
                knob.offset(x: x(lower))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { lower = min(value($0.location.x - 7), upper - step) })
                knob.offset(x: x(upper))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { upper = max(value($0.location.x - 7), lower + step) })
            }
            .frame(height: g.size.height)
        }
        .frame(height: 18)
    }

    private var knob: some View {
        Circle().fill(Theme.surface)
            .overlay(Circle().strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .frame(width: 14, height: 14)
    }
}

/// − value + with quiet buttons; `format` renders the value.
struct Nudge: View {
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 2) {
            QuietIcon(system: "minus") { value = max(range.lowerBound, value - step) }
            Text(format(value)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.ink).frame(minWidth: 40)
            QuietIcon(system: "plus") { value = min(range.upperBound, value + step) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(.leading, 2)
    }
}

/// The refresh icon turns into a spinner while a refresh runs.
struct RefreshButton: View {
    let spinning: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !spinning)) { ctx in
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hover || spinning ? Theme.accent : Theme.subtle)
                    .rotationEffect(.degrees(spinning ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360 : 0))
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .help("Refresh")
    }
}
