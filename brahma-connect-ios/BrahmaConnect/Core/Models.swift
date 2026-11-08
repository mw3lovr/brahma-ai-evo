import Foundation

enum ConnectionState: String {
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
    case disconnected = "DISCONNECTED"
    case reconnecting = "RECONNECTING"
}

struct GatewayEndpoint: Equatable {
    var name: String
    var host: String
    var port: Int
    var online: Bool = true
}

struct PairingOffer: Codable, Equatable {
    var service: String
    var host: String
    var port: Int
    var pairingToken: String
    var pairingCode: String
    var expiresInSeconds: Int
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case service, host, port
        case pairingToken = "pairing_token"
        case pairingCode = "pairing_code"
        case expiresInSeconds = "expires"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = (try? c.decode(String.self, forKey: .service)) ?? ""
        host = try c.decode(String.self, forKey: .host)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 8765
        pairingToken = (try? c.decode(String.self, forKey: .pairingToken)) ?? ""
        pairingCode = (try? c.decode(String.self, forKey: .pairingCode)) ?? ""
        expiresInSeconds = (try? c.decode(Int.self, forKey: .expiresInSeconds)) ?? 0
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    static func parse(_ raw: String) -> PairingOffer? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let offer = try? JSONDecoder().decode(PairingOffer.self, from: data), !offer.host.isEmpty else { return nil }
        return offer
    }
}

struct DeviceCredential: Codable, Equatable {
    var deviceId: String
    var deviceSecret: String
    var deviceName: String
    var gatewayHost: String
    var gatewayPort: Int
    var pairedAt: String = ISO8601DateFormatter().string(from: Date())

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceSecret = "device_secret"
        case deviceName = "device_name"
        case gatewayHost = "gateway_host"
        case gatewayPort = "gateway_port"
        case pairedAt = "paired_at"
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date
    var status: String
}

struct CommandResult {
    var success: Bool
    var data: [String: Any] = [:]
    var errorCode: String? = nil
    var error: String? = nil

    static func fail(_ code: String, _ message: String) -> CommandResult {
        CommandResult(success: false, errorCode: code, error: message)
    }

    func toJson() -> [String: Any] {
        var json: [String: Any] = ["success": success]
        if !data.isEmpty { json["data"] = data }
        if let errorCode, !errorCode.isEmpty { json["error_code"] = errorCode }
        if let error, !error.isEmpty { json["error"] = error }
        return json
    }
}

enum BrahmaProtocol {
    static let hello = "hello"
    static let pairRequest = "pair_request"
    static let pairApproved = "pair_approved"
    static let authenticate = "authenticate"
    static let deviceOnline = "device_online"
    static let deviceOffline = "device_offline"
    static let capabilities = "capabilities"
    static let execute = "execute"
    static let result = "result"
    static let event = "event"
    static let error = "error"
    static let ping = "ping"
    static let pong = "pong"
    static let chatMessage = "chat_message"

    static func newRequestId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func envelope(_ type: String, payload: [String: Any] = [:], requestId: String = newRequestId()) -> [String: Any] {
        [
            "type": type,
            "request_id": requestId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "payload": payload,
        ]
    }
}

enum BrahmaConnectCapabilities {
    // Capabilities iOS can actually honour. Android-only features (accessibility
    // autopilot, launching arbitrary apps, unlocking) are intentionally absent.
    static let initial = [
        "device_info",
        "battery",
        "flashlight",
        "volume",
        "open_url",
        "launch_app",
        "files",
        "wifi_state",
    ]
}
