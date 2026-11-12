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

    /// Thread updates: faces and rows slide to their new place and settle with a small overshoot.
    static let shuffle = Animation.spring(response: 0.5, dampingFraction: 0.68)
    /// Your own actions: quick and without overshoot, since you already know what happened.
    static let act = Animation.spring(response: 0.3, dampingFraction: 0.86)

    static func accent(_ provider: ProviderLimits) -> Color {
        if let hex = provider.accentHex { return Color(hex: hex) }
        return provider.id == "claudeAgent" ? Color(hex: "#E8875B") : secondary
    }
}

extension Color {
    /// `greyscale` keeps only the luminance.
    init(hex: String, greyscale: Bool = false) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0xFFFFFF
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        if greyscale {
            self.init(white: 0.2126 * red + 0.7152 * green + 0.0722 * blue)
        } else {
            self.init(red: red, green: green, blue: blue)
        }
    }
}

enum Format {
    /// "21:30", "tomorrow 09:00" or "Mon 09:00", in the user's clock format.
    static func clock(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

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
