import CryptoKit
import Foundation

/// Where a pan-tilt camera points, in the camera's own units (see `PTZGeometry`).
struct PTZPosition: Equatable {
    var pan: Int
    var tilt: Int
}

/// What a camera can do, from `GetAbility`.
struct PTZAbility: Equatable {
    var panTilt = false
    var zoom = false
    var presets = false

    var any: Bool { panTilt || zoom }
}

struct PTZZoom: Equatable {
    var position: Int
    var range: ClosedRange<Int>
}

/// A position saved on the camera, shared with the Reolink app.
struct PTZPreset: Equatable {
    var id: Int
    var name: String
}

/// One axis at a time: an E1 accepts diagonal moves and ignores them.
enum PTZDirection: String {
    case left = "Left", right = "Right", up = "Up", down = "Down"

    var pan: Int { self == .left ? -1 : self == .right ? 1 : 0 }
    var tilt: Int { self == .down ? -1 : self == .up ? 1 : 0 }
}

/// Pan, tilt and zoom. `CameraAPI` drives a Reolink camera; `PTZSimulator` pretends to be one.
protocol PTZDevice: AnyObject, Sendable {
    func ptzAbility() async throws -> PTZAbility
    func ptzPosition() async throws -> PTZPosition
    /// Starts moving and keeps moving until `ptzStop()`.
    func ptzMove(_ direction: PTZDirection) async throws
    func ptzStop() async throws
    func ptzZoom() async throws -> PTZZoom
    func setZoom(_ position: Int) async throws
    func presets() async throws -> [PTZPreset]
    /// Every preset id, used or not.
    func presetSlots() async throws -> [(id: Int, used: Bool)]
    /// Saves where the camera points now (pan, tilt and zoom) under this id.
    func savePreset(id: Int, name: String) async throws
    func removePreset(id: Int) async throws
    func goToPreset(id: Int) async throws
    func logout() async
}

/// Pan, tilt and zoom over the Reolink HTTP API.
extension CameraAPI: PTZDevice {
    func ptzAbility() async throws -> PTZAbility {
        let value = try await value(of: ["cmd": "GetAbility", "action": 0, "param": ["User": ["userName": userName]]])
        let channel = ((value["Ability"] as? [String: Any])?["abilityChn"] as? [[String: Any]])?.first ?? [:]
        func version(_ key: String) -> Int { (channel[key] as? [String: Any])?["ver"] as? Int ?? 0 }
        // ptzType 1 is zoom only; 2, 3 and 5 pan and tilt (5, the E1 Zoom, also zooms).
        let type = version("ptzType")
        var ability = PTZAbility()
        ability.panTilt = [2, 3, 5].contains(type) && version("ptzCtrl") > 0
        ability.zoom = version("supportZoom") > 0 || [1, 5].contains(type)
        ability.presets = ability.panTilt && version("ptzPreset") > 0
        return ability
    }

    func ptzPosition() async throws -> PTZPosition {
        let value = try await value(of: ["cmd": "GetPtzCurPos", "action": 0, "param": ["PtzCurPos": ["channel": 0]]])
        guard let pos = value["PtzCurPos"] as? [String: Any],
              let pan = pos["Ppos"] as? Int, let tilt = pos["Tpos"] as? Int else { throw APIError.badResponse }
        return PTZPosition(pan: pan, tilt: tilt)
    }

    /// Over ONVIF when the camera has it on. The HTTP API answers one command at a time and may
    /// take most of a second over a move, so a stop sent after it waits while the camera turns.
    /// ONVIF has a server of its own, and answers in about 0.1 s.
    func ptzMove(_ direction: PTZDirection) async throws {
        if let onvif = await onvif() {
            _ = try await onvif.call("<tptz:ContinuousMove><tptz:ProfileToken>\(onvif.profile)</tptz:ProfileToken>"
                + "<tptz:Velocity><tt:PanTilt x=\"\(direction.pan)\" y=\"\(direction.tilt)\"/></tptz:Velocity>"
                + "</tptz:ContinuousMove>")
            return
        }
        // Speed makes little difference on an E1: it turns about 60° a second whatever it is asked.
        _ = try await value(of: ["cmd": "PtzCtrl", "action": 0, "param": ["channel": 0, "op": direction.rawValue, "speed": 32]])
    }

    func ptzStop() async throws {
        try await ptzStop(viaHTTP: false)
    }

    /// `viaHTTP` stops over the HTTP API even when ONVIF is there: a second way through, for when
    /// one of them is slow to answer.
    func ptzStop(viaHTTP: Bool) async throws {
        if !viaHTTP, let onvif = await onvif() {
            _ = try await onvif.call("<tptz:Stop><tptz:ProfileToken>\(onvif.profile)</tptz:ProfileToken>"
                + "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>false</tptz:Zoom></tptz:Stop>")
            return
        }
        _ = try await value(of: ["cmd": "PtzCtrl", "action": 0, "param": ["channel": 0, "op": "Stop"]])
    }

