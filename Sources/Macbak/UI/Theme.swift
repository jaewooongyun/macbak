import SwiftUI

/// Spacing and shape tokens. Every screen uses these, so a change here restyles the whole app.
enum Theme {
    static let gutter: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let rowRadius: CGFloat = 12
    /// Content stops growing here and stays centered, so rows stay readable on wide windows.
    static let maxContentWidth: CGFloat = 1240

    static let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
    static let rowShape = RoundedRectangle(cornerRadius: rowRadius, style: .continuous)

    /// Every live value (numbers, gauges, bars) changes with this one short animation. Values arrive together on each
    /// 2-second sample, so they all start and finish together and the screen moves for about a fifth of a second of every 2 s.
    /// - Important: Longer, staggered animations kept something moving most of the time; each animated frame is a
    ///   SwiftUI commit on the main thread, which took the glance screen from 6% to over 20% of a core.
    static let liveChange = Animation.smooth(duration: 0.22)

    /// Big numbers: rounded, like the system's own gauges.
    static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

// MARK: - Formatting

/// Short sizes for glancing: "471 GB", "41.6 GB", "600 MB" — at most three significant digits, spaced unit.
private func sizeText(_ bytes: Double, base: Double) -> String {
    let gb = bytes / (base * base * base)
    if gb >= 1000 { return (gb / base).formatted(.number.precision(.fractionLength(0...1))) + " TB" }
    if gb >= 100 { return gb.formatted(.number.precision(.fractionLength(0))) + " GB" }
    if gb >= 1 { return gb.formatted(.number.precision(.fractionLength(0...1))) + " GB" }
    return (gb * base).formatted(.number.precision(.fractionLength(0))) + " MB"
}

extension Int64 {
    /// Decimal units, matching Finder.
    var diskText: String { sizeText(Double(self), base: 1000) }
}

extension UInt64 {
    /// Binary units, matching Activity Monitor.
    var memoryText: String { sizeText(Double(self), base: 1024) }
}

extension Double {
    /// "23%" for a value already in percent.
    var percentText: String { formatted(.number.precision(.fractionLength(0))) + "%" }
}

// MARK: - Meaning colors

extension AIVendor {
    /// One hue per vendor, from the system palette so light, dark and Increase Contrast stay correct.
    /// - Important: Used only where the color means "this vendor"; everything else stays monochrome.
    var tint: Color {
        switch self {
        case .anthropic: .orange
        case .openAI: .mint
        case .google: .blue
        case .cursor: .brown
        case .local: .purple
        case .other: .gray
        }
    }
}

extension AIStorageReport.Total {
    var tint: Color { vendor?.tint ?? Color.secondary }
}

extension CleanupStatus {
    var title: String {
        switch self {
        case .ready: "지워도 되는 것"
        case .review: "골라서 지울 것"
        case .protected: "지우면 안 되는 것"
        case .deferred: "금방 다시 생기는 것"
        }
    }

    /// One line under the group's title saying what the group means and what the person does with it.
    var groupNote: String {
        switch self {
        case .ready: "다시 만들어지고 지금 쓰는 곳이 없어 미리 골라 둡니다. 체크를 풀면 남깁니다."
        case .review: "지우면 다시 받거나 다시 만들어야 합니다. 이유를 보고 직접 고르세요."
        case .protected: "사용자 데이터·설정·보안 소프트웨어이거나, 지금 쓰는 중이거나, 판단할 근거가 부족한 것입니다. 고를 수 없습니다."
        case .deferred: "지워도 금방 다시 생겨서 지금은 미뤄 둡니다."
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .review: "exclamationmark.circle.fill"
        case .protected: "lock.fill"
        case .deferred: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .review: .orange
        case .protected, .deferred: .gray
        }
    }
}

extension MemoryPressure {
    var title: String {
        switch self {
        case .normal: "압력 보통"
        case .warning: "압력 경고"
        case .critical: "압력 위험"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    /// "보통" for meters, where "메모리" already labels the row.
    var shortTitle: String {
        switch self {
        case .normal: "보통"
        case .warning: "경고"
        case .critical: "위험"
        }
    }

    var advice: String {
        switch self {
        case .normal: "메모리에 여유가 있습니다."
        case .warning: "압축과 스왑이 늘고 있습니다. 큰 앱을 닫으면 나아집니다."
        case .critical: "메모리가 부족합니다. 쓰지 않는 앱을 닫아 주세요."
        }
    }
}

extension MemoryUsage {
    var swapText: String { swapTotal > 0 ? swapUsed.memoryText : "사용 안 함" }

    /// Fixed category order and hues (blue, pink, indigo) — validated for color-vision separation in light and dark.
    var segments: [BarSegment] {
        [
            BarSegment("app", Double(app), .blue),
            BarSegment("wired", Double(wired), .pink),
            BarSegment("compressed", Double(compressed), .indigo),
            BarSegment("cached", Double(cached), .gray),
            BarSegment("other", Double(other), .fillTertiary),
            BarSegment("free", Double(free), .fillQuaternary),
        ]
    }
}
