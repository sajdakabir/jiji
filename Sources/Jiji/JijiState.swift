import Foundation

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
}
