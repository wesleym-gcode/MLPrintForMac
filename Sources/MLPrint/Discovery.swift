import Foundation
import Network

struct DiscoveredPrinter: Identifiable, Hashable {
    var id: String { name }
    var name: String
    /// Host to use for IPP: the `.local` name derived from the service name when available.
    var host: String?
    fileprivate var endpoint: NWEndpoint
}

/// Finds IPP printers via Bonjour.
@MainActor
final class PrinterDiscovery: ObservableObject {
    @Published private(set) var printers: [DiscoveredPrinter] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_ipp._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredPrinter] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredPrinter(name: name, host: Self.hostName(from: name), endpoint: result.endpoint)
            }
            Task { @MainActor in self?.printers = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Samsung printers advertise "Model (SECxxxxxxxxxxxx)"; the id is also the mDNS host name.
    nonisolated private static func hostName(from name: String) -> String? {
        guard let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else { return nil }
        let id = name[name.index(after: open)..<close]
        guard id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        return "\(id).local"
    }

    /// Resolves a discovered service to an IPv4 address.
    func resolveAddress(of printer: DiscoveredPrinter) async -> String? {
        if let host = printer.host { return host }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: printer.endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        let text = "\(host)"
                        continuation.resume(returning: text.split(separator: "%").first.map(String.init))
                    } else {
                        continuation.resume(returning: nil)
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    finished = true
                    continuation.resume(returning: nil)
                default: break
                }
            }
            connection.start(queue: .main)
        }
    }
}
