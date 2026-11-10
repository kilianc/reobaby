import Foundation

/// A pretend E1 Zoom for demos and testing without a camera (`REOBABY_PTZ_DEMO=1`): it turns
/// at the same speed, takes as long to answer, and zooms as slowly.
final class PTZSimulator: PTZDevice, @unchecked Sendable {
    private struct Motor {
        var pan = 3000.0, tilt = 420.0, zoom = 6.0
        var direction: (pan: Double, tilt: Double) = (0, 0)
        var zoomGoal = 6.0
        var goal: (pan: Double, tilt: Double)?
        var updated = Date()
    }

    private let lock = NSLock()
    private var motor = Motor()
    private var saved: [Int: (name: String, pan: Double, tilt: Double, zoom: Double)] = [
        0: ("Crib", 3000, 420, 6),
        1: ("Door", 5200, 380, 0),
    ]
    private let geometry = PTZGeometry()
    private let speed = 1200.0, zoomSpeed = 2.5

    /// Commands take effect after a while, as a camera's do.
    private func lag() async throws {
        try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.05...0.3) * 1_000_000_000))
    }

    private func advance() {
        let now = Date()
        let dt = now.timeIntervalSince(motor.updated)
        motor.updated = now
        if let goal = motor.goal {
            let dp = goal.pan - motor.pan, dtl = goal.tilt - motor.tilt
            let step = speed * dt
            motor.pan += max(-step, min(step, dp))
            motor.tilt += max(-step, min(step, dtl))
            if abs(dp) <= step && abs(dtl) <= step { motor.goal = nil }
        } else {
            motor.pan += motor.direction.pan * speed * dt
            motor.tilt += motor.direction.tilt * speed * dt
        }
        motor.pan = min(max(motor.pan, Double(geometry.panRange.lowerBound)), Double(geometry.panRange.upperBound))
        motor.tilt = min(max(motor.tilt, Double(geometry.tiltRange.lowerBound)), Double(geometry.tiltRange.upperBound))
        let dz = motor.zoomGoal - motor.zoom
        motor.zoom += max(-zoomSpeed * dt, min(zoomSpeed * dt, dz))
    }

    private func update<T>(_ change: (inout Motor) -> T) -> T {
        lock.withLock {
            advance()
            return change(&motor)
        }
    }

    func ptzAbility() async throws -> PTZAbility {
        PTZAbility(panTilt: true, zoom: true, presets: true)
    }

    func ptzPosition() async throws -> PTZPosition {
        try await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.04...0.12) * 1_000_000_000))
        return update { PTZPosition(pan: Int($0.pan.rounded()), tilt: Int($0.tilt.rounded())) }
    }

    func ptzMove(_ direction: PTZDirection) async throws {
        try await lag()
        let (pan, tilt) = (Double(direction.pan), Double(direction.tilt))
        update { $0.goal = nil; $0.direction = (pan, tilt) }
    }

    func ptzStop() async throws {
        try await lag()
        update { $0.direction = (0, 0) }
    }

    func ptzZoom() async throws -> PTZZoom {
        try await Task.sleep(nanoseconds: 60_000_000)
        return update { PTZZoom(position: Int($0.zoom.rounded()), range: geometry.zoomRange) }
    }

    func setZoom(_ position: Int) async throws {
        try await lag()
        update { $0.zoomGoal = Double(position) }
    }

    func presets() async throws -> [PTZPreset] {
        lock.withLock { saved.keys.sorted().map { PTZPreset(id: $0, name: saved[$0]!.name) } }
    }

    func presetSlots() async throws -> [(id: Int, used: Bool)] {
        lock.withLock { (0..<32).map { ($0, saved[$0] != nil) } }
    }

    func savePreset(id: Int, name: String) async throws {
        let now = update { ($0.pan, $0.tilt, $0.zoom) }
        lock.withLock { saved[id] = (name, now.0, now.1, now.2) }
    }

    func removePreset(id: Int) async throws {
        _ = lock.withLock { saved.removeValue(forKey: id) }
    }

    func goToPreset(id: Int) async throws {
        try await lag()
        guard let preset = lock.withLock({ saved[id] }) else { return }
        update {
            $0.direction = (0, 0)
            $0.goal = (preset.pan, preset.tilt)
            $0.zoomGoal = preset.zoom
        }
    }

    func logout() async {}
}
