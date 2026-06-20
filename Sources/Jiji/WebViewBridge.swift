import SwiftUI
import WebKit

/// SwiftUI wrapper around a WKWebView used by LoginView. Cookies are stored in
/// WKWebsiteDataStore.default() so they are shared with UsageScraper. Navigation
/// is restricted to claude.ai hosts only.
struct WebViewBridge: NSViewRepresentable {
    let url: URL
    let onCookieDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookieDetected: onCookieDetected)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persist cookies in the same default store the scraper reads from.
        config.websiteDataStore = WKWebsiteDataStore.default()

        // Use a non-zero initial frame so WKWebView's tracking areas /
        // hit-test rect register correctly on first appearance; with frame:.zero
        // clicks sometimes land on the SwiftUI host view instead of web content.
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 600),
            configuration: config
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.autoresizingMask = [.width, .height]
        // Identify as Safari so claude.ai serves the regular login page rather
        // than fingerprinting the bare WKWebView and refusing to render.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))

        // Force the WKWebView to first responder once it has been attached to
        // a window so the email field receives keystrokes without requiring
        // an initial click.
        DispatchQueue.main.async { [weak webView] in
            guard let webView = webView, let window = webView.window else { return }
            window.makeFirstResponder(webView)
        }

        context.coordinator.startCookiePolling()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op: the URL is set once at creation time.
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopCookiePolling()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookieDetected: () -> Void
        private var cookieTimer: Timer?
        private var fired = false

        /// Weakly retained reference to the hosting web view so the cookie
        /// poller can confirm the user has navigated off `/login` before
        /// declaring the session valid.
        weak var webView: WKWebView?

        init(onCookieDetected: @escaping () -> Void) {
            self.onCookieDetected = onCookieDetected
        }

        deinit {
            cookieTimer?.invalidate()
        }

        // MARK: Navigation allowlist

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Allow subframe loads (recaptcha, cloudflare turnstile, gstatic,
            // analytics iframes embedded in the login page). The host allowlist
            // is enforced on main-frame navigations only — without this the
            // page's JS event handlers can bail out when their subframes are
            // cancelled, manifesting as "clicks do nothing".
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }

            // Allow about:blank / data URLs used internally.
            if url.scheme == "about" || url.scheme == "data" {
                decisionHandler(.allow)
                return
            }

            guard let host = url.host?.lowercased() else {
                decisionHandler(.cancel)
                return
            }

            if host == "claude.ai" || host.hasSuffix(".claude.ai") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        // MARK: Failure logging — so a silent white screen doesn't recur.

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            FileHandle.standardError.write(Data("[Jiji] login webview didFail: \(error.localizedDescription)\n".utf8))
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            FileHandle.standardError.write(Data("[Jiji] login webview didFailProvisionalNavigation: \(error.localizedDescription)\n".utf8))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            FileHandle.standardError.write(Data("[Jiji] login webview WebContent process terminated; reloading.\n".utf8))
            webView.reload()
        }

        // MARK: Cookie polling

        func startCookiePolling() {
            stopCookiePolling()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkForSessionCookie()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.cookieTimer = timer
            // Run an immediate check so a pre-existing cookie is caught fast.
            checkForSessionCookie()
        }

        func stopCookiePolling() {
            cookieTimer?.invalidate()
            cookieTimer = nil
        }

        /// Known claude.ai post-login session cookie names. Pre-login pages set
        /// `__Secure-` / `__Host-` prefixed CSRF and analytics cookies almost
        /// immediately on first load, so a generic prefix match would fire
        /// before the user has actually signed in. Restrict detection to the
        /// concrete session-key names Anthropic ships on the logged-in surface.
        private static let knownSessionCookieNames: Set<String> = [
            "sessionkey",
            "sessionKey".lowercased(),
            "lastactiveorg",
            "anthropic-device-id",
            "user-sess"
        ]

        private func checkForSessionCookie() {
            guard !fired else { return }

            // Require the user to have navigated off `/login` before we
            // consider the session valid. This guards against false positives
            // from pre-login `__Secure-`/`__Host-` cookies that claude.ai sets
            // on the login page itself.
            let path = webView?.url?.path.lowercased() ?? ""
            let stillOnLoginPage = path.isEmpty || path.contains("/login")

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.fired else { return }

                let hasSession = cookies.contains { cookie in
                    let rawHost = cookie.domain.hasPrefix(".")
                        ? String(cookie.domain.dropFirst())
                        : cookie.domain
                    let host = rawHost.lowercased()
                    let isClaudeHost = host == "claude.ai" || host.hasSuffix(".claude.ai")
                    guard isClaudeHost else { return false }
                    guard !cookie.value.isEmpty else { return false }

                    let name = cookie.name.lowercased()
                    return Self.knownSessionCookieNames.contains(name)
                }

                // Only declare success once BOTH a known session cookie is
                // present AND the user has navigated away from /login.
                if hasSession && !stillOnLoginPage {
                    self.fired = true
                    DispatchQueue.main.async {
                        self.stopCookiePolling()
                        self.onCookieDetected()
                    }
                }
            }
        }
    }
}
