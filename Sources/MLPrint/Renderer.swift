import AppKit
import PDFKit

enum RenderError: LocalizedError {
    case cannotOpen(String)
    case cannotRender
    case filter(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "Não foi possível abrir “\(name)”."
        case .cannotRender: return "Falha ao renderizar a página."
        case .filter(let text): return "Falha no driver de impressão: \(text)"
        }
    }
}

/// A rendered sheet at printer resolution: 1 bit per pixel, 1 = black.
struct RasterPage {
    var width: Int
    var height: Int
    var bytesPerLine: Int
    var bits: [UInt8]
}

/// An 8-bit gray sheet, rows from top to bottom (0 = black).
struct GraySheet {
    var width: Int
    var height: Int
    var context: CGContext
}

enum Renderer {
    static let printDPI = 600

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "webp"]

    // MARK: Layout

    private static func grid(pagesPerSheet: Int, landscape: Bool) -> (columns: Int, rows: Int) {
        switch pagesPerSheet {
        case 2: return landscape ? (2, 1) : (1, 2)
        case 4: return (2, 2)
        case 6: return landscape ? (3, 2) : (2, 3)
        case 9: return (3, 3)
        default: return (1, 1)
        }
    }

    private static func isLandscape(_ page: PDFPage?) -> Bool {
        guard let page else { return false }
        let bounds = page.bounds(for: .cropBox)
        return bounds.width > bounds.height
    }

    /// Whether the sheet's content is laid out landscape (and then rotated onto the portrait-fed paper).
    static func usesLandscape(sheet: SheetSpec, document: PDFDocument, options: JobOptions) -> Bool {
        switch options.orientation {
        case .portrait: return false
        case .landscape: return true
        case .auto:
            let first = sheet.pages.compactMap { $0 }.first.flatMap { document.page(at: $0) }
            let multiColumn = options.pagesPerSheet == 2 || options.pagesPerSheet == 6
            return isLandscape(first) != multiColumn
        }
    }

    // MARK: Drawing

    /// Draws one sheet into an 8-bit gray context covering the printable area.
    static func renderGray(sheet: SheetSpec, document: PDFDocument, options: JobOptions, dpi: Int) throws -> GraySheet {
        let area = options.paper.imageable
        let scale = CGFloat(dpi) / 72
        let width = Int((area.width * scale).rounded())
        let height = Int((area.height * scale).rounded())

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw RenderError.cannotRender }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: scale, y: scale)

        let landscape = usesLandscape(sheet: sheet, document: document, options: options)
        let logicalW = landscape ? area.height : area.width
        let logicalH = landscape ? area.width : area.height

        if landscape {
            // Rotate the logical (landscape) sheet 90° counterclockwise onto the portrait paper.
            ctx.translateBy(x: area.width, y: 0)
            ctx.rotate(by: .pi / 2)
        }
        if sheet.rotate180 {
            ctx.translateBy(x: logicalW, y: logicalH)
            ctx.rotate(by: .pi)
        }

        let margin = CGFloat(options.marginMM) * 72 / 25.4
        let (columns, rows) = grid(pagesPerSheet: options.pagesPerSheet, landscape: landscape)
        let cellW = (logicalW - 2 * margin) / CGFloat(columns)
        let cellH = (logicalH - 2 * margin) / CGFloat(rows)
        let multi = options.pagesPerSheet > 1
        let gap: CGFloat = multi ? 8 : 0

        for (slot, pageIndex) in sheet.pages.enumerated() {
            let column = slot % columns
            let row = slot / columns
            let cell = CGRect(
                x: margin + CGFloat(column) * cellW,
                y: logicalH - margin - CGFloat(row + 1) * cellH,
                width: cellW, height: cellH
            ).insetBy(dx: gap / 2, dy: gap / 2)

            guard let pageIndex, let page = document.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }

            let factor = options.scale == .fit
                ? min(cell.width / bounds.width, cell.height / bounds.height)
                : 1
            let drawn = CGSize(width: bounds.width * factor, height: bounds.height * factor)
            let origin = options.scale == .fit
                ? CGPoint(x: cell.midX - drawn.width / 2, y: cell.midY - drawn.height / 2)
                : CGPoint(x: cell.minX, y: cell.maxY - drawn.height)

            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: factor, y: factor)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()

            if multi && options.showBorders {
                ctx.saveGState()
                ctx.setStrokeColor(gray: 0.55, alpha: 1)
                ctx.setLineWidth(0.5)
                ctx.stroke(CGRect(
                    x: origin.x, y: origin.y, width: drawn.width, height: drawn.height
                ).intersection(cell))
                ctx.restoreGState()
            }
        }
        return GraySheet(width: width, height: height, context: ctx)
    }

    static func preview(sheet: SheetSpec, document: PDFDocument, options: JobOptions) throws -> NSImage {
        let gray = try renderGray(sheet: sheet, document: document, options: options, dpi: 110)
        guard let image = gray.context.makeImage() else { throw RenderError.cannotRender }
        let area = options.paper.imageable
        return NSImage(cgImage: image, size: NSSize(width: area.width, height: area.height))
    }

    static func raster(sheet: SheetSpec, document: PDFDocument, options: JobOptions) throws -> RasterPage {
        let gray = try renderGray(sheet: sheet, document: document, options: options, dpi: printDPI)
        guard let data = gray.context.data else { throw RenderError.cannotRender }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return halftone(pixels, width: gray.width, height: gray.height, mode: options.imageMode)
    }

    // MARK: Halftone

    // 8x8 Bayer matrix scaled to 0...255 thresholds.
    private static let bayer: [UInt8] = {
        let base: [[Int]] = [
            [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
            [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
            [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
            [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
        ]
        return base.flatMap { $0.map { UInt8(($0 * 255 + 32) / 64) } }
    }()

    /// Converts 8-bit gray to 1-bit. `.document` snaps near-black/white and dithers mid-tones with an
    /// ordered matrix; `.text` is a hard threshold; `.photo` uses Floyd–Steinberg error diffusion.
    private static func halftone(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, mode: ImageMode) -> RasterPage {
        let bytesPerLine = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: bytesPerLine * height)

        switch mode {
        case .photo:
            var current = [Int16](repeating: 0, count: width + 2)
            var next = [Int16](repeating: 0, count: width + 2)
            bits.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = pixels + y * width
                    let outRow = y * bytesPerLine
                    for x in 0..<width {
                        let value = Int16(row[x]) + current[x + 1]
                        let black = value < 128
                        let error = value - (black ? 0 : 255)
                        current[x + 2] += error * 7 / 16
                        next[x] += error * 3 / 16
                        next[x + 1] += error * 5 / 16
                        next[x + 2] += error / 16
                        if black { out[outRow + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
                    }
                    swap(&current, &next)
                    for index in next.indices { next[index] = 0 }
                }
            }
        case .text, .document:
            let hard = mode == .text
            bayer.withUnsafeBufferPointer { matrix in
                bits.withUnsafeMutableBufferPointer { out in
                    for y in 0..<height {
                        let row = pixels + y * width
                        let matrixRow = (y & 7) * 8
                        let outRow = y * bytesPerLine
                        for x in 0..<width {
                            let value = row[x]
                            let black: Bool
                            if hard {
                                black = value < 150
                            } else if value < 24 {
                                black = true
                            } else if value > 232 {
                                black = false
                            } else {
                                black = value < matrix[matrixRow + (x & 7)]
                            }
                            if black { out[outRow + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
                        }
                    }
                }
            }
        }
        return RasterPage(width: width, height: height, bytesPerLine: bytesPerLine, bits: bits)
    }

    static func pngPreview(of raster: RasterPage) -> Data? {
        var gray = [UInt8](repeating: 255, count: raster.width * raster.height)
        for y in 0..<raster.height {
            for x in 0..<raster.width where raster.bits[y * raster.bytesPerLine + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0 {
                gray[y * raster.width + x] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(
                width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: raster.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
