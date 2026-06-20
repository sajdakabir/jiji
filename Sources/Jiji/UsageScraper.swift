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
    /// Returns `JSON.stringify({percent: number, resetText: string|null})` on
    /// success, or `null` while the page hasn't rendered the expected row yet.
    private static let scrapeJS: String = """
    (function() {
      try {
        var needle = 'current session';
        var all = document.querySelectorAll('body *');
        var label = null;
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (!el || !el.textContent) continue;
          var t = el.textContent.toLowerCase();
          if (t.indexOf(needle) === -1) continue;
          // Prefer the deepest element that contains the needle to avoid the <body>.
          var hasChildMatch = false;
          for (var j = 0; j < el.children.length; j++) {
            var c = el.children[j];
            if (c && c.textContent && c.textContent.toLowerCase().indexOf(needle) !== -1) {
              hasChildMatch = true;
              break;
            }
          }
          if (!hasChildMatch) { label = el; break; }
        }
        if (!label) return null;

        // Walk up looking for a container that also holds a percent token.
        var percentRe = /(\\d{1,3})\\s*%/;

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
        var resetIdx = containerText.search(/resets?\\s/i);
        var resetText = null;
        if (resetIdx >= 0) {
          var rest = containerText.slice(resetIdx);
          // Stop before the next "<digits>%" token or any newline so we don't
          // slurp trailing "NN% used" text that follows the reset descriptor.
          var stopIdx = rest.search(/\\d{1,3}\\s*%|[\\n\\r]/);
          resetText = (stopIdx > 0 ? rest.slice(0, stopIdx) : rest).replace(/\\s+/g, ' ').trim();
        }

        return JSON.stringify({ percent: pct, resetText: resetText });
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

    /// Runs the static scraping script once. Returns `nil` if the DOM isn't
    /// ready or the script returned `null` / an unexpected shape.
    private func evaluateScrape() async -> (percent: Double, resetText: String?)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(percent: Double, resetText: String?)?, Never>) in
            self.webView.evaluateJavaScript(Self.scrapeJS) { value, _ in
                guard let str = value as? String,
                      let data = str.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    cont.resume(returning: nil)
                    return
                }
                let pct: Double?
                if let n = json["percent"] as? Double { pct = n }
                else if let n = json["percent"] as? Int { pct = Double(n) }
                else if let n = json["percent"] as? NSNumber { pct = n.doubleValue }
                else { pct = nil }

                guard let percent = pct else {
                    cont.resume(returning: nil)
                    return
                }
                let resetText = json["resetText"] as? String
                cont.resume(returning: (percent, resetText))
            }
        }
    }

    private func applyScrapeResult(_ result: (percent: Double, resetText: String?)) {
        store.sessionPercent = max(0, min(100, result.percent))
        store.resetText = result.resetText
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
