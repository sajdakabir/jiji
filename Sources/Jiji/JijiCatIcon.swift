import SwiftUI

/// Menu bar variant of `JijiCat`, sized to the standard 18pt menu bar slot.
/// At this size the underlying proportional drawing still renders as a
/// recognizable big-eyed black cat silhouette.
struct JijiCatIcon: View {
    let state: JijiState

    /// Tracks pointer hover over the menu bar item so the cat can "jump"
    /// (scale up + lift) when the user mouses over it. `onHover` works on
    /// SwiftUI views inside MenuBarExtra labels even though the menu bar
    /// item itself isn't a regular view.
    @State private var hovering: Bool = false

    var body: some View {
        JijiCat(state: state, size: 18, motionStyle: .subtle)
            .frame(width: 18, height: 18)
            // Hover jump — scale up and lift slightly. Spring animation
            // gives the lift a natural settle.
            .scaleEffect(hovering ? 1.18 : 1.0)
            .offset(y: hovering ? -2 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hovering)
            .onHover { hovering = $0 }
    }
}
