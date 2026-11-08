import Foundation
import Network

/// Bonjour discovery of the `_BRAHMA._tcp` service advertised by the PC gateway
/// (replaces Android's NsdManager).
final class GatewayDiscovery {
    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.brahma.connect.discovery")

    func start(onFound: @escaping @MainActor (GatewayEndpoint) -> Void, onError: @escaping @MainActor (String) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_BRAHMA._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Task { @MainActor in onError("Discovery failed: \(error.localizedDescription)") }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                self.resolve(result.endpoint, name: name, onFound: onFound)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// NWBrowser yields service endpoints, not addresses. Open a short-lived TCP
    /// connection to learn the resolved host/port, then hand that to the WebSocket client.
    private func resolve(_ endpoint: NWEndpoint, name: String, onFound: @escaping @MainActor (GatewayEndpoint) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        resolving.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    var hostString = "\(host)"
                    if let percent = hostString.firstIndex(of: "%") { hostString = String(hostString[..<percent]) }
                    let gateway = GatewayEndpoint(name: name, host: hostString, port: Int(port.rawValue))
                    Task { @MainActor in onFound(gateway) }
                }
                connection.cancel()
            case .failed, .cancelled:
                self?.queue.async { self?.resolving.removeAll { $0 === connection } }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.forEach { $0.cancel() }
        resolving.removeAll()
    }
}
