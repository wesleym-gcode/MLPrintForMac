import Foundation

enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case a4 = "A4"
    case letter = "Letter"
    case legal = "Legal"
    case executive = "Executive"
    case a5 = "A5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Carta (Letter)"
        case .legal: return "Ofício (Legal)"
        case .executive: return "Executive"
        case .a5: return "A5"
        }
    }

    /// Paper size in points.
    var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        case .executive: return CGSize(width: 522, height: 756)
        case .a5: return CGSize(width: 420, height: 595)
        }
    }

    /// Printable area from the printer's PPD, in points, relative to the paper's bottom-left corner.
    var imageable: CGRect {
        switch self {
        case .a4: return CGRect(x: 10.75, y: 15, width: 573.5, height: 812)
        case .letter: return CGRect(x: 10.75, y: 15, width: 590.5, height: 762)
        case .legal: return CGRect(x: 10.75, y: 15, width: 590.5, height: 978)
        case .executive: return CGRect(x: 10.75, y: 15, width: 500.5, height: 726)
        case .a5: return CGRect(x: 10.75, y: 15, width: 398.5, height: 565)
        }
    }
}

enum Orientation: String, CaseIterable, Identifiable, Codable {
    case auto, portrait, landscape
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automática"
        case .portrait: return "Retrato"
        case .landscape: return "Paisagem"
        }
    }
}

enum ScaleMode: String, CaseIterable, Identifiable, Codable {
    case fit, actual
    var id: String { rawValue }
    var title: String { self == .fit ? "Ajustar à página" : "Tamanho real" }
}

enum ImageMode: String, CaseIterable, Identifiable, Codable {
    case document, photo, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .document: return "Documento"
        case .photo: return "Foto (meio-tom)"
        case .text: return "Texto nítido"
        }
    }
}

enum DuplexMode: String, CaseIterable, Identifiable, Codable {
    case off, longEdge, shortEdge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Desligado"
        case .longEdge: return "Manual, borda longa"
        case .shortEdge: return "Manual, borda curta"
        }
    }
}

struct JobOptions: Codable, Equatable {
    var paper: PaperSize = .a4
    var orientation: Orientation = .auto
    var scale: ScaleMode = .fit
    var pagesPerSheet = 1
    var marginMM = 0
    var showBorders = true
    var copies = 1
    var collate = true
    var range = ""
    var reverse = false
    var duplex: DuplexMode = .off
    var reverseBackSide = true
    var imageMode: ImageMode = .document
    var tonerSave = false
    var density = 3
    var mediaType = "OFF"
    var manualFeed = false

    static let mediaTypes: [(id: String, title: String)] = [
        ("OFF", "Padrão da impressora"), ("NORMAL", "Comum"), ("THICK", "Grosso"),
        ("THIN", "Fino"), ("BOND", "Bond"), ("OHP", "Transparência"), ("CARD", "Cartão"),
        ("LABEL", "Etiqueta"), ("USED", "Pré-impresso"), ("COLOR", "Colorido"),
        ("ENV", "Envelope"), ("COTTON", "Algodão"), ("RECYCLED", "Reciclado"), ("ARCHIVE", "Arquivo"),
    ]

    /// Options handed to the splix filter (names come from its PPD).
    var filterOptions: String {
        [
            "PageSize=\(paper.rawValue)",
            "Resolution=600dpi",
            "EconoMode=\(tonerSave ? "ON" : "OFF")",
            "TonerDensity=\(density)",
            "MediaType=\(mediaType)",
            "InputSlot=\(manualFeed ? "Manual" : "Auto")",
        ].joined(separator: " ")
    }

    private static let storageKey = "jobOptions.v2"

    static func load() -> JobOptions {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var options = try? JSONDecoder().decode(JobOptions.self, from: data) else { return JobOptions() }
        options.range = ""
        options.copies = 1
        return options
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Planning

/// One physical side of a sheet: up to `pagesPerSheet` document pages (nil = blank cell).
struct SheetSpec: Equatable {
    var pages: [Int?]
    var rotate180 = false
}

enum PlanError: LocalizedError {
    case badRange(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badRange(let text): return "Intervalo de páginas inválido: “\(text)”. Use algo como 1-3, 5, 8-."
        case .empty: return "Nenhuma página selecionada."
        }
    }
}

enum PrintPlan {
    /// Parses "1-3, 5, 8-" against `count` pages. Empty text means all pages.
    static func pageIndices(count: Int, range: String, reverse: Bool) throws -> [Int] {
        let text = range.trimmingCharacters(in: .whitespaces)
        var indices: [Int] = []
        if text.isEmpty {
            indices = Array(0..<count)
        } else {
            for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let piece = part.trimmingCharacters(in: .whitespaces)
                let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                switch bounds.count {
                case 1:
                    guard let page = Int(bounds[0]), (1...count).contains(page) else { throw PlanError.badRange(piece) }
                    indices.append(page - 1)
                case 2:
                    let start = bounds[0].isEmpty ? 1 : Int(bounds[0])
                    let end = bounds[1].isEmpty ? count : Int(bounds[1])
                    guard let start, let end, start >= 1, end <= count, start <= end else { throw PlanError.badRange(piece) }
                    indices.append(contentsOf: (start - 1)..<end)
                default:
                    throw PlanError.badRange(piece)
                }
            }
        }
        guard !indices.isEmpty else { throw PlanError.empty }
        return reverse ? indices.reversed() : indices
    }

    static func sheets(for indices: [Int], pagesPerSheet: Int) -> [SheetSpec] {
        stride(from: 0, to: indices.count, by: pagesPerSheet).map { start in
            var pages: [Int?] = indices[start..<min(start + pagesPerSheet, indices.count)].map { $0 }
            while pages.count < pagesPerSheet { pages.append(nil) }
            return SheetSpec(pages: pages)
        }
    }

    /// The ordered list of physical sides to send, grouped into passes. A pass is one job;
    /// manual duplex needs a pause (flip the paper) between passes.
    static func passes(for sheets: [SheetSpec], options: JobOptions) -> [[SheetSpec]] {
        let copies = max(1, options.copies)

        if options.duplex == .off {
            if options.collate {
                return [Array((0..<copies).flatMap { _ in sheets })]
            }
            return [sheets.flatMap { Array(repeating: $0, count: copies) }]
        }

        let fronts = stride(from: 0, to: sheets.count, by: 2).map { sheets[$0] }
        var backs = stride(from: 1, to: sheets.count, by: 2).map { sheets[$0] }
        if sheets.count % 2 == 1 {
            backs.append(SheetSpec(pages: Array(repeating: nil, count: sheets[0].pages.count)))
        }
        if options.reverseBackSide { backs.reverse() }
        if options.duplex == .shortEdge {
            backs = backs.map { SheetSpec(pages: $0.pages, rotate180: true) }
        }
        return (0..<copies).flatMap { _ in [fronts, backs] }
    }

    static func physicalSheetCount(sheets: Int, duplex: DuplexMode) -> Int {
        duplex == .off ? sheets : (sheets + 1) / 2
    }
}
