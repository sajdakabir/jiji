import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Single source of truth for usage state. Created eagerly so both the
    /// SwiftUI scene and the scraper share the exact same instance.
    let store = UsageStore()

    /// Strongly retained scraper that owns the hidden WKWebView and the 60s timer.
    /// Created once in `applicationDidFinishLaunching` and never reassigned.
    private(set) var scraper: UsageScraper!

    /// Strongly retained login window so it stays alive while the user signs in.
    var loginWindow: NSWindow?

    /// Combine cancellables (e.g. login-state observer).
    private var cancellables = Set<AnyCancellable>()

    /// Switch to accessory before AppKit finishes launching to avoid a Dock
    /// icon flash on first launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the scraper bound to the shared store and kick off polling.
        let scraper = UsageScraper(store: store)
        self.scraper = scraper
        scraper.start()

        // Re-present the login window whenever the store flips to logged-out
        // (e.g. cookie expiry, server-side logout detected by the scraper).
        store.$isLoggedIn
            .removeDuplicates()
            .dropFirst() // ignore the initial `true` default
            .sink { [weak self] loggedIn in
                guard let self = self else { return }
                if !loggedIn {
                    self.presentLoginWindow()
                }
            }
            .store(in: &cancellables)

        // If no claude.ai cookie is present yet, prompt the user to log in.
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let hasClaudeCookie = cookies.contains { cookie in
                let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == "claude.ai" || host.hasSuffix(".claude.ai")
            }
            if !hasClaudeCookie {
                DispatchQueue.main.async {
                    self?.presentLoginWindow()
                }
            }
        }
    }

    func presentLoginWindow() {
        // MARK: - Activation policy bump
        // LSUIElement / .accessory apps are non-activating, so NSApp.activate
        // does NOT reliably make a regular NSWindow key — clicks and key events
        // get silently dropped by the WKWebView. Temporarily promote to .regular
        // while the login window is up, then drop back to .accessory in
        // dismissLoginWindow() so the menu-bar-only UX is preserved.
        NSApp.setActivationPolicy(.regular)

        // If a login window is already up, just bring it forward.
        if let existing = loginWindow {
            existing.level = .normal
            existing.collectionBehavior.insert(.moveToActiveSpace)
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.center()
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)

        let root = LoginView(onLoginComplete: { [weak self] in
            self?.dismissLoginWindow()
        })
        .environmentObject(store)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hosting

        // Activate first, then order front, so the window becomes key on the
        // accessory→regular transition.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Seed the responder chain with the hosting view immediately; once
        // SwiftUI mounts the WKWebView we promote it to first responder so the
        // email field receives keystrokes without requiring a click.
        window.makeFirstResponder(hosting)

        DispatchQueue.main.async { [weak window] in
            guard let window = window,
                  let webView = window.contentView?.findDescendant(of: WKWebView.self) else { return }
            window.initialFirstResponder = webView
            window.makeFirstResponder(webView)
        }

        self.loginWindow = window
    }

    func dismissLoginWindow() {
        loginWindow?.orderOut(nil)
        loginWindow = nil
        // Restore menu-bar-only UX now that the login window is gone.
        NSApp.setActivationPolicy(.accessory)
        // Kick off a refresh now that we may have a session.
        if let scraper = scraper {
            Task { await scraper.refresh() }
        }
    }
}

// MARK: - NSView descendant search

extension NSView {
    /// Recursively walks the subview tree looking for the first descendant of
    /// the given type. Used to locate the embedded WKWebView inside an
    /// NSHostingView so it can be made the window's first responder.
    func findDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.findDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
