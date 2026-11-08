import Foundation

/// Swift counterpart of the Android `AgentStateStore`: one observable source of truth for the UI.
@MainActor
final class AgentState: ObservableObject {
    static let shared = AgentState()

    @Published var connectionState: ConnectionState = .disconnected
    @Published var gateway: GatewayEndpoint?
    @Published var pairingOffer: PairingOffer?
    @Published var credential: DeviceCredential?
    @Published var statusText: String = "Ready"
    @Published var lastError: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var chatHistory: [ChatMessage] = []

    func addLog(_ message: String) {
        logs = Array((logs + [message]).suffix(50))
    }

    func addChatMessage(_ message: ChatMessage) {
        var current = chatHistory
        if let index = current.firstIndex(where: { $0.id == message.id }) {
            current[index] = message
        } else {
            current.append(message)
        }
        chatHistory = current
    }
}
