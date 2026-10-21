import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MLPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() { HeadlessCommand.runIfRequested() }

    var body: some Scene {
        Window("ML Print for Mac", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 680)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1040, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Imprimir") { model.printAll() }
                    .keyboardShortcut("p")
                    .disabled(model.files.isEmpty || model.isBusy || model.status == nil)
            }
            CommandMenu("Impressora") {
                Button("Atualizar estado") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Página de teste") { model.addTestPage() }
                Button("Rede sem fio…") { model.showWireless = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Cancelar todos os trabalhos") { Task { await model.cancelAllJobs() } }
                    .disabled(model.jobs.isEmpty)
                Divider()
                Button("Instalar no menu PDF do macOS") { model.installPDFService() }
            }
        }
    }
}
