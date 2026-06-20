import SwiftUI

@main
struct JijiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate)
        } label: {
            // Observe the same store the AppDelegate owns so the icon updates.
            MenuBarIconLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Tiny view that observes the shared UsageStore so the MenuBarExtra label
/// re-renders whenever `state` changes. Without this `@ObservedObject`, the
/// label closure would not subscribe to store updates.
private struct MenuBarIconLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        JijiCat(size: 18)
    }
}
