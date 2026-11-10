import Foundation

/// Camera controls for the camera in the player: where it points, where it is going, and how it
/// gets there. Pan and tilt are chased in the background (see `PTZMotion`); zoom is the lens
/// first, then a crop of the picture.
@MainActor
final class PTZController {
    struct State: Equatable {
        var ability: PTZAbility?
        var position: PTZPosition?
        /// Where the camera is headed, while it moves.
        var target: PTZPosition?
        var zoom: PTZZoom?
        /// The lens step being zoomed to, while the lens moves.
        var zoomTarget: Int?
        var digitalZoom = 1.0
        var presets: [PTZPreset] = []
        /// Going to a saved position: the camera finds its own way there.
        var travelling = false

        var available: Bool { ability?.any == true }
        var moving: Bool { target != nil || travelling }
    }

    enum MoveResult { case arrived, stopped, failed }

    private(set) var state = State() {
        didSet { if state != oldValue { onChange?() } }
    }

    let geometry = PTZGeometry()
    var onChange: (() -> Void)?
    var onMoveEnded: ((MoveResult) -> Void)?
    var onError: ((String) -> Void)?
    /// Whether to keep reading where the camera points: while the controls are on screen.
    var shouldPoll: (() -> Bool)?

    /// Camera controls are on screen: keep the position current.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { startPolling() } else { poller?.cancel(); poller = nil }
        }
    }

    private var device: PTZDevice?
    private var generation = 0
    private let tuning = PTZTuning()
    private var chase: Task<Void, Never>?
    private var zoomTask: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var travel: Task<Void, Never>?
    /// Asking the camera what it can do, until it answers.
    private var asking: Task<Void, Never>?
    // Read by the chase, which runs off the main thread.
    private let liveTarget = Locked<PTZPosition?>(nil)
    private let liveTolerance = Locked(PTZPosition(pan: 30, tilt: 30))
    private let liveZoom = Locked<Int?>(nil)
    private var targetVersion = 0

    // MARK: - Camera

    /// Switches to another camera, or none.
    func connect(_ new: PTZDevice?) {
        chase?.cancel()
        zoomTask?.cancel()
        travel?.cancel()
        asking?.cancel()
        chase = nil
        zoomTask = nil
        travel = nil
        asking = nil
        liveTarget.value = nil
        liveZoom.value = nil
        if let old = device { Task { await old.logout() } }
        device = new
        generation += 1
        state = State()
        guard let new else { return }
        let generation = generation
        // A camera busy at that moment, as just after launch, can miss the question: ask
        // again, less and less often, until it answers. Until then there are no controls.
        asking = Task {
            var wait = 5.0
            while generation == self.generation, !Task.isCancelled {
                do {
                    let ability = try await new.ptzAbility()
                    guard generation == self.generation else { return }
                    state.ability = ability
                    if ability.any { await refresh(all: true) }
                    if isActive { startPolling() }
                    return
                } catch {
                    // Not answering, or not a Reolink camera.
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 60)
            }
        }
    }

    /// Reads where the camera points, and its zoom and saved positions.
    func refresh(all: Bool = false) async {
        guard let device, let ability = state.ability else { return }
        let generation = generation
        if ability.panTilt, chase == nil, let position = try? await device.ptzPosition(), generation == self.generation {
            state.position = position
        }
        if ability.zoom, zoomTask == nil, let zoom = try? await device.ptzZoom(), generation == self.generation {
            state.zoom = zoom
        }
        if all, ability.presets, let presets = try? await device.presets(), generation == self.generation {
            state.presets = presets
        }
    }

    private func startPolling() {
        poller?.cancel()
        guard device != nil, state.available else { return }
        poller = Task {
            var tick = 0
            while !Task.isCancelled {
                if shouldPoll?() ?? true, !state.travelling {
                    // Zoom changes only when asked to: read it less often.
                    if tick % 3 == 0 { await refresh() } else if state.ability?.panTilt == true, chase == nil,
                        let position = try? await device?.ptzPosition() { state.position = position }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Pan and tilt

    /// Focal length of what is on screen, in picture widths.
    var focal: Double {
        geometry.focal(step: Double(state.zoom?.position ?? 0), digital: state.digitalZoom)
    }

    /// Focal length once the lens gets where it is going.
    private var targetFocal: Double {
        geometry.focal(step: Double(state.zoomTarget ?? state.zoom?.position ?? 0), digital: state.digitalZoom)
    }

    /// Close enough: 1.8% of the picture's width at the zoom it is headed for, as far as the motor can do it.
    private var viewTolerance: Int {
        Int(min(max(geometry.units(forFraction: 0.018, focal: targetFocal), 12), 60))
    }

    /// Centers the point at `offset`: picture widths from the middle, x to the right, y up.
    func aim(at offset: CGPoint) {
        guard state.ability?.panTilt == true, let position = state.position else { return }
        let target = geometry.position(centering: offset, from: position, focal: focal)
        setTarget(target, tolerance: viewTolerance)
    }

    /// Centers a part of the picture and zooms until it fills the picture. Picture widths, from the middle.
    func frame(center: CGPoint, width: Double) {
        guard let position = state.position else { return }
        // Where the part is, in the picture as it is now; then zoom, then turn as precisely as the new zoom needs.
        let target = geometry.position(centering: center, from: position, focal: focal)
        setMagnification(currentMagnification / max(width, 0.01))
        if state.ability?.panTilt == true { setTarget(target, tolerance: viewTolerance) }
    }

    /// Turns by this many degrees from where the camera is going, or is.
    func nudge(pan: Double = 0, tilt: Double = 0) {
        guard state.ability?.panTilt == true, let base = state.target ?? state.position else { return }
        let target = PTZPosition(pan: base.pan + geometry.units(pan), tilt: base.tilt + geometry.units(tilt))
        let step = max(geometry.units(abs(pan)), geometry.units(abs(tilt)))
        setTarget(target, tolerance: min(viewTolerance, max(step / 2, 8)))
    }

    /// Goes to a position in degrees. Nil keeps that axis where it is going.
    func go(panDegrees: Double? = nil, tiltDegrees: Double? = nil) {
        guard state.ability?.panTilt == true, let base = state.target ?? state.position else { return }
        let target = PTZPosition(pan: panDegrees.map(geometry.units) ?? base.pan,
                                 tilt: tiltDegrees.map(geometry.units) ?? base.tilt)
        setTarget(target, tolerance: min(viewTolerance, 10))
    }

    /// Stops where the camera is.
    func stop() {
        guard state.moving else { return }
        liveTarget.value = nil
        chase?.cancel()
        travel?.cancel()
        if let device { Task { await device.ptzStopNow(sure: true) } }
    }

    private func setTarget(_ target: PTZPosition, tolerance: Int) {
        guard let device else { return }
        travel?.cancel()
        state.travelling = false
        let target = geometry.clamp(target)
        targetVersion += 1
        liveTarget.value = target
        liveTolerance.value = PTZPosition(pan: tolerance, tilt: tolerance)
        state.target = target
        guard chase == nil else { return }
        let version = targetVersion
        let generation = generation
        let (live, tol, tuning) = (liveTarget, liveTolerance, tuning)
        let report = positionReporter(generation)
        chase = Task { [weak self] in
            var result: PTZPosition?
            do {
                result = try await device.ptzChase(target: { live.value }, tolerance: { tol.value }, tuning: tuning, progress: report)
            } catch {}
            guard let self, self.generation == generation else { return }
            self.chaseEnded(at: result, version: version)
        }
    }

    /// Shows the positions a move reads on its way, from wherever it reads them.
    private func positionReporter(_ generation: Int) -> @Sendable (PTZPosition) -> Void {
        { [weak self] position in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == generation else { return }
                self.state.position = position
            }
        }
    }

    private func chaseEnded(at end: PTZPosition?, version: Int) {
        chase = nil
        if let end { state.position = end }
        guard let target = liveTarget.value else {
            state.target = nil
            onMoveEnded?(.stopped)
            return
        }
        let tolerance = liveTolerance.value
        // The chase settles for up to about three tolerances after repeated misses (see `ptzChase`).
        let arrived = end.map { abs($0.pan - target.pan) <= tolerance.pan * 3 && abs($0.tilt - target.tilt) <= tolerance.tilt * 3 } ?? false
        // The target moved after the chase last looked: go again.
        if !arrived, end != nil, targetVersion != version {
            setTarget(target, tolerance: tolerance.pan)
            return
        }
        liveTarget.value = nil
        state.target = nil
        if end == nil { onError?("The camera didn't answer") }
        onMoveEnded?(end == nil ? .failed : arrived ? .arrived : .stopped)
    }

    // MARK: - Zoom

    /// Total magnification of what is on screen: the lens's, then the crop's.
    var currentMagnification: Double {
        geometry.opticalMagnification(Double(state.zoom?.position ?? 0)) * state.digitalZoom
    }

    /// Where zoom is headed: shown while the lens moves.
    var targetMagnification: Double {
        geometry.opticalMagnification(Double(state.zoomTarget ?? state.zoom?.position ?? 0)) * state.digitalZoom
    }

    func setMagnification(_ magnification: Double) {
        guard let device, state.ability?.zoom == true || state.available else { return }
        let (step, digital) = state.ability?.zoom == true
            ? geometry.split(magnification)
            : (0, min(max(magnification, 1), geometry.maxDigitalZoom))
        state.digitalZoom = digital
        guard state.ability?.zoom == true, step != (state.zoomTarget ?? state.zoom?.position) else { return }
        state.zoomTarget = step
        liveZoom.value = step
        guard zoomTask == nil else { return }
        let generation = generation
        let live = liveZoom
        zoomTask = Task { [weak self] in
            var sent: Int?
            var last: PTZZoom?
            var still = Date()
            while !Task.isCancelled {
                guard let want = live.value else { break }
                if want != sent {
                    try? await device.setZoom(want)
                    sent = want
                    still = Date()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let zoom = try? await device.ptzZoom() else { continue }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.state.zoom = zoom
                }
                if zoom != last { still = Date() }
                last = zoom
                // There, or the lens has given up on getting closer.
                if live.value == sent, zoom.position == sent || Date().timeIntervalSince(still) > 1.5 { break }
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.zoomTask = nil
                if live.value == sent || Task.isCancelled {
                    live.value = nil
                    self.state.zoomTarget = nil
                } else if let want = live.value {
                    // Asked for another zoom just as this one finished.
                    self.state.zoomTarget = nil
                    self.setMagnification(self.geometry.opticalMagnification(Double(want)) * self.state.digitalZoom)
                }
            }
        }
    }

    func zoom(by factor: Double) {
        setMagnification(targetMagnification * factor)
    }

    // MARK: - Saved positions

    func goTo(_ preset: PTZPreset) {
        guard let device else { return }
        liveTarget.value = nil
        chase?.cancel()
        travel?.cancel()
        state.target = nil
        state.travelling = true
        state.digitalZoom = 1
        let generation = generation
        let report = positionReporter(generation)
        travel = Task { [weak self] in
            do {
                try await device.goToPreset(id: preset.id)
                try await Task.sleep(nanoseconds: 300_000_000)
                let end = try await device.ptzSettled(report)
                guard let self, self.generation == generation else { return }
                self.state.position = end
                self.state.travelling = false
                self.travel = nil
                self.onMoveEnded?(.arrived)
                // The lens may still be on its way to the saved zoom.
                for _ in 0..<40 {
                    guard let zoom = try? await device.ptzZoom(), self.generation == generation, self.travel == nil else { return }
                    let changed = zoom != self.state.zoom
                    self.state.zoom = zoom
                    if !changed { break }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            } catch {
                guard let self, self.generation == generation else { return }
                self.state.travelling = false
                self.travel = nil
                if !(error is CancellationError) { self.onError?("The camera didn't answer") }
            }
        }
    }

    /// Saves where the camera points now, with its zoom, under the first free id.
    func savePosition(named name: String) {
        guard let device else { return }
        let generation = generation
        Task {
            do {
                guard let free = try await device.presetSlots().first(where: { !$0.used }) else {
                    onError?("The camera has no room for more positions")
                    return
                }
                try await device.savePreset(id: free.id, name: name)
                let presets = try await device.presets()
                if generation == self.generation { state.presets = presets }
            } catch {
                onError?("The camera didn't save the position")
            }
        }
    }

    func remove(_ preset: PTZPreset) {
        guard let device else { return }
        let generation = generation
        Task {
            do {
                try await device.removePreset(id: preset.id)
                let presets = try await device.presets()
                if generation == self.generation { state.presets = presets }
            } catch {
                onError?("The camera didn't forget the position")
            }
        }
    }

    /// The name a new position gets unless the user picks one.
    var nextPositionName: String {
        let names = Set(state.presets.map(\.name))
        return (1...).lazy.map { "Position \($0)" }.first { !names.contains($0) }!
    }
}
