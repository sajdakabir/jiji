import SwiftUI

/// The cat icon, backed by Apple's `cat.fill` SF Symbol. State drives tint
/// (color), tilt, scale, and shake — so the symbol stays recognizable as a
/// cat at all sizes (18pt menu bar through 64pt popover) while still
/// communicating the current `JijiState`.
///
/// A single SF Symbol can't articulate independent legs / tail (that needs
/// sprite frames or a Lottie file). What we get here is whole-body motion:
/// breathing, pulse, shake, tilt, and a tail-rocking rotation pivoted at
/// the rear so the tail end sweeps the widest arc.
struct JijiCat: View {
    enum MotionStyle { case none, subtle, full }

    let state: JijiState
    let size: CGFloat
    var motionStyle: MotionStyle = .none

    /// 0...1 phase driving the gentle breathing/pulse scale used by
    /// `.chill` and `.worried`.
    @State private var pulsePhase: Double = 0

    /// 0/1 toggle that drives a fast linear repeating animation for
    /// the panic shake.
    @State private var shakeToggle: Bool = false

    /// 0...1 phase for the tail-rock rotation. Pivoted at rear-bottom in
    /// `body`, so the tail (top of the silhouette) sweeps the widest arc
    /// while the legs stay planted.
    @State private var wagPhase: Double = 0

    var body: some View {
        Group {
            // In .chill, if the user has dropped a `chill_cat.lottie`
            // (or .json) into Sources/Jiji/Resources/, play it via the
            // dotlottie-wc web component. Otherwise fall through to the
            // SF Symbol cat below so the app still works without assets.
            if state == .chill, let url = Self.chillLottieURL {
                JijiLottieWebView(lottieURL: url)
                    .frame(width: size, height: size)
            } else {
                sfSymbolCat
            }
        }
        .task(id: state) { startAnimations() }
    }

    /// SF Symbol-based fallback (and the body for non-chill states).
    private var sfSymbolCat: some View {
        Image(systemName: "cat.fill")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(state.tint)
            .scaleEffect(idleScale)
            .rotationEffect(.degrees(tailWagAngle),
                            anchor: UnitPoint(x: 0.55, y: 0.95))
            .rotationEffect(.degrees(stateRotation))
            .offset(x: shakeOffset, y: bobOffset)
            .opacity(state == .dead ? 0.55 : 1.0)
    }

    /// Resolves the bundled chill-state Lottie file, if the user dropped
    /// one in. Prefers `.lottie` (compressed) over `.json`. `build-app.sh`
    /// copies anything in `Sources/Jiji/Resources/` into the .app bundle's
    /// Resources directory, where `Bundle.main` can find it.
    private static var chillLottieURL: URL? {
        Bundle.main.url(forResource: "chill_cat", withExtension: "lottie")
            ?? Bundle.main.url(forResource: "chill_cat", withExtension: "json")
    }

    // MARK: - Per-state geometry

    private var stateRotation: Double {
        switch state {
        case .alert:   return 4
        case .sideEye: return -8
        case .dead:    return 90
        default:       return 0
        }
    }

    private var idleScale: CGFloat {
        switch state {
        case .chill:   return 1.0 - (pulsePhase * 0.04)
        case .worried: return 1.0 + (pulsePhase * 0.03)
        default:       return 1.0
        }
    }

    private var shakeOffset: CGFloat {
        guard state == .panic else { return 0 }
        let amplitude = max(0.8, size / 32.0)
        return shakeToggle ? amplitude : -amplitude
    }

    private var tailWagAngle: Double {
        guard state != .dead else { return 0 }
        let amplitude: Double
        switch state {
        case .panic:   amplitude = 10
        case .alert:   amplitude = 6
        case .worried: amplitude = 5
        default:       amplitude = 5
        }
        return (wagPhase * 2 - 1) * amplitude
    }

    /// Subtle vertical bobbing so the cat reads as "trotting in place"
    /// even though the SF Symbol's legs don't articulate. Derived from
    /// `wagPhase` so it's free (no extra timer).
    private var bobOffset: CGFloat {
        guard state != .dead else { return 0 }
        let amplitude: CGFloat = max(0.6, size / 36.0)
        return CGFloat(sin(wagPhase * .pi * 2)) * amplitude
    }

    // MARK: - Animation lifecycle

    private func startAnimations() {
        // Tail-wag rocking — always on except for .dead.
        if state != .dead {
            let wagDuration: Double = (state == .panic) ? 0.45 : 1.6
            wagPhase = 0
            withAnimation(.easeInOut(duration: wagDuration).repeatForever(autoreverses: true)) {
                wagPhase = 1
            }
        } else {
            withTransaction(Transaction(animation: nil)) { wagPhase = 0.5 }
        }

        // State-specific scale/shake animations.
        switch state {
        case .chill:
            pulsePhase = 0
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        case .worried:
            pulsePhase = 0
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        case .panic:
            shakeToggle = false
            withAnimation(.linear(duration: 0.06).repeatForever(autoreverses: true)) {
                shakeToggle = true
            }
        default:
            withTransaction(Transaction(animation: nil)) {
                pulsePhase = 0
                shakeToggle = false
            }
        }
    }
}
