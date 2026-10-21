import AppKit

/// Where the island lives on one screen: around the hardware notch, or a simulated
/// notch / floating pill on notchless displays. Proportions follow the web demo,
/// whose 40pt-tall island is 112 wide idle, 186 with an activity and 72 tall when peeking.
struct NotchGeometry: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var height: CGFloat
    /// Flush with the top edge (hardware or simulated notch) rather than a floating pill.
    var attached: Bool

    @MainActor static func of(_ screen: NSScreen) -> NotchGeometry {
        let p = Preferences.shared
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - l.width - r.width + p.widthTweak
            return .init(hasNotch: true, notchWidth: width, height: screen.safeAreaInsets.top + p.heightTweak, attached: true)
        }
        let h = 36 + p.heightTweak
        return .init(hasNotch: false, notchWidth: h * 2.8 + p.widthTweak, height: h, attached: p.simulatedNotch)
    }

    /// Width of each side wing that hosts activity content.
    var side: CGFloat { height * 0.925 }
    var compact: CGSize { CGSize(width: notchWidth, height: height) }
    var activity: CGSize { CGSize(width: notchWidth + side * 2, height: height) }
    var peek: CGSize { CGSize(width: notchWidth + side * 2, height: height * 1.8) }
    var radius: CGFloat { height * 0.3 }
    /// Gap above a floating pill.
    var topMargin: CGFloat { attached ? 0 : 6 }
}
