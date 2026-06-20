import Foundation
import Combine

/// Observable store for the current claude.ai session usage state.
///
/// All properties are updated on the main actor by the scraper and read by
/// the SwiftUI views via @EnvironmentObject / @ObservedObject.
@MainActor
final class UsageStore: ObservableObject {
    /// Current-session usage as a percentage in 0...100. `nil` when unknown
    /// (e.g. before the first scrape or when the page cannot be parsed).
    @Published var sessionPercent: Double? = nil

    /// Human-readable reset string parsed from the page, e.g. "Resets in 31 min".
    /// `nil` when no reset text was found.
    @Published var resetText: String? = nil

    /// Timestamp of the last successful (or attempted) refresh.
    @Published var lastUpdated: Date? = nil

    /// Whether a valid claude.ai session is believed to exist. Set to `false`
    /// when the scraper is redirected to a `/login` path.
    @Published var isLoggedIn: Bool = true

    /// Most recent error message, if any. `nil` clears the error state.
    @Published var lastError: String? = nil

    /// Derived Jiji state based on the current session percentage.
    var state: JijiState { JijiState.from(percent: sessionPercent) }
}
