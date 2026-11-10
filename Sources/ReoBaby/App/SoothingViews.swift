import SwiftUI

// MARK: - Settings ▸ Soothing

/// Every Soothing Sounds setting. They apply as they change, also to the sound already playing.
struct SoothingPane: View {
    @ObservedObject var soother: Soother
    @AppStorage("sootheNoise") private var noise = SoothingSettings.defaults.noise.rawValue
    @AppStorage("sootheVolume") private var volume = SoothingSettings.defaults.volume
    @AppStorage("sootheWarmth") private var warmth = SoothingSettings.defaults.warmth
    @AppStorage("sootheHeartbeat") private var heartbeat = SoothingSettings.defaults.heartbeat
    @AppStorage("sootheHeartRate") private var heartRate = SoothingSettings.defaults.heartRate
    @AppStorage("sootheShushing") private var shushing = SoothingSettings.defaults.shushing
    @AppStorage("sootheWaves") private var waves = SoothingSettings.defaults.waves
    @AppStorage("sootheHeartLevel") private var heartLevel = SoothingSettings.defaults.heartLevel
    @AppStorage("sootheShushLevel") private var shushLevel = SoothingSettings.defaults.shushLevel
    @AppStorage("sootheWavesLevel") private var wavesLevel = SoothingSettings.defaults.wavesLevel
    @AppStorage("sootheTimer") private var timer = 45.0
    @AppStorage("sootheFadeOut") private var fadeOut = 120.0
    @AppStorage("sootheOutput") private var output = Soother.Output.camera.rawValue

    private var isDefault: Bool {
        Soother.defaults.keys.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil }
    }

    /// One row per setting, so the pane stays short enough for a laptop's screen.
    var body: some View {
        PaneForm {
            Section {
                SoothingHeader(soother: soother)
            }

            Section {
                NoisePicker(selection: $noise)
                    .padding(.vertical, 2)
                LevelRow("Volume", value: $volume, text: volume == 0 ? "Off" : "\(Int((volume * 100).rounded()))%")
                LevelRow("Warmth", value: $warmth, text: Self.warmthText(warmth))
                    .help("Takes the hiss out of the treble, toward the deep hush a baby hears in the womb.")
            } header: {
                Text("Sound")
            } footer: {
                SectionNote("Set the volume at the crib, as quiet as still soothes: about 50 dB at the mattress, as loud as a quiet conversation. Warmth takes the hiss out of the treble.")
            }

            Section {
                LevelRow("Heartbeat", value: $heartLevel, text: Self.levelText(heartLevel), isOn: $heartbeat) {
                    LayerIcon(symbol: "heart.fill", color: .pink)
                }
                .help("A slow heartbeat under the noise, as in the womb. The slider sets how loud it is against the noise.")
                if heartbeat {
                    LevelRow("Heart rate", value: $heartRate, in: 55...90, text: "\(Int(heartRate.rounded())) bpm",
                             secondary: true, alignsWithSwitch: true) {
                        LayerIcon(symbol: nil, color: .clear)
                    }
                    .help("A parent's resting heart beats 60 to 80 times a minute.")
                }
                LevelRow("Shushing", value: $shushLevel, text: Self.levelText(shushLevel), isOn: $shushing) {
                    LayerIcon(symbol: "wind", color: .teal)
                }
                .help("A soft, rhythmic “shhh”, the way parents shush. The slider sets how loud it is against the noise.")
                LevelRow("Waves", value: $wavesLevel, text: Self.levelText(wavesLevel), isOn: $waves) {
                    LayerIcon(symbol: "water.waves", color: .blue)
                }
                .help("The noise swells and falls slowly, like the sea. The slider sets how far.")
            } header: {
                Text("Layers")
            } footer: {
                SectionNote("Set each level by ear, at the crib. Every change, like Play and Stop, takes 10 seconds to arrive.")
            }

            Section {
                Picker("Stop after", selection: $timer) {
                    ForEach(Self.with(Soother.timerChoices, timer), id: \.self) { Text(Soother.describeTimer($0)).tag($0) }
                }
                Picker("Fade out over", selection: $fadeOut) {
                    ForEach(Self.with(Soother.fadeOutChoices, fadeOut), id: \.self) { Text(Soother.describeSeconds($0)).tag($0) }
                }
                Picker(selection: $output) {
                    Text("The camera you're watching").tag(Soother.Output.camera.rawValue)
                    Text("This Mac").tag(Soother.Output.mac.rawValue)
                } label: {
                    Text("Play on")
                    Text(output == Soother.Output.camera.rawValue
                         ? "Its speaker\(soother.cameraName.map { ": \($0)" } ?? ""). Pause fades it out."
                         : "This Mac's sound output.")
                }
            } header: {
                Text("Timer")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    SectionNote("All night stops after 8 hours, as paediatricians advise. The sound is made as it plays, never recorded or downloaded.")
                    Button("Restore Defaults") {
                        withAnimation { Soother.defaults.keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
                    }
                    .disabled(isDefault)
                    .fixedSize()
                }
            }
        }
        // Leaving the pane ends a preview.
        .onDisappear { soother.stopPreview() }
    }

    static func levelText(_ level: Double) -> String {
        level < 0.005 ? "Off" : "\(Int((level * 100).rounded()))%"
    }

    static func warmthText(_ warmth: Double) -> String {
        warmth < 0.03 ? "Off" : "\(Int((warmth * 100).rounded()))%"
    }

    /// The standard choices, plus a value set some other way.
    private static func with(_ choices: [Double], _ value: Double) -> [Double] {
        choices.contains(value) ? choices : (choices + [value]).sorted()
    }
}

