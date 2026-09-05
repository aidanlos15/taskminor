import Foundation

/// Pure decision logic for when to take a screen capture — kept separate so it
/// can be unit-tested without the live engine.
///
/// The rule: capture when the *context changes* (new app/window/tab), or on the
/// periodic interval BUT only if the human actually did something since the last
/// capture. A frozen screen with no input — e.g. left open while away — is never
/// re-captured, so idle time is never described as work.
enum CaptureGate {
    static func shouldCapture(
        now: Date,
        lastCaptureDate: Date,
        lastContext: String,
        currentContext: String,
        floor: TimeInterval,
        interval: TimeInterval,
        idleSeconds: TimeInterval
    ) -> Bool {
        let sinceLast = now.timeIntervalSince(lastCaptureDate)
        // Never faster than the floor.
        guard sinceLast >= floor else { return false }
        // A real context change means the user navigated somewhere — but only if
        // they were actually present (input within the window since last capture).
        let wasActiveSinceLastCapture = idleSeconds < sinceLast
        if currentContext != lastContext {
            return wasActiveSinceLastCapture
        }
        // Same context: only the periodic interval, and only if the user was active.
        return sinceLast >= interval && wasActiveSinceLastCapture
    }
}

/// Pure helpers for idle-session bookkeeping, kept testable outside the engine.
enum IdleMath {
    /// Start of a new idle stretch: when input actually stopped, but never
    /// before the last moment the user was known present (so a new idle stretch
    /// cannot overlap a prior one, or predate launch/sleep).
    static func idleStart(now: Date, idleSeconds: TimeInterval, lastPresentAt: Date) -> Date {
        max(now.addingTimeInterval(-idleSeconds), lastPresentAt)
    }

    /// End of an idle stretch: the actual return moment, clamped to be after the
    /// start and no later than now.
    static func idleEnd(start: Date, returnedAt: Date, now: Date) -> Date {
        min(max(returnedAt, start), now)
    }
}
