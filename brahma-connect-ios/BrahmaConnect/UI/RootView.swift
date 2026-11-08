import SwiftUI

enum Route: Hashable {
    case welcome, about, connect, scanner, splash, home, chat
}

enum Palette {
    static let background = Color(red: 0x02 / 255, green: 0x03 / 255, blue: 0x05 / 255)
    static let accent = Color.white
    static let cyan = Color(red: 0, green: 0xE5 / 255, blue: 1)
    static let muted = Color(red: 0x8E / 255, green: 0x94 / 255, blue: 0x9D / 255)
    static let error = Color(red: 1, green: 0x6B / 255, blue: 0x6B / 255)
}

/// Mirrors the Android NavHost: one route at a time, cross-faded, over a single
/// holographic WebGL background that never reloads.
struct RootView: View {
    @EnvironmentObject private var state: AgentState
    @State private var route: Route = .welcome

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            HolographicBackground().ignoresSafeArea()

            screen
                .id(route)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.4), value: route)
        .onChange(of: state.credential) { credential in
            if credential != nil, route != .home, route != .chat { route = .splash }
        }
        .onAppear {
            if state.credential != nil {
                route = .home
                BrahmaWebSocketClient.shared.connectIfPossible()
            }
            BrahmaWebSocketClient.shared.commandHandler.attachVolumeView(
                to: UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch route {
        case .welcome:
            WelcomeView { route = .about }
        case .about:
            AboutView { route = .connect }
        case .connect:
            ConnectView(onScan: { route = .scanner })
        case .scanner:
            BackBar(title: "Scan QR", onBack: { route = .connect }) {
                ScannerScreen { route = .connect }
            }
        case .splash:
            ConnectedSplashView { route = state.credential != nil ? .home : .connect }
        case .home:
            if let credential = state.credential {
                HomeView(credential: credential, onOpenChat: { route = .chat })
            } else {
                WelcomeView { route = .about }
            }
        case .chat:
            BackBar(title: "Brahma Chat", onBack: { route = .home }) { ChatView() }
        }
    }
}

struct BackBar<Content: View>: View {
    let title: String
    var onBack: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.headline).foregroundStyle(.white)
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .background(.black.opacity(0.4))
            content.frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Shared chrome

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 16) { content }
            .padding(24)
            .frame(maxWidth: 520)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.accent.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 24)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.black)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white)
            .overlay(Capsule().stroke(Palette.accent.opacity(configuration.isPressed ? 0.4 : 0.7), lineWidth: 1))
    }
}

// MARK: - Onboarding

struct WelcomeView: View {
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("BRAHMA").font(.system(size: 56, weight: .black)).foregroundStyle(Palette.accent)
            Text("CONNECT").font(.system(size: 28, weight: .light)).foregroundStyle(.white)
            Spacer().frame(height: 60)
            GlassCard {
                Text("Welcome to the neural bridge.").foregroundStyle(.white)
                Button("Get Started", action: onNext).buttonStyle(PrimaryButtonStyle())
            }
            Spacer()
        }
    }
}

struct AboutView: View {
    var onNext: () -> Void

