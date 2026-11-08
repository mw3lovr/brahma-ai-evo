import Foundation
import UIKit

/// Port of the Android `BrahmaWebSocketClient` + `BrahmaConnectForegroundService`.
/// Speaks the same JSON envelope protocol to the Brahma Gateway at ws://host:port/ws.
@MainActor
final class BrahmaWebSocketClient: NSObject {
    static let shared = BrahmaWebSocketClient()

    private let state = AgentState.shared
    private let storage = PairingStorage.shared
    let commandHandler = DeviceCommandHandler()

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var socket: URLSessionWebSocketTask?
    private var currentEndpoint: GatewayEndpoint?
    private var currentOffer: PairingOffer?
    private var currentCredential: DeviceCredential?
    private var manualDisconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    /// Equivalent of the Android service's `connectIfPossible()`.
    func connectIfPossible() {
        guard let endpoint = state.gateway else { return }
        let credential = storage.loadCredential()
        let offer = state.pairingOffer ?? storage.loadGatewayHint()
        connect(endpoint, credential: credential, offer: offer)
    }

    func connect(_ endpoint: GatewayEndpoint, credential: DeviceCredential?, offer: PairingOffer?) {
        if socket != nil && currentEndpoint == endpoint {
            currentCredential = credential ?? currentCredential
            currentOffer = offer ?? currentOffer
            state.gateway = endpoint
            return
        }
        reconnectTask?.cancel()
        currentEndpoint = endpoint
        currentCredential = credential
        currentOffer = offer
        manualDisconnect = false
        state.gateway = endpoint
        state.connectionState = .connecting
        state.statusText = "Connecting to \(endpoint.name)"

        socket?.cancel(with: .normalClosure, reason: nil)
        guard let url = URL(string: "ws://\(Self.formatHost(endpoint.host)):\(endpoint.port)/ws") else {
            state.lastError = "Invalid gateway address: \(endpoint.host)"
            state.connectionState = .disconnected
            return
        }
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        keepAliveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: "Disconnected by user".data(using: .utf8))
        socket = nil
        currentEndpoint = nil
        state.connectionState = .disconnected
        state.statusText = "Disconnected"
    }

    func forgetPairing() {
        disconnect()
        storage.clearCredential()
        storage.clearGatewayHint()
        state.credential = nil
        state.pairingOffer = nil
        state.gateway = nil
    }

    func sendChatMessage(_ text: String) {
        let envelope = BrahmaProtocol.envelope(BrahmaProtocol.chatMessage, payload: ["text": text])
        let id = envelope["request_id"] as? String ?? BrahmaProtocol.newRequestId()
        var message = ChatMessage(id: id, role: "user", text: text, timestamp: Date(), status: "Sending...")
        state.addChatMessage(message)
        send(envelope)
        message.status = socket == nil ? "Not connected" : "Sent"
        state.addChatMessage(message)
    }

    // MARK: - Internals

    private static func formatHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private func send(_ json: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            if let error { Task { @MainActor in self?.state.addLog("Send failed: \(error.localizedDescription)") } }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure(let error):
                    self.handleClosed("Socket failure: \(error.localizedDescription)", status: "Connection failed")
                }
            }
        }
    }

    private func handleClosed(_ log: String, status: String) {
        socket = nil
        keepAliveTask?.cancel()
        state.addLog(log)
        state.connectionState = .disconnected
        state.statusText = status
        reconnectLater()
    }

    private func reconnectLater() {
        guard !manualDisconnect, let endpoint = currentEndpoint else { return }
        reconnectAttempt += 1
        state.connectionState = .reconnecting
        let delay = min(30, 1 << min(reconnectAttempt, 5))
        state.statusText = "Reconnecting in \(delay)s"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.manualDisconnect, self.currentEndpoint == endpoint else { return }
            self.currentEndpoint = nil  // force a fresh socket
            self.connect(endpoint, credential: self.currentCredential, offer: self.currentOffer)
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.socket?.sendPing { _ in }
            }
        }
    }

    private func buildSnapshot() -> [String: Any] {
        let battery = commandHandler.batterySnapshot()
        return [
            "device_id": currentCredential?.deviceId ?? NSNull(),
            "device_name": currentCredential?.deviceName ?? UIDevice.current.name,
            "platform": "ios",
            "os_version": UIDevice.current.systemVersion,
            "agent_version": DeviceCommandHandler.agentVersion,
            "battery": battery.percentage,
            "charging": battery.charging,
            "wifi_state": commandHandler.wifiConnected ? "connected" : "disconnected",
            "capabilities": BrahmaConnectCapabilities.initial,
            "permissions": [String](),
            "metadata": ["model": DeviceCommandHandler.modelIdentifier()],
        ]
    }

    private func sendHello() {
        send(BrahmaProtocol.envelope(BrahmaProtocol.hello, payload: buildSnapshot()))
        state.statusText = "Awaiting approval"
    }

    private func sendPairRequest() {
        guard let offer = currentOffer else { return sendHello() }
        var payload = buildSnapshot()
        payload["pairing_token"] = offer.pairingToken
        payload["pairing_code"] = offer.pairingCode
        send(BrahmaProtocol.envelope(BrahmaProtocol.pairRequest, payload: payload))
        state.statusText = "Pairing request sent"
    }

    private func sendAuthenticate() {
        guard let credential = currentCredential ?? storage.loadCredential() else { return sendHello() }
        currentCredential = credential
        send(BrahmaProtocol.envelope(BrahmaProtocol.authenticate, payload: [
            "device_id": credential.deviceId,
            "device_secret": credential.deviceSecret,
        ]))
        state.statusText = "Authenticating"
    }

    private func onOpen() {
        reconnectAttempt = 0
        state.connectionState = .connecting
        startKeepAlive()
        if currentCredential != nil || storage.loadCredential() != nil {
            sendAuthenticate()
        } else if currentOffer != nil {
            sendPairRequest()
        } else {
            sendHello()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            state.lastError = "Malformed message from gateway"
            return
        }
        let type = root["type"] as? String ?? ""
        let requestId = root["request_id"] as? String ?? BrahmaProtocol.newRequestId()
        let payload = root["payload"] as? [String: Any] ?? [:]

        switch type {
        case BrahmaProtocol.pairRequest:
            state.statusText = "Waiting for approval"
        case BrahmaProtocol.pairApproved:
            handlePairApproved(payload)
        case BrahmaProtocol.deviceOnline:
            state.connectionState = .connected
            state.statusText = "Connected"
            state.lastError = nil
        case BrahmaProtocol.capabilities:
            state.addLog("Capabilities synced")
        case BrahmaProtocol.execute:
            let action = payload["action"] as? String ?? ""
            let parameters = payload["parameters"] as? [String: Any] ?? [:]
            let result = commandHandler.handle(action, parameters)
            state.addLog("Executed \(action): \(result.success ? "ok" : (result.errorCode ?? "error"))")
            send(BrahmaProtocol.envelope(BrahmaProtocol.result, payload: result.toJson(), requestId: requestId))
        case BrahmaProtocol.ping:
            send(BrahmaProtocol.envelope(BrahmaProtocol.pong, payload: ["status": "ok"], requestId: requestId))
        case BrahmaProtocol.error:
            state.lastError = payload["error"] as? String
        case BrahmaProtocol.chatMessage:
            let message = ChatMessage(
                id: requestId,
                role: payload["role"] as? String ?? "system",
                text: payload["text"] as? String ?? "",
                timestamp: Date(),
                status: "Sent"
            )
            state.addChatMessage(message)
        default:
            break
        }
    }

    private func handlePairApproved(_ payload: [String: Any]) {
        let device = payload["device"] as? [String: Any] ?? [:]
        let credential = DeviceCredential(
            deviceId: device["device_id"] as? String ?? "",
            deviceSecret: payload["device_secret"] as? String ?? "",
            deviceName: device["name"] as? String ?? UIDevice.current.name,
            gatewayHost: currentEndpoint?.host ?? "",
            gatewayPort: currentEndpoint?.port ?? 8765
        )
        storage.saveCredential(credential)
        currentCredential = credential
        state.credential = credential
        state.statusText = "Pair approved"
        sendAuthenticate()
    }
}

extension BrahmaWebSocketClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.socket else { return }
            self.onOpen()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard webSocketTask === self.socket else { return }
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.handleClosed("Socket closed: \(closeCode.rawValue) \(text)", status: "Disconnected")
        }
    }
}
