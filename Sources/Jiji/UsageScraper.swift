import Foundation
import WebKit

/// Scrapes the current-session usage percentage from claude.ai's usage page
/// using a single hidden, retained `WKWebView`.
///
/// The web view shares cookies with the LoginView via
/// `WKWebsiteDataStore.default()`, so once the user logs in the scraper can
/// fetch the rendered usage DOM without any further interaction.
@MainActor
final class UsageScraper: NSObject, ObservableObject, WKNavigationDelegate {

    // MARK: - Hardcoded constants (security: no dynamic URLs / no JS interpolation)

    /// Only host allowed for navigation inside the scraper's web view.
    private static let allowedHost = "claude.ai"

    /// The only URL the scraper ever loads.
    private static let usageURL = URL(string: "https://claude.ai/settings/usage")!

    /// Polling interval used while waiting for the usage DOM to appear.
    private static let pollInterval: TimeInterval = 0.5

    /// Maximum time to poll for the usage DOM after navigation finishes.
    private static let pollTimeout: TimeInterval = 10.0

    /// Refresh cadence for the background timer.
    private static let refreshInterval: TimeInterval = 60.0

    /// Read-only DOM scraping script. **MUST** remain a single static string
    /// literal with no interpolation, per the security review.
    ///
    /// Returns `JSON.stringify({
    ///   current:      {percent: number, resetText: string|null} | null,
    ///   weeklyAll:    {percent: number, resetText: string|null} | null,
    ///   weeklySonnet: {percent: number, resetText: string|null} | null
    /// })` on success, or `null` while the page hasn't rendered any of the
    /// expected rows yet.
    private static let scrapeJS: String = """
    (function() {
      try {
        var percentRe = /(\\d{1,3})\\s*%/;
        var resetStartRe = /resets?\\s/i;
        var resetStopRe = /\\d{1,3}\\s*%|[\\n\\r]/;

        function findLabel(needle) {
          var all = document.querySelectorAll('body *');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (!el || !el.textContent) continue;
            var t = el.textContent.toLowerCase();
            if (t.indexOf(needle) === -1) continue;
            // Prefer the deepest element that contains the needle to avoid
            // matching the <body> itself.
            var hasChildMatch = false;
            for (var j = 0; j < el.children.length; j++) {
              var c = el.children[j];
              if (c && c.textContent && c.textContent.toLowerCase().indexOf(needle) !== -1) {
                hasChildMatch = true;
                break;
              }
            }
            if (!hasChildMatch) return el;
          }
          return null;
        }

        function extractMetric(needle) {
          var label = findLabel(needle);
          if (!label) return null;

          // Walk up to find a container that also contains a percent token.
          var container = label;
          var match = null;
          for (var k = 0; k < 8 && container; k++) {
            var txt = container.textContent || '';
            var m = txt.match(percentRe);
            if (m) { match = m; break; }
            container = container.parentElement;
          }
          if (!match || !container) return null;

          var pct = parseInt(match[1], 10);
          if (isNaN(pct)) return null;
          if (pct < 0) pct = 0;
          if (pct > 100) pct = 100;

          var containerText = container.textContent || '';
          var resetIdx = containerText.search(resetStartRe);
          var resetText = null;
          if (resetIdx >= 0) {
            var rest = containerText.slice(resetIdx);
            // Truncate before the next "<digits>%" token or newline so we
            // don't slurp the next metric's text or trailing "NN% used".
            // Also cap absolute length to 80 chars as a defensive bound.
            var stopIdx = rest.search(resetStopRe);
            var slice = stopIdx > 0 ? rest.slice(0, stopIdx) : rest;
            if (slice.length > 80) slice = slice.slice(0, 80);
            resetText = slice.replace(/\\s+/g, ' ').trim();
          }

          return { percent: pct, resetText: resetText };
        }

        var current = extractMetric('current session');
        var weeklyAll = extractMetric('all models');
        var weeklySonnet = extractMetric('sonnet only');

        if (!current && !weeklyAll && !weeklySonnet) return null;

        return JSON.stringify({
          current: current,
          weeklyAll: weeklyAll,
          weeklySonnet: weeklySonnet
        });
      } catch (e) {
        return null;
      }
    })();
    """

    // MARK: - State

    private let store: UsageStore
    private let webView: WKWebView
    private var timer: Timer?
    private var isRefreshing = false

    /// Resumed by `webView(_:didFinish:)` / `webView(_:didFail:withError:)`.
    private var navigationContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Init

    init(store: UsageStore) {
        self.store = store

        let config = WKWebViewConfiguration()
        // Share cookies with LoginView so login persists across launches.
        config.websiteDataStore = WKWebsiteDataStore.default()

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1),
                           configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
        self.webView = wv

