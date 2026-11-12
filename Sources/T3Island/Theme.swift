import SwiftUI

enum Theme {
    static let island = Color.black
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let muted = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.08)
    static let card = Color.white.opacity(0.055)

    static let needsYou = Color(hex: "#FFB020")
    static let working = Color(hex: "#3DD68C")
    static let replied = Color(hex: "#5AA9FF")
    static let failed = Color(hex: "#FF5D5D")

    static func mood(_ mood: ThreadMood) -> Color {
        switch mood {
        case .needsYou: needsYou
        case .working: muted
        case .replied: replied
        case .failed: failed
        case .idle: primary
        }
    }

    static func accent(_ provider: ProviderLimits) -> Color {
        if let hex = provider.accentHex { return Color(hex: hex) }
        return provider.id == "claudeAgent" ? Color(hex: "#E8875B") : secondary
    }
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum Format {
    /// "4h 21m", "5d 3h", "12m", "now".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86_400, h = s % 86_400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "now"
    }

    static func ago(_ date: Date?, now: Date) -> String {
        date.map { duration(now.timeIntervalSince($0)) } ?? ""
    }
}