/// The moon, what's playing, and the button that starts or stops it.
struct SoothingHeader: View {
    @ObservedObject var soother: Soother
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            if compact {
                // The player's own moon: white, lit indigo while sound plays.
                Image(systemName: soother.isOn ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(soother.isOn ? IconTile.soothingLit : .white)
                    .frame(width: 28)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                SoothingIcon(playing: soother.isOn, size: 42)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Soothing Sounds")
                    .font(compact ? .system(size: 13, weight: .semibold) : .body)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(detail)
                        .font(compact ? .system(size: 11) : .subheadline)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)
            if compact {
                // A text button like the player's camera name: no bezel, a faint backing.
                Button {
                    soother.toggle()
                } label: {
                    Label(soother.isOn ? "Stop" : "Play", systemImage: soother.isOn ? "stop.fill" : "play.fill")
                }
                .buttonStyle(HUDButtonStyle(look: .button))
                .keyboardShortcut(.defaultAction)
            } else {
                PreviewButton(soother: soother)
                Button {
                    soother.toggle()
                } label: {
                    Label(soother.isOn ? "Stop" : "Play", systemImage: soother.isOn ? "stop.fill" : "play.fill")
                        .frame(minWidth: 54, minHeight: 16)
                }
                .soothingButton(prominent: !soother.isOn, shape: .capsule)
            }
        }
        .padding(.vertical, compact ? 0 : 2)
        .animation(.snappy, value: soother.status)
        .animation(.snappy, value: soother.isFadingOut)
        .animation(.snappy, value: soother.isPreviewing)
    }

    private var isFailed: Bool {
        if case .failed = soother.status { return true }
        return false
    }

    private var detail: String {
        if !soother.isOn, !isFailed, !soother.isFadingOut {
            if soother.isPreviewing { return "Previewing on this Mac" }
            let settings = SoothingSettings.current
            let timer = Soother.describeTimer(Soother.timerMinutes)
            return compact ? "\(settings.noise.title) noise · \(Soother.timerMinutes >= 480 ? "all night" : timer)"
                : "\(settings.noise.title) noise · stops after \(timer.lowercased())"
        }
        return [soother.statusText, soother.untilText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Headphones: the sound as set, on this Mac only, for choosing it by ear.
struct PreviewButton: View {
    @ObservedObject var soother: Soother
    /// Drawn like the player's controls, for the moon's panel.
    var hud = false

    var body: some View {
        Group {
            if hud {
                Button {
                    soother.togglePreview()
                } label: {
                    Image(systemName: "headphones")
                        .foregroundStyle(soother.isPreviewing ? AnyShapeStyle(IconTile.soothingLit) : AnyShapeStyle(.white))
                }
                .buttonStyle(HUDButtonStyle(look: soother.isPreviewing ? .on : .plain))
            } else {
                Button {
                    soother.togglePreview()
                } label: {
                    Image(systemName: "headphones")
                }
                .soothingButton(prominent: soother.isPreviewing, shape: .circle)
            }
        }
        .disabled(!soother.canPreview)
        .help(soother.isPreviewing ? "Stop the preview" : "Preview on this Mac: hear the sound as set, here only, before playing it in the nursery")
        .accessibilityLabel(soother.isPreviewing ? "Stop Preview" : "Preview on This Mac")
    }
}

/// A moon on an indigo tile; while sound plays, ripples spread from it.
struct SoothingIcon: View {
    let playing: Bool
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            if playing {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, canvas in
                        for ring in 0..<3 {
                            let phase = (t / 3.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                            let radius = canvas.width * (0.32 + 0.22 * phase)
                            let rect = CGRect(x: canvas.width / 2 - radius, y: canvas.height / 2 - radius, width: radius * 2, height: radius * 2)
                            ctx.stroke(Circle().path(in: rect), with: .color(IconTile.soothingColor.opacity(0.55 * (1 - phase))), lineWidth: 1.5)
                        }
                    }
                }
                .frame(width: size * 1.5, height: size * 1.5)
                .transition(.opacity)
            }
            IconTile.soothing.size(size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// White, pink and brown noise as three tiles, each drawing its own spectrum: flat, gently
/// sloping, steeply sloping.
struct NoisePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(SoothingSettings.Noise.allCases) { noise in
                Button {
                    withAnimation(.snappy) { selection = noise.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        NoiseTile(noise: noise, selected: selection == noise.rawValue)
                        VStack(spacing: 1) {
                            Text(noise.title)
                                .font(.callout.weight(selection == noise.rawValue ? .semibold : .regular))
                            Text(Self.caption(noise))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(noise.title) noise")
                .accessibilityAddTraits(selection == noise.rawValue ? .isSelected : [])
            }
        }
    }

    static func caption(_ noise: SoothingSettings.Noise) -> String {
        switch noise {
        case .white: "Bright, like a fan"
        case .pink: "Soft, like rain"
        case .brown: "Deep, like surf"
        }
    }
}

private struct NoiseTile: View {
    let noise: SoothingSettings.Noise
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: background, startPoint: .top, endPoint: .bottom))
            .overlay {
                Spectrum(noise: noise)
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 0.5)
            }
            .frame(height: 58)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }

    private var background: [Color] {
        switch noise {
        case .white: [Color(white: 0.78), Color(white: 0.58)]
        case .pink: [Color(red: 1, green: 0.55, blue: 0.70), Color(red: 0.86, green: 0.30, blue: 0.50)]
        case .brown: [Color(red: 0.74, green: 0.52, blue: 0.36), Color(red: 0.50, green: 0.32, blue: 0.20)]
        }
    }
}