        super.init()
        self.webView.navigationDelegate = self
    }

    // MARK: - Public API

    /// Starts the periodic refresh timer and triggers an immediate refresh.
    func start() {
        stop()
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        // .common modes so the timer survives menu tracking / modal runloops.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t

        Task { @MainActor in
            await self.refresh()
        }
    }

    /// Stops the periodic refresh timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Performs a single scrape round. Safe to call from a Task; guarded
    /// against overlapping calls.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await loadUsagePage()

        // If navigation landed on /login, mark logged-out and bail out cleanly.
        if let url = webView.url, url.path.contains("/login") {
            store.isLoggedIn = false
            store.lastUpdated = Date()
            return
        }

        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            // Re-check login redirect on every poll iteration.
            if let url = webView.url, url.path.contains("/login") {
                store.isLoggedIn = false
                store.lastUpdated = Date()
                return
            }

            if let result = await evaluateScrape() {
                applyScrapeResult(result)
                store.isLoggedIn = true
                store.lastUpdated = Date()
                store.lastError = nil
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }

        // Timed out without seeing the expected DOM. Keep previous values but
        // record the timestamp and a soft error so the UI can surface it.
        store.lastUpdated = Date()
        store.lastError = "Could not find usage info on page."
    }

    // MARK: - Internals

    /// Loads the hardcoded usage URL and awaits navigation completion.
    private func loadUsagePage() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Replace any in-flight continuation so we never leak one.
            if let pending = self.navigationContinuation {
                self.navigationContinuation = nil
                pending.resume()
            }
            self.navigationContinuation = cont

            let request = URLRequest(url: Self.usageURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 30)
            self.webView.load(request)
        }
    }

    /// One parsed metric row from the scrape JSON.
    private struct Metric {
        let percent: Double
        let resetText: String?
    }

    /// All three metrics returned by a single scrape pass. Any field may be
    /// `nil` when that row was not present on the page.
    private struct ScrapeResult {
        let current: Metric?
        let weeklyAll: Metric?
        let weeklySonnet: Metric?

        var hasAnyMetric: Bool {
            current != nil || weeklyAll != nil || weeklySonnet != nil
        }
    }

    /// Runs the static scraping script once. Returns `nil` if the DOM isn't
    /// ready or the script returned `null` / an unexpected shape.
    private func evaluateScrape() async -> ScrapeResult? {
        await withCheckedContinuation { (cont: CheckedContinuation<ScrapeResult?, Never>) in
            self.webView.evaluateJavaScript(Self.scrapeJS) { value, _ in
                guard let str = value as? String,
                      let data = str.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    cont.resume(returning: nil)
                    return
                }

                func parseMetric(_ key: String) -> Metric? {
                    guard let dict = json[key] as? [String: Any] else { return nil }
                    let pct: Double?
                    if let n = dict["percent"] as? Double { pct = n }
                    else if let n = dict["percent"] as? Int { pct = Double(n) }
                    else if let n = dict["percent"] as? NSNumber { pct = n.doubleValue }
                    else { pct = nil }
                    guard let percent = pct else { return nil }
                    let resetText = dict["resetText"] as? String
                    return Metric(percent: percent, resetText: resetText)
                }

                let result = ScrapeResult(
                    current: parseMetric("current"),
                    weeklyAll: parseMetric("weeklyAll"),
                    weeklySonnet: parseMetric("weeklySonnet")
                )

                guard result.hasAnyMetric else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: result)
            }
        }
    }

    private func applyScrapeResult(_ result: ScrapeResult) {
        if let m = result.current {
            store.sessionPercent = max(0, min(100, m.percent))
            store.resetText = m.resetText
        } else {
            store.sessionPercent = nil
            store.resetText = nil
        }
        if let m = result.weeklyAll {
            store.weeklyAllModelsPercent = max(0, min(100, m.percent))
            store.weeklyAllModelsResetText = m.resetText
        } else {
            store.weeklyAllModelsPercent = nil
            store.weeklyAllModelsResetText = nil
        }
        if let m = result.weeklySonnet {
            store.weeklySonnetPercent = max(0, min(100, m.percent))
            store.weeklySonnetResetText = m.resetText
        } else {
            store.weeklySonnetPercent = nil
            store.weeklySonnetResetText = nil
        }
    }

    // MARK: - WKNavigationDelegate

    /// Restrict navigation to claude.ai hosts only.
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // about:blank is benign and produced internally; allow it.
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        let host = url.host?.lowercased() ?? ""
        let allowed = host == Self.allowedHost || host.hasSuffix("." + Self.allowedHost)
        decisionHandler(allowed ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.resumeNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.resumeNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.resumeNavigation()
        }
    }

    private func resumeNavigation() {
        guard let cont = navigationContinuation else { return }
        navigationContinuation = nil
        cont.resume()
    }
}
