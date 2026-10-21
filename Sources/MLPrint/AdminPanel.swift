import SwiftUI
import WebKit

/// The printer's own SyncThru web page (where the wireless network is changed), shown inside the app.
struct AdminPanelView: NSViewRepresentable {
    let url: URL
    @Binding var reloadToken: Int

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastToken = 0

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if ProcessInfo.processInfo.environment["MLPRINT_DEBUG"] != nil { print("[web]", message.body) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if ProcessInfo.processInfo.environment["MLPRINT_DEBUG"] != nil { print("[nav fail]", error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if ProcessInfo.processInfo.environment["MLPRINT_DEBUG"] != nil { print("[nav provisional fail]", error) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let script = WKUserScript(source: """
            window.addEventListener('error', function(e){ window.webkit.messageHandlers.log.postMessage('error: ' + e.message + ' @' + e.filename + ':' + e.lineno); });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(context.coordinator, name: "log")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }
}

struct AdminPanelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reload = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Painel da impressora", systemImage: "gearshape.2").font(.headline)
                Spacer()
                Text("O painel é lento: pode levar cerca de 1 minuto para carregar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Recarregar") { reload += 1 }
                Button("Fechar") {
                    dismiss()
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let url = URL(string: "http://\(model.client.host)/") {
                AdminPanelView(url: url, reloadToken: $reload)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}