    var body: some View {
        VStack {
            Spacer()
            GlassCard {
                Text("Hardware Bridge").font(.title2.bold()).foregroundStyle(Palette.accent)
                Text("This agent acts as a secure physical bridge between your iPhone and your PC's Brahma AI.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Next", action: onNext).buttonStyle(PrimaryButtonStyle())
            }
            Spacer()
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject private var state: AgentState
    var onScan: () -> Void

    @State private var discovery = GatewayDiscovery()
    @State private var discovering = false
    @State private var showManual = false
    @State private var manualHost = ""
    @State private var manualPort = "8765"

    var body: some View {
        VStack {
            Spacer()
            if let offer = state.pairingOffer {
                pairingPending(offer)
            } else {
                GlassCard {
                    Text("Pair Device").font(.title2.bold()).foregroundStyle(Palette.accent)
                    Button("Scan QR Code", action: onScan).buttonStyle(PrimaryButtonStyle())
                    Button(discovering ? "Searching…" : "Auto Discover") { startDiscovery() }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(discovering)
                    Button("Enter IP Manually") { showManual = true }.foregroundStyle(.white)
                    if state.gateway != nil, state.connectionState != .disconnected || state.statusText != "Ready" {
                        HStack(spacing: 8) {
                            if state.connectionState != .disconnected { ProgressView().tint(.white) }
                            Text("\(state.gateway?.host ?? ""): \(state.statusText)")
                                .font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }
                    if let error = state.lastError {
                        Text(error).font(.footnote).foregroundStyle(Palette.error)
                    }
                }
            }
            Spacer()
        }
        .onDisappear { discovery.stop() }
        .alert("Connect to Brahma", isPresented: $showManual) {
            TextField("PC IP address", text: $manualHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: $manualPort).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Connect") {
                let host = manualHost.trimmingCharacters(in: .whitespaces)
                guard !host.isEmpty else { return }
                connect(to: GatewayEndpoint(name: "Brahma PC", host: host, port: Int(manualPort) ?? 8765))
                state.statusText = "Manual endpoint selected"
            }
        } message: {
            Text("Enter the address shown in Brahma on your PC.")
        }
    }

    @ViewBuilder
    private func pairingPending(_ offer: PairingOffer) -> some View {
        GlassCard {
            Text("CONNECT TO BRAHMA?").font(.title3.weight(.black)).foregroundStyle(.white)
            Text("\(state.gateway?.name ?? "Brahma PC")\n\(state.gateway?.host ?? offer.host):\(offer.port)")
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pair this device?")
                Text("Code \(offer.pairingCode)").bold()
                Text("State: \(state.connectionState.rawValue)")
                Text("Status: \(state.statusText)")
                if let error = state.lastError { Text(error).foregroundStyle(Palette.error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            Button("Request Pairing") {
                BrahmaWebSocketClient.shared.connectIfPossible()
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Cancel") {
                BrahmaWebSocketClient.shared.disconnect()
                PairingStorage.shared.clearGatewayHint()
                state.pairingOffer = nil
            }
            .buttonStyle(OutlineButtonStyle())
        }
    }

    private func startDiscovery() {
        discovering = true
        state.lastError = nil
        discovery.start(onFound: { endpoint in
            guard discovering else { return }
            discovering = false
            discovery.stop()
            state.statusText = "Gateway Online"
            connect(to: endpoint)
        }, onError: { message in
            discovering = false
            state.lastError = message
        })
    }

    private func connect(to endpoint: GatewayEndpoint) {
        state.gateway = endpoint
        BrahmaWebSocketClient.shared.connectIfPossible()
    }
}

struct ScannerScreen: View {
    @EnvironmentObject private var state: AgentState
    var onDone: () -> Void
    @State private var scanError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView(onScanned: { raw in
                guard let offer = PairingOffer.parse(raw) else {
                    scanError = "That QR code does not look like a Brahma pairing code."
                    return
                }
                scanError = nil
                PairingStorage.shared.saveGatewayHint(offer)
                state.pairingOffer = offer
                state.gateway = GatewayEndpoint(name: "Brahma PC", host: offer.host, port: offer.port)
                state.statusText = "Pairing payload loaded"
                onDone()
            }, onError: { scanError = $0 })
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 24)
                .stroke(Palette.cyan, lineWidth: 3)
                .frame(width: 240, height: 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(scanError ?? "Point the camera at the pairing QR code on your PC.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(scanError == nil ? .white : Palette.error)
                .padding()
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
        }
    }
}

struct ConnectedSplashView: View {
    var onFinished: () -> Void

    var body: some View {
        VStack {
            Spacer()
            GlassCard {
                Text("Connection Established").font(.title3).foregroundStyle(Palette.accent)
                ProgressView().tint(Palette.accent)
            }
            Spacer()
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onFinished()
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var state: AgentState
    let credential: DeviceCredential
    var onOpenChat: () -> Void
    @State private var confirmForget = false

    private var connected: Bool { state.connectionState == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BRAHMA CONNECT").font(.title2.weight(.black)).foregroundStyle(.white)
                Text(connected ? "● Connected" : "● \(state.connectionState.rawValue.capitalized)")
                    .foregroundStyle(connected ? Palette.accent : Palette.muted)

                card {
                    Text(state.gateway?.name ?? "Brahma PC").bold()
                    Text(credential.deviceName)
                    Text("Gateway: \(state.gateway?.host ?? credential.gatewayHost):\(state.gateway?.port ?? credential.gatewayPort)")
                    Text("State: \(state.connectionState.rawValue)")
                    Text(state.statusText).foregroundStyle(Palette.muted)
                    if let error = state.lastError { Text(error).foregroundStyle(Palette.error) }
                }

                Button(action: onOpenChat) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Palette.cyan)
                        VStack(alignment: .leading) {
                            Text("Brahma Chat").font(.headline)
                            Text("Synchronized with your PC").font(.caption).foregroundStyle(Palette.accent.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.3)))
                }

                if state.connectionState == .disconnected {
                    Button("Reconnect") { BrahmaWebSocketClient.shared.connectIfPossible() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Disconnect") { BrahmaWebSocketClient.shared.disconnect() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Forget this PC") { confirmForget = true }
                    .buttonStyle(OutlineButtonStyle())
                Button("Permissions") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(OutlineButtonStyle())

                Text("Note: iOS pauses the connection while Brahma Connect is in the background. Keep the app open for the PC to control this device.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)

                Text("Recent Logs").bold().foregroundStyle(.white)
                ForEach(Array(state.logs.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(Palette.muted)
                }
            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Forget this PC?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { BrahmaWebSocketClient.shared.forgetPairing() }
        } message: {
            Text("You will need to pair again from Brahma on your PC.")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.3)))
    }
}
