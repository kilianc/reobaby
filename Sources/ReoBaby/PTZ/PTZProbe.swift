import CoreGraphics
import Foundation
import ImageIO

/// `ReoBaby --ptz <camera> <command> …`: pan, tilt and zoom from the command line, and the
/// measurements behind `PTZGeometry`, for fitting it to another camera model.
extension Probe {
    static func ptz(target: String, arguments: [String]) -> Int32 {
        guard let (_, endpoint) = resolve(target), let password = endpoint.password else {
            print("No camera with a saved password matching “\(target)”")
            return 2
        }
        let api = CameraAPI(host: endpoint.host, user: endpoint.user ?? "admin", password: password)
        let command = arguments.first ?? "pos"
        let rest = Array(arguments.dropFirst())
        return wait {
            do {
                switch command {
                case "pos":
                    let position = try await api.ptzPosition()
                    let zoom = try? await api.ptzZoom()
                    print("pan \(position.pan) tilt \(position.tilt) zoom \(zoom.map { "\($0.position) of \($0.range)" } ?? "-")")
                    print(try await api.ptzAbility())
                case "goto":
                    // goto <pan> <tilt> [tolerance], in the camera's units
                    guard rest.count > 1, let pan = Int(rest[0]), let tilt = Int(rest[1]) else { return usage() }
                    let tolerance = rest.count > 2 ? Int(rest[2]) ?? 30 : 30
                    let goal = PTZPosition(pan: pan, tilt: tilt)
                    let began = Date()
                    let trace = Locked<[String]>([])
                    let end = try await api.ptzChase(target: { goal }, tolerance: { PTZPosition(pan: tolerance, tilt: tolerance) },
                                                     tuning: PTZTuning()) { position in
                        let text = "\(position.pan),\(position.tilt)"
                        if trace.value.last != text { trace.value.append(text) }
                    }
                    print(String(format: "at %d,%d, off by %+d,%+d after %.1f s: ", end.pan, end.tilt, end.pan - pan, end.tilt - tilt,
                                 Date().timeIntervalSince(began)) + trace.value.joined(separator: " "))
                case "pulses":
                    // pulses <hold ms> [count] [Left|Right|Up|Down]: short moves, alternating unless a direction is given
                    let hold = (Double(rest.first ?? "") ?? 60) / 1000
                    var moves: [String] = []
                    let only = rest.count > 2 ? PTZDirection(rawValue: rest[2]) : nil
                    var direction = only ?? PTZDirection.right
                    var position = try await api.ptzSettled()
                    for _ in 0..<(rest.count > 1 ? Int(rest[1]) ?? 8 : 8) {
                        let began = Date()
                        await api.ptzPulse(direction, hold: hold)
                        let took = Date().timeIntervalSince(began)
                        let next = try await api.ptzSettled()
                        let moved = direction.tilt != 0 ? next.tilt - position.tilt : next.pan - position.pan
                        moves.append(String(format: "%+d (%.0f ms)", moved, took * 1000))
                        position = next
                        if only == nil { direction = direction == .right ? .left : .right }
                    }
                    print("\(await api.onvif() == nil ? "HTTP API" : "ONVIF"), hold \(Int(hold * 1000)) ms: " + moves.joined(separator: "  "))
                case "zoom":
                    guard let position = rest.first.flatMap(Int.init) else { return usage() }
                    try await api.setZoom(position)
                    print("zoom \(try await settleZoom(api).position)")
                case "limit":
                    // limit <Left|Right|Up|Down>: runs to the end stop
                    guard let direction = rest.first.flatMap(PTZDirection.init(rawValue:)) else { return usage() }
                    try await api.ptzMove(direction)
                    let deadline = Date().addingTimeInterval(9)
                    var last = try await api.ptzPosition(), same = 0
                    while same < 3, Date() < deadline {
                        try await Task.sleep(nanoseconds: 150_000_000)
                        let now = try await api.ptzPosition()
                        same = now == last ? same + 1 : 0
                        last = now
                    }
                    await api.ptzStopNow()
                    print("end stop: pan \(last.pan) tilt \(last.tilt)")
                case "survey":
                    // survey <zoom> <pan> <tilt,tilt,…>: how far the picture moves per unit
                    guard rest.count > 2, let zoom = Int(rest[0]), let pan = Int(rest[1]) else { return usage() }
                    try await survey(api, zoom: zoom, pan: pan, tilts: rest[2].split(separator: ",").compactMap { Int($0) })
                case "ends":
                    // ends <tilt>: whether the pictures at the two pan end stops overlap
                    try await ends(api, tilt: Int(rest.first ?? "") ?? 300)
                default:
                    return usage()
                }
                await api.logout()
                return 0
            } catch {
                await api.ptzStopNow()
                await api.logout()
                print("failed: \(error)")
                return 1
            }
        }
    }

    private static func usage() -> Int32 {
        print("""
        ReoBaby --ptz <camera> pos
                               goto <pan> <tilt> [tolerance]
                               pulses <hold ms> [count]
                               zoom <step>
                               limit <Left|Right|Up|Down>
                               survey <zoom> <pan> <tilt,tilt,…>
                               ends <tilt>
        """)
        return 2
    }

    @discardableResult
    private static func settleZoom(_ api: CameraAPI) async throws -> PTZZoom {
        var last = try await api.ptzZoom()
        var still = Date()
        while Date().timeIntervalSince(still) < 2 {
            try await Task.sleep(nanoseconds: 150_000_000)
            let now = try await api.ptzZoom()
            if now != last { still = Date() }
            last = now
        }
        return last
    }