/// The noise's spectrum over a log frequency axis, with a little shimmer, filled to the bottom.
private struct Spectrum: Shape {
    let noise: SoothingSettings.Noise

    func path(in rect: CGRect) -> Path {
        let slope: Double = switch noise {
        case .white: 0
        case .pink: 0.5
        case .brown: 1
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        let steps = 48
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            // Level falls by `slope` per unit of log frequency; a fixed ripple reads as noise.
            let ripple = 0.05 * sin(x * 61) + 0.035 * sin(x * 23 + 1)
            let level = max(0.06, min(1, 0.86 - slope * 0.72 * x + ripple))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * x, y: rect.maxY - rect.height * level))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A small coloured symbol in front of a layer; without one, the space it takes.
struct LayerIcon: View {
    let symbol: String?
    let color: Color

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .foregroundStyle(color.gradient)
                .frame(width: 22)
        } else {
            Color.clear.frame(width: 22, height: 1)
        }
    }
}

/// A setting in one row: its name, a slider and its value; for a layer, its symbol in front and
/// its switch at the end. A layer's slider dims while the layer is off.
struct LevelRow<Icon: View>: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String
    let isOn: Binding<Bool>?
    let secondary: Bool
    /// Leaves room for a switch it doesn't have, so its slider lines up with the layers'.
    let alignsWithSwitch: Bool
    let icon: Icon

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, text: String,
         isOn: Binding<Bool>? = nil, secondary: Bool = false, alignsWithSwitch: Bool = false, @ViewBuilder icon: () -> Icon) {
        self.title = title
        _value = value
        self.range = range
        self.text = text
        self.isOn = isOn
        self.secondary = secondary
        self.alignsWithSwitch = alignsWithSwitch
        self.icon = icon()
    }

    private var on: Bool { isOn?.wrappedValue ?? true }
    private static var switchWidth: CGFloat { 40 }

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .disabled(!on)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(on ? 1 : 0.5)
                .frame(width: 58, alignment: .trailing)
                .contentTransition(.numericText(value: value))
                .animation(.snappy(duration: 0.2), value: value)
            if let isOn {
                Toggle(title, isOn: isOn.animation(.snappy))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(width: Self.switchWidth, alignment: .trailing)
            } else if alignsWithSwitch {
                Color.clear.frame(width: Self.switchWidth, height: 1)
            }
        }
    }
}

extension LevelRow where Icon == LayerIcon {
    /// A row with no symbol and no switch, its slider in line with the layers'.
    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, text: String) {
        self.init(title, value: value, in: range, text: text, alignsWithSwitch: true) { LayerIcon(symbol: nil, color: .clear) }
    }
}

// MARK: - The player's popover

