import Foundation
import Observation

/// Countdown timer started from the expanded calendar (or `isolactl timer.start`).
@MainActor @Observable
final class CalendarTimer {
    static let shared = CalendarTimer()
    private(set) var end: Date?
    private(set) var duration: TimeInterval = 0
    /// Seconds left while paused.
    private(set) var paused: TimeInterval?
    @ObservationIgnored private var ticker: Timer?

    var snapshot: TimerSnapshot? { end.map { TimerSnapshot(end: $0, duration: duration, paused: paused) } }

    func start(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        duration = seconds
        paused = nil
        end = Date().addingTimeInterval(seconds)
        schedule(seconds)
        Island.shared.start(CalendarItems.timer())
    }

    /// Option-click on the timer: freeze the countdown, or pick it up where it stopped.
    func togglePause() {
        guard let end else { return }
        if let left = paused {
            paused = nil
            self.end = Date().addingTimeInterval(left)
            schedule(left)
        } else {
            ticker?.invalidate()
            paused = max(0, end.timeIntervalSinceNow)
        }
    }

    func stop() {
        ticker?.invalidate()
        end = nil
        paused = nil
        Island.shared.end(CalendarItems.timerID)
    }

    private func schedule(_ seconds: TimeInterval) {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { CalendarTimer.shared.finish() }
        }
    }

    private func finish() {
        stop()
        Sounds.play("Glass")
        Island.shared.post(CalendarItems.timerDone(), duration: 5)
    }
}

/// Value copy of a running timer, so views can be rendered from fixed data (gallery).
struct TimerSnapshot {
    var end: Date
    var duration: TimeInterval
    var paused: TimeInterval? = nil
    func remaining(at date: Date) -> TimeInterval { paused ?? max(0, end.timeIntervalSince(date)) }
    func progress(at date: Date) -> Double { duration > 0 ? remaining(at: date) / duration : 0 }
}
