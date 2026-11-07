import AppKit
import UserNotifications

/// Turns monitor events into notifications (with a snapshot) and a short recent-events list.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    struct Entry {
        let cameraURL: String
        let cameraName: String
        let text: String
        let symbol: String
        let date: Date
    }

    /// Opens the player on the camera with this URL.
    var onOpen: ((String) -> Void)?
    /// Recent events changed; `true` when a new one just arrived.
    var onChange: ((Bool) -> Void)?
    private(set) var recent: [Entry] = []

    var notifyMotion: Bool {
        get { UserDefaults.standard.bool(forKey: "notifyMotion") }
        set { UserDefaults.standard.set(newValue, forKey: "notifyMotion") }
    }

    var notifySound: Bool {
        get { UserDefaults.standard.bool(forKey: "notifySound") }
        set { UserDefaults.standard.set(newValue, forKey: "notifySound") }
    }

    /// After a camera notifies, its further events are dropped for this long (seconds, default 5 min),
    /// so someone walking into a room gives one notification, not twenty.
    var cooldown: TimeInterval { UserDefaults.standard.double(forKey: "notifyCooldown") }
    /// Events in the first seconds of a burst only make it more specific (motion → person).
    private let gather: TimeInterval = 3

    private struct Burst {
        let start: Date
        var text: String
        var symbol: String
        var rank: Int
    }
    /// Per camera URL: the burst currently holding its cooldown.
    private var bursts: [String: Burst] = [:]

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["notifyMotion": true, "notifySound": true, "notifyCooldown": 300.0])
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handle(_ event: CameraMonitor.Event, from monitor: CameraMonitor) {
        let text: String
        let symbol: String
        let kind: String
        let rank: Int
        switch event {
        case .detection(let d):
            kind = "motion"
            switch true {
            case d.person: (text, symbol, rank) = ("Person detected", "figure.walk", 4)
            case d.vehicle: (text, symbol, rank) = ("Vehicle detected", "car.fill", 3)
            case d.animal: (text, symbol, rank) = ("Animal detected", "pawprint.fill", 2)
            default: (text, symbol, rank) = ("Motion detected", "figure.walk.motion", 1)
            }
        case .sound:
            (kind, text, symbol, rank) = ("sound", "Sound detected", "waveform", 1)
        }

        guard kind == "motion" ? notifyMotion : notifySound else { return }

        let url = monitor.camera.url
        let name = monitor.camera.displayName
        let now = Date()
        if var burst = bursts[url], now.timeIntervalSince(burst.start) < cooldown {
            // Still gathering: keep the most specific event. Afterwards: drop it.
            guard now.timeIntervalSince(burst.start) < gather, rank > burst.rank else { return }
            (burst.text, burst.symbol, burst.rank) = (text, symbol, rank)
            bursts[url] = burst
            if let i = recent.firstIndex(where: { $0.cameraURL == url && $0.date == burst.start }) {
                recent[i] = Entry(cameraURL: url, cameraName: name, text: text, symbol: symbol, date: burst.start)
            }
            return
        }
        bursts[url] = Burst(start: now, text: text, symbol: symbol, rank: rank)

        recent.insert(Entry(cameraURL: url, cameraName: name, text: text, symbol: symbol, date: now), at: 0)
        recent = Array(recent.prefix(5))
        onChange?(true)

        DispatchQueue.main.asyncAfter(deadline: .now() + gather) { [weak self] in
            guard let burst = self?.bursts[url], burst.start == now else { return }
            Self.notify(burst.text, camera: name, from: monitor)
        }
    }

    private static func notify(_ text: String, camera name: String, from monitor: CameraMonitor) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = name
            content.body = text
            content.sound = .default
            content.threadIdentifier = monitor.camera.url
            content.userInfo = ["camera": monitor.camera.url]
            if let jpeg = await monitor.snapshot() {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("reobaby-\(UUID().uuidString).jpg")
                if (try? jpeg.write(to: file)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "snapshot", url: file) {
                    content.attachments = [attachment]
                }
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func clearRecent() {
        recent.removeAll()
        onChange?(false)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let url = response.notification.request.content.userInfo["camera"] as? String {
            DispatchQueue.main.async { self.onOpen?(url) }
        }
        completionHandler()
    }
}
