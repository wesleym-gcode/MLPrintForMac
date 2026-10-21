import Foundation

/// Minimal IPP 2.0 codec: just enough to query a printer and submit jobs.
enum IPPOperation: UInt16 {
    case printJob = 0x0002
    case cancelJob = 0x0008
    case getJobAttributes = 0x0009
    case getJobs = 0x000A
    case getPrinterAttributes = 0x000B
}

enum IPPValue: Equatable {
    case integer(Int)
    case boolean(Bool)
    case string(String)

    var text: String {
        switch self {
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .string(let value): return value
        }
    }

    var int: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }
}

typealias IPPAttributes = [String: [IPPValue]]

struct IPPResponse {
    var status: UInt16
    /// One dictionary per attribute group, in order. Group 0 is the operation group.
    var groups: [IPPAttributes]

    var isSuccess: Bool { status < 0x0100 }
    var printer: IPPAttributes { groups.first(where: { $0["printer-state"] != nil }) ?? [:] }

    var statusText: String {
        switch status {
        case 0x0000, 0x0001, 0x0002: return "ok"
        case 0x0400: return "requisição inválida"
        case 0x0404: return "impressora não encontrada"
        case 0x0405: return "tempo esgotado"
        case 0x040A: return "formato de documento não suportado"
        case 0x0507: return "impressora ocupada"
        default: return String(format: "erro IPP 0x%04X", status)
        }
    }
}

enum IPPError: LocalizedError {
    case malformed
    case http(Int)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .malformed: return "Resposta IPP inválida."
        case .http(let code): return "A impressora respondeu HTTP \(code)."
        case .operation(let text): return "A impressora recusou a operação: \(text)."
        }
    }
}

struct IPPRequest {
    var operation: IPPOperation
    var requestID: UInt32 = 1
    private var groups: [(tag: UInt8, attrs: [(tag: UInt8, name: String, values: [Data])])] = []

    init(operation: IPPOperation, printerURI: String, user: String) {
        self.operation = operation
        beginGroup(0x01)
        add(0x47, "attributes-charset", "utf-8")
        add(0x48, "attributes-natural-language", "pt-br")
        add(0x45, "printer-uri", printerURI)
        add(0x42, "requesting-user-name", user)
    }

    mutating func beginGroup(_ tag: UInt8) {
        groups.append((tag, []))
    }

    mutating func add(_ tag: UInt8, _ name: String, _ value: String) {
        groups[groups.count - 1].attrs.append((tag, name, [Data(value.utf8)]))
    }

    mutating func add(keywords name: String, _ values: [String]) {
        groups[groups.count - 1].attrs.append((0x44, name, values.map { Data($0.utf8) }))
    }

    mutating func add(integer name: String, _ value: Int, tag: UInt8 = 0x21) {
        var big = Int32(value).bigEndian
        groups[groups.count - 1].attrs.append((tag, name, [Data(bytes: &big, count: 4)]))
    }

    mutating func add(boolean name: String, _ value: Bool) {
        groups[groups.count - 1].attrs.append((0x22, name, [Data([value ? 1 : 0])]))
    }

    func encoded(document: Data? = nil) -> Data {
        var out = Data([0x02, 0x00])
        out.append(contentsOf: withUnsafeBytes(of: operation.rawValue.bigEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: requestID.bigEndian, Array.init))
        for group in groups {
            out.append(group.tag)
            for attr in group.attrs {
                for (index, value) in attr.values.enumerated() {
                    out.append(attr.tag)
                    let name = index == 0 ? Data(attr.name.utf8) : Data()
                    out.append(contentsOf: withUnsafeBytes(of: UInt16(name.count).bigEndian, Array.init))
                    out.append(name)
                    out.append(contentsOf: withUnsafeBytes(of: UInt16(value.count).bigEndian, Array.init))
                    out.append(value)
                }
            }
        }
        out.append(0x03)
        if let document { out.append(document) }
        return out
    }
}

enum IPPDecoder {
    static func decode(_ data: Data) throws -> IPPResponse {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { throw IPPError.malformed }
        let status = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        var position = 8
        var groups: [IPPAttributes] = []
        var current: IPPAttributes?
        var lastName: String?
        var collectionDepth = 0

        func u16() throws -> Int {
            guard position + 2 <= bytes.count else { throw IPPError.malformed }
            defer { position += 2 }
            return Int(bytes[position]) << 8 | Int(bytes[position + 1])
        }

        while position < bytes.count {
            let tag = bytes[position]
            position += 1
            if tag == 0x03 { break }
            if tag <= 0x05 {
                if let current { groups.append(current) }
                current = [:]
                lastName = nil
                continue
            }
            let nameLength = try u16()
            guard position + nameLength <= bytes.count else { throw IPPError.malformed }
            let name = String(decoding: bytes[position..<position + nameLength], as: UTF8.self)
            position += nameLength
            let valueLength = try u16()
            guard position + valueLength <= bytes.count else { throw IPPError.malformed }
            let raw = Array(bytes[position..<position + valueLength])
            position += valueLength

            if tag == 0x34 { collectionDepth += 1; continue }
            if tag == 0x37 { collectionDepth = max(0, collectionDepth - 1); continue }
            if collectionDepth > 0 || tag == 0x4A { continue }

            let key = nameLength == 0 ? lastName : name
            guard let key else { continue }
            if nameLength > 0 { lastName = name }

            let value: IPPValue
            switch tag {
            case 0x21, 0x23 where raw.count == 4:
                value = .integer(Int(Int32(bitPattern: raw.reduce(0) { $0 << 8 | UInt32($1) })))
            case 0x22:
                value = .boolean(raw.first == 1)
            case 0x33, 0x35, 0x36, 0x37, 0x13:
                continue
            default:
                value = .string(String(decoding: raw, as: UTF8.self))
            }
            current?[key, default: []].append(value)
        }
        if let current { groups.append(current) }
        return IPPResponse(status: status, groups: groups)
    }
}
