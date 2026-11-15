/// ReoBabyKit: Reolink cameras for any Swift app, command-line tool or server. Local only.
///
/// - `ConfigStore` and `Camera`: the camera list (`~/.config/reobaby/cameras.json`), with
///   passwords in the keychain on Apple platforms and in the file elsewhere.
/// - `Discovery`: Reolink cameras on the local network.
/// - `CameraAPI`: the camera's HTTP API (snapshots, detections, any command), and pan, tilt
///   and zoom through `PTZDevice`; `PTZController` aims a camera as the app does.
/// - `RTSPClient`: the camera's stream, RTP packet by packet. On Apple platforms
///   `CameraPlayer` decodes it, and `CameraMonitor` listens for sound and motion.
/// - `SoothingSynth` and `BaichuanTalk`: noise made as it plays, on the camera's speaker.
public enum ReoBaby {
    /// The release this library comes from: the app's CFBundleShortVersionString.
    public static let version = "1.7.0"
}
