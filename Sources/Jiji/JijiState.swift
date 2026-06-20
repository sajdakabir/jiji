import Foundation
import SwiftUI

/// The Jiji mood, derived purely from the current-session usage percentage.
enum JijiState: String, CaseIterable {
    case chill
    case alert
    case sideEye
    case worried
    case panic
    case dead

    /// Maps a usage percent in 0...100 to a Jiji mood.
    ///
    /// Thresholds:
    /// - `nil` or `< 25` -> `.chill`
    /// - `< 50`          -> `.alert`
    /// - `< 75`          -> `.sideEye`
    /// - `< 90`          -> `.worried`
    /// - `< 100`         -> `.panic`
    /// - else            -> `.dead`
    static func from(percent: Double?) -> JijiState {
        guard let p = percent else { return .chill }
        if p < 25 { return .chill }
        if p < 50 { return .alert }
        if p < 75 { return .sideEye }
        if p < 90 { return .worried }
        if p < 100 { return .panic }
        return .dead
    }

    /// SF Symbol name used to render this mood in the menu bar and popover.
    var sfSymbolName: String {
        switch self {
        case .chill:   return "moon.zzz.fill"
        case .alert:   return "eye"
        case .sideEye: return "eye.trianglebadge.exclamationmark"
        case .worried: return "exclamationmark.triangle"
        case .panic:   return "exclamationmark.triangle.fill"
        case .dead:    return "xmark.octagon.fill"
        }
    }

    /// Short human-readable caption for this mood.
    var caption: String {
        switch self {
        case .chill:   return "Chill"
        case .alert:   return "Alert"
        case .sideEye: return "Side-eye"
        case .worried: return "Worried"
        case .panic:   return "Panic"
        case .dead:    return "Done"
        }
    }

    /// Tint applied to the cat SF Symbol — escalates from neutral through
    /// orange/red as usage climbs, with a faded gray for the spent state.
    var tint: Color {
        switch self {
        case .chill:   return .primary
        case .alert:   return .primary
        case .sideEye: return .yellow
        case .worried: return .orange
        case .panic:   return .red
        case .dead:    return .gray
        }
    }
}
