import Observation
import SwiftUI

@MainActor @Observable
final class LockModel {
    static let shared = LockModel()
    var unlocked = false
}

/// Screen lock as a live activity: a padlock while locked; on unlock the shackle swings
/// open and the island collapses 475 ms later (same timing as the web demo).
@MainActor
enum LockMonitor {
    static let activityID = "system.lock"

    static func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockMonitor.locked() }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LockMonitor.unlocked() }
        }
    }

    static func locked() {
        if Preferences.shared.lockSound { Sounds.lock() }
        guard SystemPreferences.shared.lockActivity else { return }
        LockModel.shared.unlocked = false
        Island.shared.start(item())
    }

    static func unlocked() {
        if Preferences.shared.unlockSound { Sounds.unlock() }
        guard Island.shared.isRunning(activityID) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { LockModel.shared.unlocked = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.475) { Island.shared.end(activityID) }
    }

    /// `unlocked` pins the glyph state for gallery snapshots.
    static func item(unlocked: Bool? = nil) -> IslandItem {
        IslandItem(id: activityID, kind: .liveActivity, priority: 100) {
            LockWing(unlocked: unlocked).padding(.leading, 10)
        } trailing: {
            EmptyView()
        }
    }
}

private struct LockWing: View {
    var unlocked: Bool?
    var body: some View { LockGlyph(unlocked: unlocked ?? LockModel.shared.unlocked) }
}

/// Padlock drawn on a 16-unit grid: on unlock the shackle mirrors around x = 56%
/// (swinging it open to the right) while the body nudges 1 unit left.
struct LockGlyph: View {
    var unlocked: Bool
    var size: CGFloat = 18

    var body: some View {
        let u = size / 16
        ZStack(alignment: .topLeading) {
            Shackle()
                .stroke(style: StrokeStyle(lineWidth: 1.25 * u))
                .scaleEffect(x: unlocked ? -1 : 1, y: 1, anchor: UnitPoint(x: 0.56, y: 0.5))
            RoundedRectangle(cornerRadius: 1.6 * u, style: .continuous)
                .frame(width: 9.33 * u, height: 7.98 * u)
                .offset(x: (3 - (unlocked ? 1 : 0)) * u, y: 6.3 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .foregroundStyle(Palette.ink)
        .animation(.easeInOut(duration: 0.3), value: unlocked)
    }
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 16
        var p = Path()
        p.move(to: CGPoint(x: 4.84 * u, y: 6.86 * u))
        p.addLine(to: CGPoint(x: 4.84 * u, y: 4.6 * u))
        p.addCurve(to: CGPoint(x: 7.665 * u, y: 1.62 * u), control1: CGPoint(x: 4.84 * u, y: 2.65 * u), control2: CGPoint(x: 6.0 * u, y: 1.62 * u))
        p.addCurve(to: CGPoint(x: 10.49 * u, y: 4.6 * u), control1: CGPoint(x: 9.33 * u, y: 1.62 * u), control2: CGPoint(x: 10.49 * u, y: 2.65 * u))
        p.addLine(to: CGPoint(x: 10.49 * u, y: 6.86 * u))
        return p
    }
}
