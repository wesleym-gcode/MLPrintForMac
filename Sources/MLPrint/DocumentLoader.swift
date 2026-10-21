import AppKit
import PDFKit

/// A file the user added. Word/text-like files are re-paginated when the paper size changes.
final class QueuedFile: Identifiable {
    enum Source {
        case pdf(PDFDocument)
        case rich(NSAttributedString)
    }

    let id = UUID()
    let url: URL
    let source: Source
    private var cache: [PaperSize: PDFDocument] = [:]

    init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }

    func document(for paper: PaperSize) -> PDFDocument? {
        switch source {
        case .pdf(let doc): return doc
        case .rich(let text):
            if let cached = cache[paper] { return cached }
            let doc = DocumentLoader.paginate(text, paper: paper)
            cache[paper] = doc
            return doc
        }
    }
}

enum DocumentLoader {
    static let richExtensions: Set<String> = [
        "txt", "text", "md", "log", "csv", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "xml", "json",
    ]
    static let plainExtensions: Set<String> = ["txt", "text", "md", "log", "csv", "xml", "json"]

    static var supportedExtensions: Set<String> {
        Renderer.imageExtensions.union(richExtensions).union(["pdf"])
    }

    static func load(_ url: URL) throws -> QueuedFile {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw RenderError.cannotOpen(url.lastPathComponent) }
            return QueuedFile(url: url, source: .pdf(doc))
        }
        if Renderer.imageExtensions.contains(ext) {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw RenderError.cannotOpen(url.lastPathComponent)
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            return QueuedFile(url: url, source: .pdf(doc))
        }
        if richExtensions.contains(ext) {
            return QueuedFile(url: url, source: .rich(try attributedText(from: url, plain: plainExtensions.contains(ext))))
        }
        throw RenderError.cannotOpen(url.lastPathComponent)
    }

    private static func attributedText(from url: URL, plain: Bool) throws -> NSAttributedString {
        if plain {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw RenderError.cannotOpen(url.lastPathComponent)
        }
    }

    /// Lays out rich text onto pages of the given paper (20 mm margins) and returns a PDF.
    static func paginate(_ source: NSAttributedString, paper: PaperSize) -> PDFDocument? {
        let page = paper.size
        let margin: CGFloat = 20 * 72 / 25.4
        let content = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)

        // Text on a white page: force dark text so dark-mode colors don't wash out.
        let text = NSMutableAttributedString(attributedString: source)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let color = value as? NSColor,
               let rgb = color.usingColorSpace(.deviceGray), rgb.whiteComponent > 0.9 {
                text.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(for: container)
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs || glyphs.length == 0 || containers.count > 2000 { break }
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: page)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        for container in containers {
            pdf.beginPDFPage(nil)
            let glyphs = layout.glyphRange(for: container)
            let graphics = NSGraphicsContext(cgContext: pdf, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            pdf.translateBy(x: margin, y: page.height - margin)
            pdf.scaleBy(x: 1, y: -1)
            layout.drawBackground(forGlyphRange: glyphs, at: .zero)
            layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return PDFDocument(data: data as Data)
    }
}
