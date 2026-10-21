import Foundation
import CSpl

/// Converts rasterized pages into the printer's native QPDL stream using the bundled splix filter.
enum SplPipeline {
    static var resourceDirectory: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Runs the filter. `pages` produces rasters lazily so that only one 600 dpi page is held in memory.
    static func makeJob(
        title: String,
        options: JobOptions,
        pageCount: Int,
        page: @escaping (Int) throws -> RasterPage
    ) async throws -> Data {
        let filter = resourceDirectory.appendingPathComponent("rastertoqpdl")
        let ppd = resourceDirectory.appendingPathComponent("ml2160.ppd")
        guard FileManager.default.isExecutableFile(atPath: filter.path) else {
            throw RenderError.filter("filtro rastertoqpdl não encontrado no aplicativo.")
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = filter
            process.arguments = ["1", NSUserName(), title, "1", options.filterOptions]
            process.environment = ["PPD": ppd.path, "PATH": "/usr/bin:/bin"]

            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            var collected = Data()
            var errorText = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                collected = output.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errorText = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            var failure: Error?
            if let raster = spl_raster_open(input.fileHandleForWriting.fileDescriptor) {
                do {
                    for index in 0..<pageCount {
                        try Task.checkCancellation()
                        let rendered = try page(index)
                        let size = options.paper.size
                        let ok = rendered.bits.withUnsafeBufferPointer { bits in
                            spl_raster_write_page(
                                raster, UInt32(rendered.width), UInt32(rendered.height),
                                UInt32(rendered.bytesPerLine), UInt32(Renderer.printDPI),
                                UInt32(size.width), UInt32(size.height),
                                1, bits.baseAddress)
                        }
                        if ok == 0 { throw RenderError.filter("o driver encerrou antes do fim.") }
                    }
                } catch {
                    failure = error
                }
                spl_raster_close(raster)
            } else {
                failure = RenderError.filter("não foi possível abrir o fluxo raster.")
            }
            try? input.fileHandleForWriting.close()

            group.wait()
            process.waitUntilExit()

            if let failure { throw failure }
            guard process.terminationStatus == 0, !collected.isEmpty else {
                let tail = String(decoding: errorText.suffix(300), as: UTF8.self)
                throw RenderError.filter("código \(process.terminationStatus). \(tail)")
            }
            return collected
        }.value
    }
}
