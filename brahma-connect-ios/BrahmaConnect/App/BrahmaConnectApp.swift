import SwiftUI

@main
struct BrahmaConnectApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = AgentState.shared

    init() {
        let state = AgentState.shared
        let storage = PairingStorage.shared
        state.credential = storage.loadCredential()
        if let offer = storage.loadGatewayHint() {
            state.pairingOffer = offer
            state.gateway = GatewayEndpoint(name: "Brahma PC", host: offer.host, port: offer.port)
        } else if let credential = state.credential, !credential.gatewayHost.isEmpty {
            state.gateway = GatewayEndpoint(name: "Brahma PC", host: credential.gatewayHost, port: credential.gatewayPort)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
        .onChange(of: scenePhase) { phase in
            // iOS has no equivalent of Android's foreground service: the socket is
            // suspended in the background, so reconnect whenever we become active.
            if phase == .active, state.credential != nil {
                BrahmaWebSocketClient.shared.connectIfPossible()
            }
        }
    }
}