    func ptzZoom() async throws -> PTZZoom {
        let result = try await run([["cmd": "GetZoomFocus", "action": 1, "param": ["channel": 0]]])
        guard let first = result.first else { throw APIError.badResponse }
        if let error = Self.error(in: first) { throw error }
        func section(_ key: String) -> [String: Any]? { (first[key] as? [String: Any])?["ZoomFocus"] as? [String: Any] }
        guard let zoom = (section("value")?["zoom"] as? [String: Any])?["pos"] as? Int else { throw APIError.badResponse }
        var range = 0...max(zoom, 32)
        if let pos = (section("range")?["zoom"] as? [String: Any])?["pos"] as? [String: Any],
           let min = pos["min"] as? Int, let max = pos["max"] as? Int, min < max {
            range = min...max
        }
        return PTZZoom(position: zoom, range: range)
    }

    func setZoom(_ position: Int) async throws {
        _ = try await value(of: ["cmd": "StartZoomFocus", "action": 0,
                                 "param": ["ZoomFocus": ["channel": 0, "pos": position, "op": "ZoomPos"]]])
    }

    func presets() async throws -> [PTZPreset] {
        let value = try await value(of: ["cmd": "GetPtzPreset", "action": 0, "param": ["channel": 0]])
        return (value["PtzPreset"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["enable"] as? Int == 1, let id = item["id"] as? Int else { return nil }
            let name = item["name"] as? String ?? ""
            return PTZPreset(id: id, name: name.isEmpty ? "Position \(id + 1)" : name)
        }
    }

    func presetSlots() async throws -> [(id: Int, used: Bool)] {
        let value = try await value(of: ["cmd": "GetPtzPreset", "action": 0, "param": ["channel": 0]])
        return (value["PtzPreset"] as? [[String: Any]] ?? []).compactMap { item in
            (item["id"] as? Int).map { ($0, item["enable"] as? Int == 1) }
        }
    }

    func savePreset(id: Int, name: String) async throws {
        _ = try await value(of: ["cmd": "SetPtzPreset", "action": 0,
                                 "param": ["PtzPreset": ["channel": 0, "enable": 1, "id": id, "name": name]]])
    }

    func removePreset(id: Int) async throws {
        _ = try await value(of: ["cmd": "SetPtzPreset", "action": 0,
                                 "param": ["PtzPreset": ["channel": 0, "enable": 0, "id": id, "name": "pos\(id + 1)"]]])
    }

    func goToPreset(id: Int) async throws {
        _ = try await value(of: ["cmd": "PtzCtrl", "action": 0, "param": ["channel": 0, "op": "ToPos", "id": id, "speed": 32]])
    }
}

/// The camera's ONVIF PTZ service: SOAP over plain HTTP, with a password digest.
struct ONVIFClient: Sendable {
    let ptz: URL
    let profile: String
    let user: String
    let password: String
    let session: URLSession

    enum Failure: Error { case fault(String) }

    func call(_ body: String, at url: URL? = nil) async throws -> String {
        let created = ISO8601DateFormatter().string(from: Date())
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let digest = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(password.utf8))).base64EncodedString()
        let wss = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss"
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" \
        xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl">\
        <s:Header><Security s:mustUnderstand="1" xmlns="\(wss)-wssecurity-secext-1.0.xsd"><UsernameToken>\
        <Username>\(user.xmlEscaped)</Username>\
        <Password Type="\(wss)-username-token-profile-1.0#PasswordDigest">\(digest)</Password>\
        <Nonce EncodingType="\(wss)-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</Nonce>\
        <Created xmlns="\(wss)-wssecurity-utility-1.0.xsd">\(created)</Created>\
        </UsernameToken></Security></s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
        var request = URLRequest(url: url ?? ptz)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)
        let (data, response) = try await session.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        // The reply repeats the login header: keep the body only.
        let reply = text.range(of: "Body>").map { String(text[$0.upperBound...]) } ?? text
        guard (response as? HTTPURLResponse)?.statusCode == 200, !reply.contains("Fault>") else { throw Failure.fault(reply) }
        return reply
    }
}

extension CameraAPI {
    /// The ONVIF client, once the camera has said where ONVIF is and which profile to steer.
    /// Nil when ONVIF is off or doesn't answer: the HTTP API steers instead.
    func onvif() async -> ONVIFClient? {
        if let known = onvifState.value { return known.client }
        guard let net = try? await value(of: ["cmd": "GetNetPort", "action": 0, "param": ["channel": 0]])["NetPort"] as? [String: Any],
              net["onvifEnable"] as? Int == 1, let port = net["onvifPort"] as? Int,
              let base = URL(string: "http://\(host):\(port)") else {
            onvifState.value = .init(client: nil)
            return nil
        }
        let probe = ONVIFClient(ptz: base.appendingPathComponent("onvif/ptz_service"), profile: "", user: userName,
                                password: password, session: onvifSession)
        var client: ONVIFClient?
        if let reply = try? await probe.call("<trt:GetProfiles/>", at: base.appendingPathComponent("onvif/media_service")),
           let range = reply.range(of: #"Profiles token="([^"]+)""#, options: .regularExpression) {
            let profile = reply[range].split(separator: "\"")[1]
            client = ONVIFClient(ptz: probe.ptz, profile: String(profile), user: userName, password: password, session: onvifSession)
        }
        onvifState.value = .init(client: client)
        return client
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