    private static func snapshot(_ api: CameraAPI) async throws -> CGImage? {
        let data = try await api.snapshot()
        return CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// Pulses pan and tilt at each tilt, and measures how far the picture moved between stills.
    private static func survey(_ api: CameraAPI, zoom: Int, pan: Int, tilts: [Int]) async throws {
        if try await api.ptzZoom().position != zoom {
            try await api.setZoom(zoom)
            try await settleZoom(api)
        }
        for tilt in tilts {
            try await api.ptzChase(target: { PTZPosition(pan: pan, tilt: tilt) }, tolerance: { PTZPosition(pan: 60, tilt: 60) },
                                   tuning: PTZTuning())
            for axis in ["pan", "tilt"] {
                var scales: [Double] = [], scores: [Float] = []
                var position = try await api.ptzSettled()
                var still = try await snapshot(api)
                var forward = true
                for _ in 0..<14 where scales.count < 4 {
                    let direction: PTZDirection = axis == "pan" ? (forward ? .right : .left) : (forward ? .up : .down)
                    await api.ptzPulse(direction, hold: 0.1)
                    let next = try await api.ptzSettled()
                    let delta = axis == "pan" ? next.pan - position.pan : next.tilt - position.tilt
                    guard delta != 0 else { continue }
                    forward.toggle()
                    try await Task.sleep(nanoseconds: 700_000_000) // for the picture to catch up
                    let after = try await snapshot(api)
                    defer { position = next; still = after }
                    guard abs(delta) >= 15, next.tilt > 0, next.tilt < 1240,
                          let a = still, let b = after, let m = PictureShift.measure(from: a, to: b) else { continue }
                    scales.append((axis == "pan" ? -m.x : m.y) / Double(delta))
                    scores.append(m.score)
                }
                let sorted = scales.sorted()
                print(String(format: "zoom %2d tilt %4d %@: %.6f picture widths per unit (%@; match %@)", zoom, position.tilt, axis,
                             sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                             scales.map { String(format: "%.6f", $0) }.joined(separator: " "),
                             scores.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            }
        }
    }

    /// A camera that turns a full circle sees the same picture at both ends.
    private static func ends(_ api: CameraAPI, tilt: Int) async throws {
        let range = PTZGeometry().panRange
        var pictures: [(PTZPosition, CGImage?)] = []
        for pan in [range.lowerBound, range.upperBound] {
            try await api.ptzChase(target: { PTZPosition(pan: pan, tilt: tilt) }, tolerance: { PTZPosition(pan: 20, tilt: 60) },
                                   tuning: PTZTuning())
            try await Task.sleep(nanoseconds: 800_000_000)
            pictures.append((try await api.ptzPosition(), try await snapshot(api)))
        }
        guard let a = pictures[0].1, let b = pictures[1].1, let m = PictureShift.measure(from: a, to: b) else {
            print("The pictures at the two ends don't overlap")
            return
        }
        print(String(format: "at %d,%d and %d,%d the picture moved %+.4f, %+.4f picture widths (match %.2f)",
                     pictures[0].0.pan, pictures[0].0.tilt, pictures[1].0.pan, pictures[1].0.tilt, m.x, m.y, m.score))
    }
}

/// How far the middle of one picture moved in another, by correlation of grey levels.
enum PictureShift {
    private struct Grey {
        var pixels: [Float]
        var width: Int
        var height: Int

        init(_ image: CGImage, width: Int) {
            self.width = width
            height = width * image.height / image.width
            var bytes = [UInt8](repeating: 0, count: width * height)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = bytes.map(Float.init)
        }
    }

    /// Correlation, -1 to 1, of the middle of `a` with `b` moved by (dx, dy) pixels.
    private static func match(_ a: Grey, _ b: Grey, dx: Int, dy: Int) -> Float {
        let w = a.width, h = a.height
        // The middle half: the camera's name and clock sit in the corners and don't move.
        let x0 = w / 4, x1 = w * 3 / 4, y0 = h / 4, y1 = h * 3 / 4
        var n: Float = 0, sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        for y in y0..<y1 where y + dy >= 0 && y + dy < h {
            for x in x0..<x1 where x + dx >= 0 && x + dx < w {
                let pa = a.pixels[y * w + x], pb = b.pixels[(y + dy) * w + x + dx]
                n += 1; sa += pa; sb += pb; saa += pa * pa; sbb += pb * pb; sab += pa * pb
            }
        }
        guard n > Float((x1 - x0) * (y1 - y0)) * 0.4 else { return -1 }
        let cov = sab - sa * sb / n, va = saa - sa * sa / n, vb = sbb - sb * sb / n
        return va > 0 && vb > 0 ? cov / (va * vb).squareRoot() : -1
    }

    /// Picture widths, x to the right and y down, and how well it matched.
    static func measure(from: CGImage, to: CGImage) -> (x: Double, y: Double, score: Float)? {
        // Everywhere at low resolution, then around the best match at a higher one.
        let coarseA = Grey(from, width: 160), coarseB = Grey(to, width: 160)
        var best = (dx: 0, dy: 0, score: Float(-1))
        for dy in -60...60 {
            for dx in -110...110 {
                let score = match(coarseA, coarseB, dx: dx, dy: dy)
                if score > best.score { best = (dx, dy, score) }
            }
        }
        let fineA = Grey(from, width: 960), fineB = Grey(to, width: 960)
        var fine = (dx: 0, dy: 0, score: Float(-1))
        for dy in (best.dy * 6 - 6)...(best.dy * 6 + 6) {
            for dx in (best.dx * 6 - 6)...(best.dx * 6 + 6) {
                let score = match(fineA, fineB, dx: dx, dy: dy)
                if score > fine.score { fine = (dx, dy, score) }
            }
        }
        guard fine.score > 0 else { return nil }
        return (Double(fine.dx) / 960, Double(fine.dy) / 960, fine.score)
    }
}
