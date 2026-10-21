import SwiftUI

/// Island springs. Same physics as the web demo (Motion springs, mass 1), so the
/// Mac app and the site move identically.
@MainActor
enum Springs {
    static func spring(_ stiffness: Double, _ damping: Double) -> Animation {
        let p = Preferences.shared
        // "No overshoot" swaps in a critically damped spring of the same stiffness.
        let d = p.overshoot ? damping : max(damping, 2 * stiffness.squareRoot())
        return .interpolatingSpring(mass: 1, stiffness: stiffness * p.speed.factor, damping: d * p.speed.factor.squareRoot())
    }

    static var expand: Animation { spring(150, 20) }
    static var collapseNotification: Animation { spring(150, 16) }
    static var collapseActivity: Animation { spring(175, 17.5) }
    static var peekIn: Animation { spring(250, 21) }
    static var peekOut: Animation { spring(250, 25) }
    static var hoverIn: Animation { spring(250, 14) }
    static var hoverOut: Animation { spring(200, 20) }
    static var press: Animation { spring(160, 18) }
    static var openPanel: Animation { spring(190, 22) }
}

enum AnimationSpeed: String, CaseIterable, Identifiable {
    case smooth, fast, instant
    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .smooth: 1
        case .fast: 1.8
        case .instant: 6
        }
    }
}