/// Soothing Sounds from the player: start or stop, the noise, the volume, the layers and the
/// timer. Everything else is in Settings.
struct SoothingPopover: View {
    @ObservedObject var soother: Soother
    var openSettings: () -> Void
    @AppStorage("sootheNoise") private var noise = SoothingSettings.defaults.noise.rawValue
    @AppStorage("sootheVolume") private var volume = SoothingSettings.defaults.volume
    @AppStorage("sootheHeartbeat") private var heartbeat = SoothingSettings.defaults.heartbeat
    @AppStorage("sootheShushing") private var shushing = SoothingSettings.defaults.shushing
    @AppStorage("sootheWaves") private var waves = SoothingSettings.defaults.waves
    @AppStorage("sootheTimer") private var timer = 45.0

    /// Drawn with the player's own controls: white symbols and text with no bezels, its white
    /// volume slider, and menus like its camera name, in a dark popover like its control strip.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SoothingHeader(soother: soother, compact: true)
            HUDSeparator()
            HStack(spacing: 4) {
                ForEach(SoothingSettings.Noise.allCases) { choice in
                    Button {
                        withAnimation(.snappy) { noise = choice.rawValue }
                    } label: {
                        Text(choice.title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HUDButtonStyle(look: noise == choice.rawValue ? .on : .plain))
                    .accessibilityLabel("\(choice.title) noise")
                    .accessibilityAddTraits(noise == choice.rawValue ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                HUDVolumeSlider(value: $volume)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            HStack(spacing: 4) {
                LayerChip(title: "Heartbeat", symbol: "heart.fill", color: .pink, isOn: $heartbeat)
                LayerChip(title: "Shushing", symbol: "wind", color: .teal, isOn: $shushing)
                LayerChip(title: "Waves", symbol: "water.waves", color: .blue, isOn: $waves)
            }
            HUDSeparator()
            HStack(spacing: 4) {
                Menu {
                    Picker("Stop after", selection: $timer) {
                        ForEach(Soother.timerChoices, id: \.self) { Text(Soother.describeTimer($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                        Text(Soother.describeTimer(timer))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(HUDButtonStyle(look: .plain))
                .fixedSize()
                .help("Stop after")
                Spacer()
                PreviewButton(soother: soother, hud: true)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(HUDButtonStyle(look: .plain))
                .help("Soothing Settings…")
                .accessibilityLabel("Soothing Settings…")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(14)
        .frame(width: 320)
        .onDisappear { soother.stopPreview() }
    }
}

/// A layer, on or off: its symbol lit in its colour when on, as the player lights its moon.
private struct LayerChip: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { isOn.toggle() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(color) : AnyShapeStyle(.white))
                    .symbolEffect(.bounce, value: isOn)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(HUDButtonStyle(look: isOn ? .on : .plain))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The player's controls as a SwiftUI button style: white on the dark blur, no bezel. What's
/// chosen or on sits on a faint rounded backing, the rest is dimmer; the pointer lights a button.
struct HUDButtonStyle: ButtonStyle {
    enum Look { case plain, on, button }
    let look: Look

    func makeBody(configuration: Configuration) -> some View {
        HUDButtonBody(configuration: configuration, look: look)
    }
}

private struct HUDButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let look: HUDButtonStyle.Look
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(look == .plain && !hovering ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.white))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(backing)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.15), value: hovering)
    }

    private var backing: Double {
        if configuration.isPressed { return 0.26 }
        switch look {
        case .on: return 0.18
        case .button: return hovering ? 0.24 : 0.16
        case .plain: return hovering ? 0.1 : 0
        }
    }
}

/// The player's volume slider: a white track and knob that stay white when the window isn't key.
struct HUDVolumeSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> HUDSlider {
        let slider = HUDSlider()
        slider.minValue = 0
        slider.maxValue = 1
        slider.controlSize = .small
        slider.isContinuous = true
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: HUDSlider, context: Context) {
        context.coordinator.value = $value
        if abs(slider.doubleValue - value) > 0.0001 { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }
}

/// A faint line between groups of controls.
private struct HUDSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 1)
    }
}

enum SoothingButtonShape { case capsule, circle }

extension View {
    /// A bordered button; prominent is filled with the accent colour.
    @ViewBuilder func soothingButton(prominent: Bool, shape: SoothingButtonShape) -> some View {
        Group {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
        .buttonBorderShape(shape == .circle ? .circle : .capsule)
    }
}

extension IconTile {
    static let soothingColor = Color(red: 0.40, green: 0.42, blue: 0.96)
    /// The player's moon button while sound plays.
    static let soothingLit = Color(red: 0.70, green: 0.72, blue: 1)
    static let soothing = IconTile(symbol: "moon.zzz.fill", colors: [Color(red: 0.47, green: 0.50, blue: 1), Color(red: 0.27, green: 0.26, blue: 0.82)])
}
