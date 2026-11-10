import Foundation

/// How pan, tilt and zoom move the picture. The numbers are an E1 Zoom's, measured with
/// `ReoBaby --ptz <camera> survey` and `ends`: pan runs 0–7360 and turns a full circle, so a
/// degree is 20.4 units; tilt turns as much per unit; the lens is close to a pinhole that sees
/// 90° across at its widest, 54° at its narrowest.
struct PTZGeometry {
    var unitsPerDegree = 20.4
    var panRange = 0...7360
    var tiltRange = 0...1240
    /// The tilt at which the camera looks level, where panning moves the picture furthest.
    var levelTilt = 500
    /// Focal length at the widest zoom, in picture widths.
    var focalLength = 0.503
    /// How much each step of the optical zoom magnifies.
    var magnificationPerStep = 0.0297
    var zoomRange = 0...32
    /// Beyond the lens, ReoBaby crops the picture: 2560 pixels across stay sharp to about 3×.
    var maxDigitalZoom = 3.0

    func degrees(_ units: Int) -> Double { Double(units) / unitsPerDegree }
    func units(_ degrees: Double) -> Int { Int((degrees * unitsPerDegree).rounded()) }

    func clamp(_ p: PTZPosition) -> PTZPosition {
        PTZPosition(pan: min(max(p.pan, panRange.lowerBound), panRange.upperBound),
                    tilt: min(max(p.tilt, tiltRange.lowerBound), tiltRange.upperBound))
    }

    // MARK: - Zoom

    func opticalMagnification(_ step: Double) -> Double { 1 + step * magnificationPerStep }
    var maxOpticalMagnification: Double { opticalMagnification(Double(zoomRange.upperBound)) }
    var maxMagnification: Double { maxOpticalMagnification * maxDigitalZoom }

    /// The optical step and digital zoom for a magnification: the lens first, then the crop.
    func split(_ magnification: Double) -> (step: Int, digital: Double) {
        let m = min(max(magnification, 1), maxMagnification)
        let step = Int(((min(m, maxOpticalMagnification) - 1) / magnificationPerStep).rounded())
        let clamped = min(max(step, zoomRange.lowerBound), zoomRange.upperBound)
        let digital = max(1, m / opticalMagnification(Double(clamped)))
        return (clamped, digital < 1.005 ? 1 : digital)
    }

    /// Focal length in picture widths of what is on screen.
    func focal(step: Double, digital: Double) -> Double {
        focalLength * opticalMagnification(step) * digital
    }

    /// What the picture covers across, in degrees.
    func fieldOfView(focal: Double) -> Double {
        2 * atan(0.5 / focal) * 180 / .pi
    }

    // MARK: - Aiming

    private func elevation(_ tilt: Double) -> Double {
        (tilt - Double(levelTilt)) / unitsPerDegree * .pi / 180
    }

    /// The position that puts the point at `offset` in the middle of the picture. Offsets are in
    /// picture widths from the middle, x to the right and y up.
    func position(centering offset: CGPoint, from position: PTZPosition, focal f: Double) -> PTZPosition {
        let e = elevation(Double(position.tilt))
        let u = Double(offset.x), v = Double(offset.y)
        // The point's direction, turned by the camera's tilt.
        let x = u
        let y = v * cos(e) + f * sin(e)
        let z = f * cos(e) - v * sin(e)
        let pan = atan2(x, z)
        let elevationThere = atan2(y, (x * x + z * z).squareRoot())
        let perRadian = unitsPerDegree * 180 / .pi
        return clamp(PTZPosition(pan: position.pan + Int((pan * perRadian).rounded()),
                                 tilt: levelTilt + Int((elevationThere * perRadian).rounded())))
    }

    /// Where `target` shows in the picture while the camera is at `position`: picture widths from
    /// the middle, x to the right and y up. Nil when it is behind the camera.
    func offset(of target: PTZPosition, from position: PTZPosition, focal f: Double) -> CGPoint? {
        let pan = Double(target.pan - position.pan) / unitsPerDegree * .pi / 180
        let et = elevation(Double(target.tilt)), e = elevation(Double(position.tilt))
        let dx = cos(et) * sin(pan), dy = sin(et), dz = cos(et) * cos(pan)
        let x = dx
        let y = dy * cos(e) - dz * sin(e)
        let z = dy * sin(e) + dz * cos(e)
        guard z > 0.01 else { return nil }
        return CGPoint(x: f * x / z, y: f * y / z)
    }

    /// Camera units that move the middle of the picture by `fraction` of its width.
    func units(forFraction fraction: Double, focal f: Double) -> Double {
        atan(fraction / f) * 180 / .pi * unitsPerDegree
    }
}

/// A value shared between the main thread and a task.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
