import Foundation
import Observation

/// Countdown timer started from the expanded calendar (or `isolactl timer.start`).
@MainActor @Observable
final class CalendarTimer {
    static let shared = CalendarTimer()
    private(set) var end: Date?
    private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var ticker: Timer?

    var snapshot: TimerSnapshot? { end.map { TimerSnapshot(end: $0, duration: duration) } }

    func start(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        ticker?.invalidate()
        duration = seconds
        end = Date().addingTimeInterval(seconds)
        ticker = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { CalendarTimer.shared.finish() }
        }
        Island.shared.start(CalendarItems.timer())
    }

    func stop() {
        ticker?.invalidate()
        end = nil
        Island.shared.end(CalendarItems.timerID)
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
    func remaining(at date: Date) -> TimeInterval { max(0, end.timeIntervalSince(date)) }
    func progress(at date: Date) -> Double { duration > 0 ? remaining(at: date) / duration : 0 }
}
