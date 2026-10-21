import Foundation
import Network

struct DiscoveredPrinter: Identifiable, Hashable {
    var id: String { host ?? name }
    var name: String
    /// Host to use for IPP: the `.local` name derived from the service name, or an address found by scanning.
    var host: String?
    fileprivate var endpoint: NWEndpoint?
}

/// Finds IPP printers via Bonjour.
@MainActor
final class PrinterDiscovery: ObservableObject {
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var scanning = false
    private var bonjour: [DiscoveredPrinter] = []
    private var scanned: [DiscoveredPrinter] = []
    private var browser: NWBrowser?

    private func publish() {
        var seen = Set<String>()
        printers = (bonjour + scanned)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name < $1.name }
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_ipp._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredPrinter] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredPrinter(name: name, host: Self.hostName(from: name), endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.bonjour = found
                self?.publish()
            }
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
        guard let endpoint = printer.endpoint else { return nil }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
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

    // MARK: Subnet scan

    /// Probes every address of the local /24 for an IPP printer. Works even when a printer does not
    /// answer Bonjour, which some firmware stops doing after a while.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }

        let addresses = await Task.detached { Self.localSubnetAddresses() }.value
        var found: [DiscoveredPrinter] = []
        await withTaskGroup(of: DiscoveredPrinter?.self) { group in
            var iterator = addresses.makeIterator()
            func addNext() {
                guard let address = iterator.next() else { return }
                group.addTask {
                    guard let status = try? await PrinterClient(host: address).status(timeout: 1.5) else { return nil }
                    return DiscoveredPrinter(name: "\(status.model) (\(address))", host: address, endpoint: nil)
                }
            }
            for _ in 0..<48 { addNext() }
            for await result in group {
                if let result { found.append(result) }
                addNext()
            }
        }
        scanned = found
        publish()
    }

    /// Addresses of the Mac's primary IPv4 network (limited to a /24), excluding the Mac itself.
    nonisolated private static func localSubnetAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            let flags = Int32(current.pointee.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip >> 24 != 169 else { continue }  // link-local
            let base = ip & 0xFFFF_FF00
            return (1...254).map { base | UInt32($0) }.filter { $0 != ip }.map {
                "\($0 >> 24).\(($0 >> 16) & 255).\(($0 >> 8) & 255).\($0 & 255)"
            }
        }
        return []
    }
}
