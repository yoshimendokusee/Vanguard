import SwiftUI

/// Colors sampled from the WristCue Apple Watch storyboard (the visual source of truth).
public enum VanguardPalette {
    public static let background = Color.black
    /// Primary capsule buttons (Next, Send, View details).
    public static let teal = Color(red: 0, green: 0.557, blue: 0.651)
    public static let micTealTop = Color(red: 0.13, green: 0.624, blue: 0.627)
    public static let micTealBottom = Color(red: 0.078, green: 0.596, blue: 0.604)
    /// Bright teal for the title, rings and waveform.
    public static let accent = Color(red: 0.373, green: 0.749, blue: 0.8)
    public static let surface = Color(red: 0.106, green: 0.137, blue: 0.161)        // buttons and chips
    public static let card = Color(red: 0.078, green: 0.094, blue: 0.106)           // transcript and list cards
    public static let row = Color(red: 0.137, green: 0.165, blue: 0.184)            // key-detail rows
    public static let muted = Color(red: 0.6, green: 0.64, blue: 0.67)
    public static let recordRed = Color(red: 0.902, green: 0.212, blue: 0.216)
    public static let highPriorityFill = Color(red: 0.32, green: 0.106, blue: 0.106)
    public static let highPriority = Color(red: 0.949, green: 0.235, blue: 0.251)
    public static let amber = Color(red: 0.969, green: 0.573, blue: 0.024)
    public static let green = Color(red: 0.063, green: 0.741, blue: 0.537)
    public static let successFill = Color(red: 0.004, green: 0.392, blue: 0.333)
}

/// How a provisional category is shown. The wording stays provisional: it is never a diagnosis.
public struct TriagePresentation: Equatable, Sendable {
    public let title: String
    public let color: Color
    public let fill: Color
    public let symbol: String

    public static func of(_ category: TriageCategory?) -> TriagePresentation {
        switch category {
        case .immediate: return .init(title: "High priority", color: VanguardPalette.highPriority, fill: VanguardPalette.highPriorityFill, symbol: "exclamationmark.triangle.fill")
        case .delayed: return .init(title: "Needs attention", color: VanguardPalette.amber, fill: VanguardPalette.amber.opacity(0.18), symbol: "exclamationmark.circle.fill")
        case .minor: return .init(title: "Routine", color: VanguardPalette.green, fill: VanguardPalette.green.opacity(0.16), symbol: "checkmark.circle.fill")
        case .unassessed, nil: return .init(title: "Not assessed", color: VanguardPalette.muted, fill: VanguardPalette.row, symbol: "questionmark.circle.fill")
        }
    }
}

/// A full-width capsule button with a 44 pt minimum touch height.
struct CapsuleButton: View {
    enum Style { case primary, secondary }
    let title: String
    var symbol: String?
    var style: Style = .primary
    var minHeight: CGFloat = 44
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(.footnote, weight: .semibold)) }
                Text(title).font(.system(.body, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .foregroundStyle(.white)
            .background(Capsule().fill(style == .primary ? VanguardPalette.teal : VanguardPalette.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
