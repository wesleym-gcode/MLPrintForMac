import Foundation

struct PrinterStatus: Equatable {
    var name: String
    var model: String
    var state: State
    var reasons: [String]
    var message: String

    enum State: Equatable {
        case idle, processing, stopped, unknown
    }

    /// Reasons that are only informational ("none", "-report" suffix variants).
    var activeReasons: [String] { reasons.filter { $0 != "none" } }
}

struct PrintJobInfo: Identifiable, Equatable {
    var id: Int
    var name: String
    var state: String
    var user: String

    var stateText: String {
        switch state {
        case "3": return "Na fila"
        case "4": return "Retido"
        case "5": return "Imprimindo"
        case "6": return "Parado"
        case "7": return "Cancelado"
        case "8": return "Abortado"
        case "9": return "Concluído"
        default: return state
        }
    }
}

/// Talks IPP to one printer over HTTP.
struct PrinterClient {
    let host: String
    var port = 631
    var path = "/ipp/printer"
    var user = NSUserName()

    private var printerURI: String { "ipp://\(host):\(port)\(path)" }

    private var httpURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    private func send(_ request: IPPRequest, document: Data? = nil, timeout: TimeInterval = 15) async throws -> IPPResponse {
        guard let url = httpURL else { throw IPPError.malformed }
        var http = URLRequest(url: url, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        http.httpBody = request.encoded(document: document)
        let (data, response) = try await URLSession.shared.data(for: http)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw IPPError.http(status)
        }
        return try IPPDecoder.decode(data)
    }

    func status(timeout: TimeInterval = 6) async throws -> PrinterStatus {
        var request = IPPRequest(operation: .getPrinterAttributes, printerURI: printerURI, user: user)
        request.add(keywords: "requested-attributes", [
            "printer-name", "printer-make-and-model", "printer-state",
            "printer-state-reasons", "printer-state-message",
        ])
        let response = try await send(request, timeout: timeout)
        guard response.isSuccess else { throw IPPError.operation(response.statusText) }
        let attrs = response.printer
        let state: PrinterStatus.State
        switch attrs["printer-state"]?.first?.int {
        case 3: state = .idle
        case 4: state = .processing
        case 5: state = .stopped
        default: state = .unknown
        }
        return PrinterStatus(
            name: attrs["printer-name"]?.first?.text ?? host,
            model: attrs["printer-make-and-model"]?.first?.text ?? "Impressora IPP",
            state: state,
            reasons: attrs["printer-state-reasons"]?.map(\.text) ?? [],
            message: attrs["printer-state-message"]?.first?.text ?? ""
        )
    }

    func submit(job document: Data, name: String) async throws -> Int {
        var request = IPPRequest(operation: .printJob, printerURI: printerURI, user: user)
        request.add(0x42, "job-name", name)
        request.add(0x49, "document-format", "application/octet-stream")
        let response = try await send(request, document: document, timeout: 120)
        guard response.isSuccess else { throw IPPError.operation(response.statusText) }
        guard let id = response.groups.first(where: { $0["job-id"] != nil })?["job-id"]?.first?.int else {
            throw IPPError.malformed
        }
        return id
    }

    func jobs() async throws -> [PrintJobInfo] {
        var request = IPPRequest(operation: .getJobs, printerURI: printerURI, user: user)
        request.add(0x44, "which-jobs", "not-completed")
        request.add(keywords: "requested-attributes", [
            "job-id", "job-name", "job-state", "job-originating-user-name",
        ])
        let response = try await send(request, timeout: 6)
        guard response.isSuccess else { throw IPPError.operation(response.statusText) }
        return response.groups.compactMap { attrs in
            guard let id = attrs["job-id"]?.first?.int else { return nil }
            return PrintJobInfo(
                id: id,
                name: attrs["job-name"]?.first?.text ?? "Trabalho \(id)",
                state: attrs["job-state"]?.first?.text ?? "",
                user: attrs["job-originating-user-name"]?.first?.text ?? ""
            )
        }
    }

    func jobState(id: Int) async throws -> Int? {
        var request = IPPRequest(operation: .getJobAttributes, printerURI: printerURI, user: user)
        request.add(integer: "job-id", id)
        request.add(keywords: "requested-attributes", ["job-state"])
        let response = try await send(request, timeout: 6)
        guard response.isSuccess else { return nil }
        return response.groups.first(where: { $0["job-state"] != nil })?["job-state"]?.first?.int
    }

    func cancel(jobID: Int) async throws {
        var request = IPPRequest(operation: .cancelJob, printerURI: printerURI, user: user)
        request.add(integer: "job-id", jobID)
        let response = try await send(request, timeout: 10)
        guard response.isSuccess else { throw IPPError.operation(response.statusText) }
    }
}
