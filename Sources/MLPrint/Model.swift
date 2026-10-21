import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI

enum Activity: Equatable {
    case idle
    case preparing(name: String, done: Int, total: Int)
    case sending(String)
    case waiting(String)
    case finished(String)
    case failed(String)
}

/// Remembers the last rendered sheet so repeated sheets (copies) are not rasterized twice.
private final class RasterCache: @unchecked Sendable {
    var sheet: SheetSpec?
    var raster: RasterPage?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: "printerHost")
            Task { await refresh() }
        }
    }
    @Published var status: PrinterStatus?
    @Published var statusError: String?
    @Published var jobs: [PrintJobInfo] = []
    @Published var files: [QueuedFile] = []
    @Published var selectedID: UUID?
    @Published var options = JobOptions.load() {
        didSet {
            options.save()
            if options.paper != oldValue.paper || options.pagesPerSheet != oldValue.pagesPerSheet {
                previewSheet = 0
            }
        }
    }
    @Published var activity = Activity.idle
    @Published var loadError: String?
    @Published var notice: String?
    @Published var showImporter = false
    @Published var previewImage: NSImage?
    @Published var previewMessage: String?
    @Published var previewSheet = 0
    @Published var duplexPrompt: String?
    @Published var showWireless = false
    @Published var showAdminPanel = false
    @Published var wireless: WirelessInfo?
    @Published var wirelessLoading = false
    @Published var wirelessFailed = false

    let discovery = PrinterDiscovery()
    private var pollTask: Task<Void, Never>?
    private var printTask: Task<Void, Never>?
    private var discoveryObserver: AnyCancellable?
    private var autoSelectObserver: AnyCancellable?
    private var duplexContinuation: CheckedContinuation<Bool, Never>?

    init() {
        host = UserDefaults.standard.string(forKey: "printerHost") ?? ""
        discoveryObserver = discovery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        autoSelectObserver = discovery.$printers.sink { [weak self] printers in
            Task { @MainActor in await self?.autoSelect(from: printers) }
        }
    }

    var client: PrinterClient { PrinterClient(host: host.trimmingCharacters(in: .whitespaces)) }

    var isBusy: Bool {
        switch activity {
        case .preparing, .sending, .waiting: return true
        default: return false
        }
    }

    var selectedFile: QueuedFile? {
        files.first { $0.id == selectedID } ?? files.first
    }

    // MARK: Printer

    func start() {
        discovery.start()
        if host.isEmpty {
            // Bonjour first; if no printer is chosen shortly after, scan the local network.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.host.isEmpty else { return }
                await self.discovery.scan()
                await self.autoSelect(from: self.discovery.printers)
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// With no printer chosen yet, picks a discovered Samsung ML printer. Queues that macOS itself
    /// shares ("name @ computer") are ignored so the app never selects this Mac as the printer.
    private func autoSelect(from printers: [DiscoveredPrinter]) async {
        guard host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let direct = printers.filter { !$0.name.contains(" @ ") }
        let choice = direct.first {
            $0.name.localizedCaseInsensitiveContains("samsung") || $0.name.contains("ML-")
        }
        if let choice { await use(choice) }
    }

    func refresh() async {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = nil
            jobs = []
            statusError = "Nenhuma impressora escolhida. Procurando na rede… (ou use o menu do IP ▸ Digitar endereço)"
            return
        }
        let client = self.client
        do {
            let status = try await client.status()
            self.status = status
            self.statusError = nil
            self.jobs = (try? await client.jobs()) ?? []
        } catch {
            self.status = nil
            self.jobs = []
            self.statusError = "Sem resposta de \(client.host): \(error.localizedDescription)"
        }
    }

    func use(_ printer: DiscoveredPrinter) async {
        if let address = await discovery.resolveAddress(of: printer) { host = address }
    }

    func cancel(_ job: PrintJobInfo) async {
        try? await client.cancel(jobID: job.id)
        await refresh()
    }

    func cancelAllJobs() async {
        for job in jobs { try? await client.cancel(jobID: job.id) }
        await refresh()
    }

    func loadWireless() async {
        let host = client.host
        wirelessLoading = true
        let info = await Task.detached { WirelessInfo.read(host: host) }.value
        wireless = info
        wirelessFailed = info == nil
        wirelessLoading = false
    }

    func openAdminPage() {
        if let url = URL(string: "http://\(client.host)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Files

    func add(urls: [URL]) {
        loadError = nil
        var problems: [String] = []
        for url in urls {
            guard DocumentLoader.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                problems.append("“\(url.lastPathComponent)”: formato não suportado.")
                continue
            }
            do {
                let file = try DocumentLoader.load(url)
                files.append(file)
                if selectedID == nil { selectedID = file.id }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { loadError = problems.joined(separator: "\n") }
        previewSheet = 0
    }

    func remove(_ file: QueuedFile) {
        files.removeAll { $0.id == file.id }
        if selectedID == file.id { selectedID = files.first?.id }
        previewSheet = 0
    }

    func select(_ file: QueuedFile) {
        selectedID = file.id
        previewSheet = 0
    }

    func addTestPage() {
        guard let doc = TestPage.make(host: host) else { return }
        let file = QueuedFile(url: URL(fileURLWithPath: "Página de teste.pdf"), source: .pdf(doc))
        files.append(file)
        selectedID = file.id
        previewSheet = 0
    }

    // MARK: Plan and preview

    struct Summary {
        var pages: Int
        var sheets: Int
        var paper: Int
    }

    func plan(for file: QueuedFile) throws -> (document: PDFDocument, sheets: [SheetSpec]) {
        guard let doc = file.document(for: options.paper) else { throw RenderError.cannotOpen(file.url.lastPathComponent) }
        let indices = try PrintPlan.pageIndices(count: doc.pageCount, range: options.range, reverse: options.reverse)
        return (doc, PrintPlan.sheets(for: indices, pagesPerSheet: options.pagesPerSheet))
    }

    var summary: Summary? {
        guard let file = selectedFile, let (doc, sheets) = try? plan(for: file) else { return nil }
        let pages = sheets.reduce(0) { $0 + $1.pages.compactMap { $0 }.count }
        _ = doc
        return Summary(
            pages: pages, sheets: sheets.count,
            paper: PrintPlan.physicalSheetCount(sheets: sheets.count, duplex: options.duplex) * max(1, options.copies))
    }

    var sheetCount: Int {
        guard let file = selectedFile, let plan = try? plan(for: file) else { return 0 }
        return plan.sheets.count
    }

    /// Identity of everything the preview depends on; the view re-renders when it changes.
    var previewKey: String {
        let data = (try? JSONEncoder().encode(options)) ?? Data()
        return "\(selectedFile?.id.uuidString ?? "-")|\(files.count)|\(previewSheet)|\(data.base64EncodedString())"
    }

    func refreshPreview() {
        guard let file = selectedFile else {
            previewImage = nil
            previewMessage = nil
            return
        }
        do {
            let (doc, sheets) = try plan(for: file)
            let index = min(max(previewSheet, 0), sheets.count - 1)
            if index != previewSheet { previewSheet = index }
            previewImage = try Renderer.preview(sheet: sheets[index], document: doc, options: options)
            previewMessage = nil
        } catch {
            previewImage = nil
            previewMessage = error.localizedDescription
        }
    }

    // MARK: Printing

    func printAll() {
        guard !files.isEmpty, !isBusy else { return }
        printTask = Task { await run() }
    }

    func cancelPrinting() {
        printTask?.cancel()
        resolveDuplex(continue: false)
    }

    func resolveDuplex(continue proceed: Bool) {
        duplexPrompt = nil
        duplexContinuation?.resume(returning: proceed)
        duplexContinuation = nil
    }

    private func askDuplex(_ text: String) async -> Bool {
        await withCheckedContinuation { continuation in
            duplexContinuation = continuation
            duplexPrompt = text
        }
    }

    private func run() async {
        let client = self.client
        let options = self.options
        let queue = files
        var sent = 0
        do {
            for file in queue {
                let name = file.url.lastPathComponent
                let (document, sheets) = try plan(for: file)
                let passes = PrintPlan.passes(for: sheets, options: options)

                for (passIndex, pass) in passes.enumerated() {
                    try Task.checkCancellation()
                    if options.duplex != .off && passIndex % 2 == 1 {
                        activity = .waiting(name)
                        let edge = options.duplex == .longEdge ? "pela borda longa" : "pela borda curta"
                        let order = options.reverseBackSide ? "As páginas do verso serão impressas em ordem inversa." : ""
                        let text = "O lado da frente de “\(name)” foi enviado. Espere a impressora terminar, "
                            + "vire a pilha \(edge) e recoloque as folhas na bandeja. \(order)"
                        guard await askDuplex(text) else { throw CancellationError() }
                    }

                    activity = .preparing(name: name, done: 0, total: pass.count)
                    let cache = RasterCache()
                    let data = try await SplPipeline.makeJob(
                        title: name, options: options, pageCount: pass.count
                    ) { [weak self] index in
                        let sheet = pass[index]
                        Task { @MainActor in
                            self?.activity = .preparing(name: name, done: index + 1, total: pass.count)
                        }
                        if cache.sheet == sheet, let raster = cache.raster { return raster }
                        let raster = try Renderer.raster(sheet: sheet, document: document, options: options)
                        cache.sheet = sheet
                        cache.raster = raster
                        return raster
                    }
                    activity = .sending(name)
                    _ = try await client.submit(job: data, name: name)
                }
                sent += 1
            }
            activity = .finished(sent == 1 ? "Enviado: \(queue[0].url.lastPathComponent)" : "\(sent) documentos enviados")
            files.removeAll()
            selectedID = nil
            previewSheet = 0
            await refresh()
        } catch is CancellationError {
            activity = .failed("Impressão cancelada.")
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    // MARK: System integration

    /// Adds "ML Print for Mac" to the PDF menu of macOS print dialogs.
    func installPDFService() {
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/PDF Services")
        let link = folder.appendingPathComponent("Imprimir com ML Print for Mac")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: Bundle.main.bundleURL)
            notice = "Pronto. Em qualquer app, use Arquivo ▸ Imprimir ▸ menu PDF ▸ “Imprimir com ML Print for Mac”."
        } catch {
            notice = "Não foi possível instalar: \(error.localizedDescription)"
        }
    }
}
