import AppKit
import PDFKit

enum TestPage {
    /// A one-page A4 PDF with alignment marks, gray steps, line weights and text samples.
    static func make(host: String) -> PDFDocument? {
        let size = CGSize(width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: string, attributes: attributes).draw(at: point)
        }

        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48))
        for corner in [CGPoint(x: 24, y: 24), CGPoint(x: size.width - 24, y: 24),
                       CGPoint(x: 24, y: size.height - 24), CGPoint(x: size.width - 24, y: size.height - 24)] {
            ctx.move(to: CGPoint(x: corner.x - 14, y: corner.y)); ctx.addLine(to: CGPoint(x: corner.x + 14, y: corner.y))
            ctx.move(to: CGPoint(x: corner.x, y: corner.y - 14)); ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + 14))
        }
        ctx.strokePath()

        text("ML Print for Mac — Página de teste", at: CGPoint(x: 48, y: size.height - 80), size: 24, weight: .bold)
        let date = Date().formatted(date: .long, time: .shortened)
        text("Impressora: \(host)   ·   \(date)", at: CGPoint(x: 48, y: size.height - 102), size: 11)

        text("Degraus de cinza", at: CGPoint(x: 48, y: size.height - 150), size: 11, weight: .semibold)
        for step in 0..<11 {
            ctx.setFillColor(gray: 1 - CGFloat(step) / 10, alpha: 1)
            let rect = CGRect(x: 48 + CGFloat(step) * 44, y: size.height - 205, width: 44, height: 40)
            ctx.fill(rect)
            ctx.setStrokeColor(gray: 0.6, alpha: 1)
            ctx.stroke(rect)
        }

        text("Espessuras de linha", at: CGPoint(x: 48, y: size.height - 250), size: 11, weight: .semibold)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        for (index, width) in [0.25, 0.5, 1, 2, 4].enumerated() {
            ctx.setLineWidth(CGFloat(width))
            let y = size.height - 272 - CGFloat(index) * 12
            ctx.move(to: CGPoint(x: 48, y: y)); ctx.addLine(to: CGPoint(x: 300, y: y))
            ctx.strokePath()
        }

        text("Tamanhos de texto", at: CGPoint(x: 48, y: size.height - 350), size: 11, weight: .semibold)
        var y = size.height - 372
        for fontSize in [6, 8, 10, 12, 16, 24] as [CGFloat] {
            text("\(Int(fontSize)) pt — A rápida raposa marrom pulou sobre o cão 0123456789".prefix(fontSize > 14 ? 34 : 200).description, at: CGPoint(x: 48, y: y), size: fontSize)
            y -= fontSize + 8
        }

        text("Quadriculado (alinhamento)", at: CGPoint(x: 48, y: 330), size: 11, weight: .semibold)
        ctx.setStrokeColor(gray: 0.3, alpha: 1)
        ctx.setLineWidth(0.4)
        let grid = CGRect(x: 48, y: 90, width: size.width - 96, height: 225)
        var gx = grid.minX
        while gx <= grid.maxX { ctx.move(to: CGPoint(x: gx, y: grid.minY)); ctx.addLine(to: CGPoint(x: gx, y: grid.maxY)); gx += 20 }
        var gy = grid.minY
        while gy <= grid.maxY { ctx.move(to: CGPoint(x: grid.minX, y: gy)); ctx.addLine(to: CGPoint(x: grid.maxX, y: gy)); gy += 20 }
        ctx.strokePath()

        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }
}
