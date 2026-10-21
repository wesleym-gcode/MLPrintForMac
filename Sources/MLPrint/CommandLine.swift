import AppKit
import Foundation

/// Headless rendering for verification:
/// `MLPrint --render input out.png [landscape|portrait] [n=4] [actual] [photo] [margin=10] [range=1-2] [sheet=0] [back]`
/// rasterizes a sheet exactly as it would be printed (600 dpi, 1 bit) and writes a PNG.
enum HeadlessCommand {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "--selftest" { selfTest(); exit(0) }
        if args.count >= 3, args[1] == "--wifi" {
            if let info = WirelessInfo.read(host: args[2]) { print(info) } else { print("sem resposta SNMP") }
            exit(0)
        }
        guard args.count >= 4, args[1] == "--render" else { return }
        do {
            let file = try DocumentLoader.load(URL(fileURLWithPath: args[2]))
            var options = JobOptions()
            var sheetIndex = 0
            var back = false
            for flag in args.dropFirst(4) {
                switch flag {
                case "landscape": options.orientation = .landscape
                case "portrait": options.orientation = .portrait
                case "actual": options.scale = .actual
                case "photo": options.imageMode = .photo
                case "text": options.imageMode = .text
                case "back": back = true
                default:
                    let parts = flag.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "n": options.pagesPerSheet = Int(parts[1]) ?? 1
                    case "margin": options.marginMM = Int(parts[1]) ?? 0
                    case "range": options.range = parts[1]
                    case "sheet": sheetIndex = Int(parts[1]) ?? 0
                    case "paper": options.paper = PaperSize(rawValue: parts[1]) ?? .a4
                    default: break
                    }
                }
            }
            guard let doc = file.document(for: options.paper) else { throw RenderError.cannotRender }
            let indices = try PrintPlan.pageIndices(count: doc.pageCount, range: options.range, reverse: false)
            var sheets = PrintPlan.sheets(for: indices, pagesPerSheet: options.pagesPerSheet)
            if back { sheets = sheets.map { SheetSpec(pages: $0.pages, rotate180: true) } }
            let raster = try Renderer.raster(sheet: sheets[min(sheetIndex, sheets.count - 1)], document: doc, options: options)
            try Renderer.pngPreview(of: raster)?.write(to: URL(fileURLWithPath: args[3]))
            print("ok \(doc.pageCount) páginas, \(sheets.count) folhas, \(raster.width)x\(raster.height)")
        } catch {
            print("erro: \(error.localizedDescription)")
        }
        exit(0)
    }

    private static func describe(_ passes: [[SheetSpec]]) -> String {
        var parts: [String] = []
        for pass in passes {
            var sheets: [String] = []
            for sheet in pass {
                var cells: [String] = []
                for page in sheet.pages {
                    if let page { cells.append(String(page + 1)) } else { cells.append("-") }
                }
                var text = "(" + cells.joined(separator: ",")
                if sheet.rotate180 { text += "r" }
                sheets.append(text + ")")
            }
            parts.append("[" + sheets.joined(separator: " ") + "]")
        }
        return parts.joined(separator: " ")
    }

    private static func selfTest() {
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok    " + name)
            } else {
                print("FAIL  " + name)
                print("  got:  " + got)
                print("  want: " + want)
            }
        }
        func r(_ text: String, _ count: Int) -> String {
            guard let indices = try? PrintPlan.pageIndices(count: count, range: text, reverse: false) else { return "erro" }
            return indices.map { String($0 + 1) }.joined(separator: ",")
        }
        check("range vazio", r("", 3), "1,2,3")
        check("range misto", r("1-2, 5, 7-", 8), "1,2,5,7,8")
        check("range -3", r("-3", 5), "1,2,3")
        check("range inválido", r("9", 5), "erro")
        check("range invertido", r("3-1", 5), "erro")

        var o = JobOptions()
        let six = PrintPlan.sheets(for: Array(0..<6), pagesPerSheet: 1)
        o.duplex = .longEdge
        check("duplex 6 págs", describe(PrintPlan.passes(for: six, options: o)), "[(1) (3) (5)] [(6) (4) (2)]")
        let five = PrintPlan.sheets(for: Array(0..<5), pagesPerSheet: 1)
        check("duplex 5 págs", describe(PrintPlan.passes(for: five, options: o)), "[(1) (3) (5)] [(-) (4) (2)]")
        o.duplex = .shortEdge; o.reverseBackSide = false
        check("borda curta", describe(PrintPlan.passes(for: PrintPlan.sheets(for: Array(0..<4), pagesPerSheet: 1), options: o)), "[(1) (3)] [(2r) (4r)]")
        o = JobOptions(); o.copies = 2
        check("cópias agrupadas", describe(PrintPlan.passes(for: PrintPlan.sheets(for: Array(0..<2), pagesPerSheet: 1), options: o)), "[(1) (2) (1) (2)]")
        o.collate = false
        check("cópias não agrupadas", describe(PrintPlan.passes(for: PrintPlan.sheets(for: Array(0..<2), pagesPerSheet: 1), options: o)), "[(1) (1) (2) (2)]")
        check("n-up 2 de 3", describe([PrintPlan.sheets(for: [0, 1, 2], pagesPerSheet: 2)]), "[(1,2) (3,-)]")
    }
}
