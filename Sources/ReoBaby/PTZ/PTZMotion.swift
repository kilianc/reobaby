import Foundation

/// How a camera's motor behaves, learned as it moves. Used by one move at a time.
final class PTZTuning: @unchecked Sendable {
    /// Camera units a second, pan or tilt.
    var speed = 1200.0
    /// How far the camera turns after it is asked to stop.
    var coast = 190.0
    /// From asking to move until the motor turns: a stop sooner than this cancels the move.
    var startLag = 0.03
}

/// Drives pan and tilt to a position, as closely as the camera's motor allows.
///
/// A Reolink camera only knows "start moving" and "stop": it turns at one speed, about 60° a
/// second, and takes anywhere from 0.1 to 0.9 s to act on a command. So a move can't be timed
/// to a fraction of a degree. What the camera does do exactly is say where it points. A move is
/// therefore a run stopped a little early, then short pulses towards the target, reading the
/// position after each, until it is within the tolerance.
extension PTZDevice {
    /// Stops twice, on separate connections: a camera sometimes takes most of a second over a
    /// command, and turns 60° in that second. `sure` also stops over the camera's other API, for
    /// the end of a long run, where a lost stop means turning to the end stop.
    func ptzStopNow(sure: Bool = false) async {
        async let first: Void? = try? ptzStop()
        async let other: Void? = sure ? try? (self as? CameraAPI)?.ptzStop(viaHTTP: true) : ()
        try? await Task.sleep(nanoseconds: 40_000_000)
        async let second: Void? = try? ptzStop()
        _ = await (first, other, second)
    }

    /// A start, then a stop `hold` seconds later. How far the camera goes is its own call:
    /// nothing, or a degree or two, now and then more.
    func ptzPulse(_ direction: PTZDirection, hold: Double) async {
        async let move: Void? = try? ptzMove(direction)
        try? await Task.sleep(nanoseconds: UInt64(max(hold, 0) * 1_000_000_000))
        await ptzStopNow()
        _ = await move
    }

    /// The position once it has stopped changing: the same twice in a row.
    func ptzSettled(_ progress: (@Sendable (PTZPosition) -> Void)? = nil) async throws -> PTZPosition {
        var last = try await ptzPosition()
        progress?(last)
        while true {
            try await Task.sleep(nanoseconds: 90_000_000)
            let now = try await ptzPosition()
            progress?(now)
            if now == last { return now }
            last = now
        }
    }

    /// Chases `target` until the camera is within `tolerance` of it. The target may change on
    /// the way, as when a scale is dragged; nil stops the chase. Returns where the camera ended up.
    /// Cancelling stops the camera.
    @discardableResult
    func ptzChase(target: @escaping @Sendable () -> PTZPosition?, tolerance: @escaping @Sendable () -> PTZPosition,
                  tuning: PTZTuning, attempts: Int = 16,
                  progress: (@Sendable (PTZPosition) -> Void)? = nil) async throws -> PTZPosition {
        var position = try await ptzSettled(progress)
        do {
            for attempt in 0..<attempts {
                try Task.checkCancellation()
                guard let goal = target() else { break }
                // About one stop in ten takes effect late and the camera overshoots, whatever the
                // pulse. After a few misses, settle for a little less, rather than hunt for long.
                let loosen = pow(1.5, Double(max(attempt - 4, 0) / 4))
                let base = tolerance()
                let tol = PTZPosition(pan: Int(Double(base.pan) * loosen), tilt: Int(Double(base.tilt) * loosen))
                let pan = goal.pan - position.pan, tilt = goal.tilt - position.tilt
                let panOff = abs(pan) > tol.pan, tiltOff = abs(tilt) > tol.tilt
                guard panOff || tiltOff else { break }

                let long = tuning.speed * 0.35
                let before = position
                if Double(abs(pan)) > long || Double(abs(tilt)) > long {
                    // The axis with further to go first.
                    let usePan = abs(pan) >= abs(tilt)
                    let direction: PTZDirection = usePan ? (pan > 0 ? .right : .left) : (tilt > 0 ? .up : .down)
                    let reachedStop = try await run(direction, from: position, target: target, tuning: tuning, progress: progress)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    position = try await ptzSettled(progress)
                    // Coasted further than expected: stop sooner next time; and the other way round.
                    if reachedStop, let goal = target() {
                        let overshoot = usePan ? (position.pan - goal.pan) * pan.signum() : (position.tilt - goal.tilt) * tilt.signum()
                        tuning.coast = min(max(tuning.coast + Double(overshoot) * 0.5, 40), 600)
                    }
                } else {
                    // The axis that is further off, in tolerances.
                    let usePan = panOff && (!tiltOff || abs(pan) * max(tol.tilt, 1) >= abs(tilt) * max(tol.pan, 1))
                    let distance = Double(abs(usePan ? pan : tilt))
                    let direction: PTZDirection = usePan ? (pan > 0 ? .right : .left) : (tilt > 0 ? .up : .down)
                    try Task.checkCancellation()
                    await ptzPulse(direction, hold: tuning.startLag + distance / tuning.speed * 0.8)
                    // The motor slows down for a moment after the stop.
                    try await Task.sleep(nanoseconds: 120_000_000)
                    position = try await ptzSettled(progress)
                    let moved = Double(abs(usePan ? position.pan - before.pan : position.tilt - before.tilt))
                    // A pulse that didn't move the camera was too short for its motor to start.
                    if moved == 0 { tuning.startLag = min(tuning.startLag + 0.015, 0.2) }
                    if moved > distance * 2 && moved > 40 { tuning.startLag = max(tuning.startLag - 0.015, 0) }
                }
            }
        } catch {
            await ptzStopNow(sure: true)
            throw error
        }
        return position
    }

    /// Starts moving, watches the position, and stops early by the distance the camera coasts.
    /// Returns whether it stopped for having reached the target, rather than for a target change or timeout.
    private func run(_ direction: PTZDirection, from start: PTZPosition, target: () -> PTZPosition?, tuning: PTZTuning,
                     progress: (@Sendable (PTZPosition) -> Void)?) async throws -> Bool {
        let panSign = direction.pan, tiltSign = direction.tilt
        guard let first = target() else { return false }
        let far = max(abs(first.pan - start.pan) * abs(panSign), abs(first.tilt - start.tilt) * abs(tiltSign))
        try await ptzMove(direction)
        var reached = false
        // However the readings go, never run longer than the distance takes.
        let deadline = Date().addingTimeInterval(Double(far) / tuning.speed + 0.6)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                let asked = Date()
                let now = try await ptzPosition()
                progress?(now)
                guard let goal = target() else { break }
                // The reading is from some time during the request: call it the middle.
                let ahead = Date().timeIntervalSince(asked) / 2 * tuning.speed + tuning.coast
                var left = Double.infinity
                if panSign != 0 { left = min(left, Double((goal.pan - now.pan) * panSign) - ahead) }
                if tiltSign != 0 { left = min(left, Double((goal.tilt - now.tilt) * tiltSign) - ahead) }
                if left <= 0 {
                    reached = true
                    break
                }
                let time = left / tuning.speed
                if time < 0.25 {
                    try await Task.sleep(nanoseconds: UInt64(time * 1_000_000_000))
                    reached = true
                    break
                }
            }
        } catch {
            await ptzStopNow(sure: true)
            throw error
        }
        await ptzStopNow(sure: true)
        return reached
    }
}
