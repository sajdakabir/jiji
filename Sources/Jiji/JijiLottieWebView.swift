import SwiftUI
import WebKit

/// Plays a Lottie animation (`.lottie` or `.json`) using LottieFiles'
/// `dotlottie-wc` web component inside a `WKWebView`.
///
/// Architecture:
/// - The animation file is read from the bundle and base64-encoded into a
///   `data:` URL — the embedded WebKit page never sees a `file://` URL,
///   which keeps the sandbox surface tight.
/// - The dotlottie-wc script is loaded from `unpkg.com` (the canonical
///   CDN for the package). The ATS allowlist in `Info.plist` is narrowed
///   to that one host.
/// - `WKNavigationDelegate.decidePolicyFor` cancels any navigation that
///   isn't `data:`, `about:`, our synthetic `jiji.local` baseURL, or
///   `unpkg.com`. Anything else is silently refused.
struct JijiLottieWebView: NSViewRepresentable {
    /// Local URL of the bundled `.lottie` or `.json` animation.
    let lottieURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Transparent background so the popover surface shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        guard let html = makeHTML(for: lottieURL) else {
            // File missing or unreadable — leave the WebView empty so the
            // caller can decide to fall back to a different view.
            return webView
        }
        webView.loadHTMLString(html, baseURL: Self.baseURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - HTML construction

    /// Synthetic base URL used by `loadHTMLString`. Must NOT be `nil` and
    /// must NOT be `file://` — using a benign HTTPS URL keeps the page
    /// in a "remote" security origin so file:// reads stay denied.
    private static let baseURL = URL(string: "https://jiji.local/")!

    /// Build the HTML page. Returns `nil` if the animation file cannot
    /// be read.
    private func makeHTML(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String = {
            switch url.pathExtension.lowercased() {
            case "lottie": return "application/zip"
            default:       return "application/json"
            }
        }()
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; width: 100%; height: 100%; overflow: hidden; }
          dotlottie-wc { display: block; width: 100%; height: 100%; }
        </style>
        <script src="https://unpkg.com/@lottiefiles/dotlottie-wc@latest/dist/dotlottie-wc.js" type="module"></script>
        </head>
        <body>
        <dotlottie-wc src="\(dataURL)" autoplay loop></dotlottie-wc>
        </body>
        </html>
        """
    }

    // MARK: - Navigation policy

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Only host outside `data:` / `about:` / our synthetic baseURL
        /// that the WebView may reach.
        private static let allowedScriptHost = "unpkg.com"

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Inline data URLs (the lottie animation) and about:blank are
            // benign internal navigations.
            if url.scheme == "data" || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }

            // The synthetic baseURL used by loadHTMLString.
            if url.host == "jiji.local" {
                decisionHandler(.allow)
                return
            }

            // The dotlottie-wc script load. Pinned to unpkg.com only.
            if let host = url.host?.lowercased(),
               host == Self.allowedScriptHost || host.hasSuffix("." + Self.allowedScriptHost) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
