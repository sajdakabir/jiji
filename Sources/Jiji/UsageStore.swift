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

    /// Weekly all-models usage as a percentage in 0...100. `nil` when unknown.
    @Published var weeklyAllModelsPercent: Double? = nil

    /// Human-readable reset string for the weekly all-models metric.
    @Published var weeklyAllModelsResetText: String? = nil

    /// Weekly Sonnet-only usage as a percentage in 0...100. `nil` when unknown.
    @Published var weeklySonnetPercent: Double? = nil

    /// Human-readable reset string for the weekly Sonnet-only metric.
    @Published var weeklySonnetResetText: String? = nil

    /// Timestamp of the last successful (or attempted) refresh.
    @Published var lastUpdated: Date? = nil

    /// Whether a valid claude.ai session is believed to exist. Set to `false`
    /// when the scraper is redirected to a `/login` path.
    @Published var isLoggedIn: Bool = true

    /// Most recent error message, if any. `nil` clears the error state.
    @Published var lastError: String? = nil

    /// Derived Jiji state based on the MAX of session and weekly all-models
    /// percentages so the menu bar icon escalates with whichever metric is
    /// most pressing.
    var state: JijiState {
        let candidates = [sessionPercent, weeklyAllModelsPercent].compactMap { $0 }
        guard let worst = candidates.max() else {
            return JijiState.from(percent: nil)
        }
        return JijiState.from(percent: worst)
    }
}
