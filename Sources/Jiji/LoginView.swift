import SwiftUI

struct LoginView: View {
    @EnvironmentObject var store: UsageStore

    /// Closure invoked when a claude.ai session cookie is detected so the
    /// owning AppDelegate can close the hosting NSWindow.
    let onLoginComplete: () -> Void

    /// Hardcoded login URL. Never built from user input.
    private static let loginURL = URL(string: "https://claude.ai/login")!

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to claude.ai")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            WebViewBridge(
                url: Self.loginURL,
                onCookieDetected: {
                    store.isLoggedIn = true
                    onLoginComplete()
                }
            )
            .frame(minWidth: 480, minHeight: 600)
        }
    }
}
