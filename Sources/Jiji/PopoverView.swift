import SwiftUI
import AppKit
import WebKit

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var appDelegate: AppDelegate

    @Environment(\.dismiss) private var dismiss

    /// Resolve the scraper from the AppDelegate. The AppDelegate creates the
    /// scraper in `applicationDidFinishLaunching`, before the popover is ever
    /// shown, so this is always non-nil at use time.
    private var scraper: UsageScraper { appDelegate.scraper }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            body_section

            Divider()

            footer_buttons
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    // MARK: - Header

    /// Title-only header. The animated cat lives in the menu bar, not here.
    private var header: some View {
        Text("Jiji")
            .font(.headline)
    }

    // MARK: - Body

    private var body_section: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isLoggedIn == false {
                Text("Not signed in")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            metricRow(
                title: "Current session",
                percent: store.sessionPercent,
                reset: store.resetText
            )

            metricRow(
                title: "Weekly (all models)",
                percent: store.weeklyAllModelsPercent,
                reset: store.weeklyAllModelsResetText
            )

            metricRow(
                title: "Weekly (Sonnet only)",
                percent: store.weeklySonnetPercent,
                reset: store.weeklySonnetResetText
            )

            Text("Last updated: \(lastUpdatedText)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    /// One metric row: label + right-aligned percentage, with the reset text
    /// in a smaller footnote underneath.
    @ViewBuilder
    private func metricRow(title: String, percent: Double?, reset: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentText(percent))
                    .font(.system(.body, design: .monospaced))
            }
            if let r = reset, !r.isEmpty {
                Text(r)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percentText(_ percent: Double?) -> String {
        guard let p = percent else { return "Unknown" }
        return "\(Int(p.rounded()))%"
    }

    private var lastUpdatedText: String {
        guard let date = store.lastUpdated else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Footer

    private var footer_buttons: some View {
        HStack {
            Button {
                Task { await scraper.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Spacer()

            Menu {
                Button("Log in again") {
                    // Clear any existing claude.ai cookies so the login page
                    // actually shows the login form instead of an already-
                    // authenticated session, then present the login window.
                    clearClaudeCookiesAndPresentLogin()
                }
                Button("Quit Jiji") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Actions

    /// Drops any claude.ai cookies in the shared cookie store, marks the store
    /// as logged-out, and asks the AppDelegate to present the login window.
    private func clearClaudeCookiesAndPresentLogin() {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                let host = cookie.domain.hasPrefix(".")
                    ? String(cookie.domain.dropFirst())
                    : cookie.domain
                let lower = host.lowercased()
                guard lower == "claude.ai" || lower.hasSuffix(".claude.ai") else { continue }
                group.enter()
                cookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                Task { @MainActor in
                    store.isLoggedIn = false
                    appDelegate.presentLoginWindow()
                }
            }
        }
    }
}
