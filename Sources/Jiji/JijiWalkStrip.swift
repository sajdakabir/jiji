import SwiftUI

/// A horizontal strip that walks `JijiCat` back and forth, used in the
/// popover header to make the cat feel alive even when `sessionPercent` is
/// steady. The strip stretches to whatever width the parent provides and
/// is `height` tall.
///
/// Behaviour by state:
/// - `.dead`: no walking; cat sits centered, no horizontal flip.
/// - `.panic`: walking is faster, like nervous pacing.
/// - Other live states: a slow easeInOut pace.
///
/// The walking phase is owned by this view so it is independent of any
/// `JijiCat` `@State`; that means tail-wag / blink / look-around continue
/// uninterrupted across direction changes.
struct JijiWalkStrip: View {
    let state: JijiState
    let height: CGFloat

    /// Animation phase in 0...1. Drives the horizontal position via the
    /// strip's `GeometryReader` width.
    @State private var walkPhase: Double = 0

    /// `true` when the cat is moving leftwards, so we flip horizontally.
    /// Computed from `walkPhase` rather than stored separately so it is
    /// always consistent with the rendered position.
    private var facingLeft: Bool { walkPhase < 0.5 }

    /// Walking duration for one half-cycle (autoreverses, so a full
    /// round-trip is 2x this). Pacing is faster in `.panic`.
    private var walkDuration: Double {
        switch state {
        case .panic: return 1.5
        default:     return 7.0
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let stripWidth = proxy.size.width
            let catSize = height * 0.9
            // Leave the cat fully inside the strip even at the extremes.
            let travel = max(0, stripWidth - catSize)
            // Tiny vertical bounce, derived from walkPhase so we don't need
            // a second timer. sin(2 pi t) gives one bounce per half-swing.
            let bounceY = sin(walkPhase * .pi * 2) * (height * 0.03)
            // Flip horizontally based on direction of travel; in `.dead`
            // the cat stays upright and centered.
            let flip: CGFloat = (state == .dead) ? 1 : (facingLeft ? -1 : 1)
            let x: CGFloat = (state == .dead) ? (travel / 2) : (travel * walkPhase)

            JijiCat(state: state, size: catSize, motionStyle: .full)
                .frame(width: catSize, height: catSize)
                .scaleEffect(x: flip, y: 1, anchor: .center)
                .offset(x: x, y: bounceY)
                // Vertically center the cat inside the strip so the
                // bounce swings symmetrically around the strip midline
                // and the cat does not appear pinned to the top edge.
                .frame(width: stripWidth, height: height, alignment: .leading)
        }
        .frame(height: height)
        // Clip so the bounce / panic-shake / scale transforms cannot
        // render the cat outside the strip rectangle (into the popover
        // padding above or the caption below).
        .clipped()
        .task(id: walkAnimationKey) {
            // Only animate when the cat should be walking. In `.dead` the
            // cat is centered (set above) and we don't drive walkPhase.
            guard state != .dead else { return }
            // Re-arm a smooth repeating ease in/out animation without
            // resetting `walkPhase`: snapping back to 0 here would cause
            // a jarring jump from wherever the cat currently is (e.g.
            // mid-strip) to the leftmost position on every panic <->
            // calm transition. Instead, retarget to the nearer endpoint
            // (0 or 1) so the existing position smoothly tweens into the
            // new pace.
            // `.task` already runs on the MainActor for a View body, so
            // no explicit `MainActor.run` hop is required.
            let target: Double = walkPhase < 0.5 ? 1 : 0
            withAnimation(.easeInOut(duration: walkDuration)
                .repeatForever(autoreverses: true)) {
                walkPhase = target
            }
        }
    }

    /// Key used to restart the walking animation when the pace changes
    /// (state transitions in/out of `.panic`) without resetting on every
    /// unrelated re-render.
    private var walkAnimationKey: String {
        switch state {
        case .dead:  return "dead"
        case .panic: return "panic"
        default:     return "calm"
        }
    }
}
