import Foundation
import Darwin

/// A minimal read-only SNMPv1 client (GET over UDP), enough to read the printer's network settings.
enum SNMP {
    enum Value: Equatable {
        case integer(Int)
        case octets([UInt8])
        case address(String)
    }

    static func get(host: String, oid: String, community: String = "public", timeout: TimeInterval = 1.5) -> Value? {
        guard let oidBytes = encodeOID(oid) else { return nil }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "161", &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let requestID = Int.random(in: 1...0x7FFF_FFF0)
        let varbind = tlv(0x30, tlv(0x06, oidBytes) + [0x05, 0x00])
        let pdu = tlv(0xA0, tlv(0x02, intBytes(requestID)) + tlv(0x02, [0]) + tlv(0x02, [0]) + tlv(0x30, varbind))
        let message = tlv(0x30, tlv(0x02, [0]) + tlv(0x04, Array(community.utf8)) + pdu)

        let sent = message.withUnsafeBytes { sendto(sock, $0.baseAddress, message.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen) }
        guard sent == message.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = recv(sock, &buffer, buffer.count, 0)
        guard received > 0 else { return nil }
        return parseResponse(Array(buffer[0..<received]), requestID: requestID)
    }

    // MARK: BER

    private static func length(_ count: Int) -> [UInt8] {
        if count < 128 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    private static func intBytes(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    private static func encodeOID(_ oid: String) -> [UInt8]? {
        let arcs = oid.split(separator: ".").compactMap { Int($0) }
        guard arcs.count >= 2, arcs.count == oid.split(separator: ".").count else { return nil }
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            out += chunk
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func next() -> (tag: UInt8, content: ArraySlice<UInt8>)? {
            guard position + 2 <= bytes.count else { return nil }
            let tag = bytes[position]
            var size = Int(bytes[position + 1])
            position += 2
            if size & 0x80 != 0 {
                let count = size & 0x7F
                guard count > 0, count <= 4, position + count <= bytes.count else { return nil }
                size = bytes[position..<position + count].reduce(0) { $0 << 8 | Int($1) }
                position += count
            }
            guard position + size <= bytes.count else { return nil }
            defer { position += size }
            return (tag, bytes[position..<position + size])
        }
    }

    private static func parseResponse(_ bytes: [UInt8], requestID: Int) -> Value? {
        var top = Reader(bytes: bytes)
        guard let message = top.next(), message.tag == 0x30 else { return nil }
        var inner = Reader(bytes: Array(message.content))
        guard inner.next()?.tag == 0x02, inner.next()?.tag == 0x04,
              let pdu = inner.next(), pdu.tag == 0xA2 else { return nil }

        var fields = Reader(bytes: Array(pdu.content))
        guard let id = fields.next(), id.content.reduce(0, { $0 << 8 | Int($1) }) == requestID,
              let status = fields.next(), status.content.allSatisfy({ $0 == 0 }),
              fields.next() != nil,
              let list = fields.next(), list.tag == 0x30 else { return nil }

        var binds = Reader(bytes: Array(list.content))
        guard let bind = binds.next() else { return nil }
        var parts = Reader(bytes: Array(bind.content))
        guard parts.next()?.tag == 0x06, let value = parts.next() else { return nil }

        switch value.tag {
        case 0x02, 0x41, 0x42, 0x43:
            return .integer(value.content.reduce(0) { $0 << 8 | Int($1) })
        case 0x04:
            return .octets(Array(value.content))
        case 0x40 where value.content.count == 4:
            return .address(value.content.map { String($0) }.joined(separator: "."))
        default:
            return nil
        }
    }
}

struct WirelessInfo: Equatable {
    var ssid: String
    var channel: String
    var frequency: String
    var accessPoint: String
    var ipAddress: String
    var subnetMask: String
    var gateway: String
    var hostName: String
    var macAddress: String
    var firmware: String

    private static let base = "1.3.6.1.4.1.236.11.5.11.53."

    /// Reads the printer's current Wi-Fi and TCP/IP settings. Returns nil if SNMP does not answer.
    static func read(host: String) -> WirelessInfo? {
        func text(_ oid: String) -> String {
            switch SNMP.get(host: host, oid: oid) {
            case .octets(let bytes)?: return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            case .address(let value)?: return value
            case .integer(let value)?: return String(value)
            case nil: return ""
            }
        }
        let ssid = text(base + "51.2.2.2.0")
        let ip = text(base + "51.11.1.1.11.1")
        guard !ssid.isEmpty || !ip.isEmpty else { return nil }

        var mac = ""
        if case .octets(let raw)? = SNMP.get(host: host, oid: "1.3.6.1.2.1.2.2.1.6.1") {
            mac = raw.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return WirelessInfo(
            ssid: ssid,
            channel: text(base + "51.2.2.7.0"),
            frequency: text(base + "51.2.2.4.0"),
            accessPoint: text(base + "51.2.2.5.0"),
            ipAddress: ip,
            subnetMask: text(base + "51.11.1.1.12.1"),
            gateway: text(base + "51.11.1.1.13.1"),
            hostName: text(base + "51.14.1.1.2.1.1"),
            macAddress: mac,
            firmware: text(base + "31.1.5.0")
        )
    }
}
