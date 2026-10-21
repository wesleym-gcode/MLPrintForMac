import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        HSplitView {
            PreviewPane()
                .frame(minWidth: 380)
            ControlsPane(dropTargeted: $dropTargeted)
                .frame(minWidth: 400, idealWidth: 420, maxWidth: 520)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add(urls: [url]) }
                }
            }
            return true
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls: urls) }
        }
        .sheet(isPresented: $model.showWireless) { WirelessView().environmentObject(model) }
        .sheet(isPresented: $model.showAdminPanel) { AdminPanelSheet().environmentObject(model) }
        .alert("Frente e verso manual", isPresented: Binding(
            get: { model.duplexPrompt != nil }, set: { _ in }
        )) {
            Button("Continuar") { model.resolveDuplex(continue: true) }
            Button("Cancelar", role: .cancel) { model.resolveDuplex(continue: false) }
        } message: {
            Text(model.duplexPrompt ?? "")
        }
        .alert("ML Print for Mac", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .padding(28)
                } else if let message = model.previewMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("A pré-visualização aparece aqui")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button { model.previewSheet -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(model.previewSheet <= 0)
                Text(model.sheetCount == 0 ? "—" : "Folha \(model.previewSheet + 1) de \(model.sheetCount)")
                    .monospacedDigit()
                    .frame(minWidth: 110)
                Button { model.previewSheet += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(model.previewSheet >= model.sheetCount - 1)
                Spacer()
                if let summary = model.summary {
                    Text("\(summary.pages) \(summary.pages == 1 ? "página" : "páginas") · \(summary.paper) \(summary.paper == 1 ? "folha" : "folhas") de papel")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .task(id: model.previewKey) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            model.refreshPreview()
        }
    }
}

// MARK: - Controls

private struct ControlsPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PrinterCard()
                    FilesSection(dropTargeted: dropTargeted)
                    OptionsSection()
                    JobsSection()
                }
                .padding(18)
            }
            Divider()
            PrintBar().padding(14)
            Divider()
            Footer()
        }
    }
}

private struct PrinterCard: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "printer.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.status?.model ?? "Impressora").font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 9, height: 9)
                            Text(stateText).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        ForEach(model.discovery.printers) { printer in
                            Button(printer.name) { Task { await model.use(printer) } }
                        }
                        if model.discovery.printers.isEmpty { Text("Nenhuma impressora encontrada") }
                        Divider()
                        Button(model.discovery.scanning ? "Procurando…" : "Procurar na rede") {
                            Task { await model.discovery.scan() }
                        }
                        .disabled(model.discovery.scanning)
                        Button("Digitar endereço…") {
                            draft = model.host
                            editing = true
                        }
                    } label: {
                        Label(model.host.isEmpty ? "Escolher impressora" : model.host, systemImage: "wifi")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button { model.showWireless = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Rede sem fio da impressora")
                }
                if let message = warningText {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let error = model.statusError {
                    Label(error, systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(.red)
                }
            }
            .padding(4)
        }
        .alert("Endereço da impressora", isPresented: $editing) {
            TextField("IP ou nome (ex.: 192.168.0.10)", text: $draft)
            Button("Conectar") { model.host = draft.trimmingCharacters(in: .whitespaces) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Use o endereço mostrado na página de configuração da impressora.")
        }
    }

    private var color: Color {
        guard let status = model.status else { return .red }
        switch status.state {
        case .idle: return .green
        case .processing: return .blue
        case .stopped: return .orange
        case .unknown: return .gray
        }
    }

    private var stateText: String {
        guard let status = model.status else { return "Desconectada" }
        switch status.state {
        case .idle: return "Pronta"
        case .processing: return "Imprimindo"
        case .stopped: return "Parada"
        case .unknown: return "Estado desconhecido"
        }
    }

    private var warningText: String? {
        guard let reasons = model.status?.activeReasons, !reasons.isEmpty else { return nil }
        return "Aviso da impressora: " + reasons.map(Self.translate).joined(separator: ", ")
    }

    private static func translate(_ reason: String) -> String {
        let table: [String: String] = [
            "toner-empty": "toner vazio", "toner-low": "toner baixo",
            "media-empty": "sem papel", "media-jam": "papel atolado",
            "media-needed": "coloque papel", "cover-open": "tampa aberta",
            "marker-supply-empty": "suprimento vazio", "offline": "offline",
            "door-open": "tampa aberta", "input-tray-missing": "bandeja ausente",
        ]
        for (key, text) in table where reason.hasPrefix(key) {
            return text + (reason.hasSuffix("-error") ? "" : " (aviso)")
        }
        return reason
    }
}

private struct FilesSection: View {
    @EnvironmentObject var model: AppModel
    let dropTargeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Documentos").font(.headline)
                Spacer()
                Button("Adicionar…") { model.showImporter = true }.buttonStyle(.link)
            }
            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Arraste PDF, Word, texto ou imagens").font(.callout)
                    Text("PDF · DOCX/DOC · RTF · TXT · HTML · PNG/JPG/HEIC")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                )
            } else {
                ForEach(model.files) { file in
                    let active = file.id == model.selectedFile?.id
                    HStack {
                        Image(systemName: "doc.fill").foregroundStyle(active ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.url.lastPathComponent).lineLimit(1)
                            if let count = file.document(for: model.options.paper)?.pageCount {
                                Text("\(count) \(count == 1 ? "página" : "páginas")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { model.remove(file) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .disabled(model.isBusy)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.accentColor.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(file) }
                }
            }
            if let error = model.loadError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

private struct OptionsSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("optionsMode") private var advanced = false

    /// Settings only reachable in advanced mode that differ from the defaults (they still apply).
    private var hiddenChanges: Bool {
        let o = model.options, d = JobOptions()
        return o.scale != d.scale || o.pagesPerSheet != d.pagesPerSheet || o.marginMM != d.marginMM
            || o.reverse != d.reverse || o.collate != d.collate || o.duplex == .shortEdge
            || o.imageMode != d.imageMode || o.density != d.density || o.mediaType != d.mediaType
            || o.manualFeed != d.manualFeed || !o.reverseBackSide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Opções").font(.headline)
                Spacer()
                Picker("", selection: $advanced) {
                    Text("Fácil").tag(false)
                    Text("Avançado").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }

            if advanced {
                advancedOptions
            } else {
                easyOptions
            }

            HStack {
                Button("Restaurar padrões") {
                    var fresh = JobOptions()
                    fresh.paper = model.options.paper
                    model.options = fresh
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
    }

    // MARK: Easy

    private var easyOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Cópias: \(model.options.copies)", value: $model.options.copies, in: 1...99)
                    HStack {
                        Text("Páginas")
                        TextField("Todas (ex.: 1-3, 5, 8-)", text: $model.options.range)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Papel", selection: $model.options.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Orientação", selection: $model.options.orientation) {
                        ForEach(Orientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Imprimir dos dois lados (virar as folhas à mão)", isOn: Binding(
                        get: { model.options.duplex != .off },
                        set: { model.options.duplex = $0 ? (model.options.duplex == .off ? .longEdge : model.options.duplex) : .off }
                    ))
                    Toggle("Economizar toner", isOn: $model.options.tonerSave)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if hiddenChanges {
                Label("Há ajustes do modo Avançado ativos.", systemImage: "slider.horizontal.3")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Advanced

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox("Cópias e páginas") {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Cópias: \(model.options.copies)", value: $model.options.copies, in: 1...99)
                    Toggle("Agrupar cópias (1,2,3 · 1,2,3)", isOn: $model.options.collate)
                        .disabled(model.options.copies == 1 || model.options.duplex != .off)
                    HStack {
                        Text("Páginas")
                        TextField("Todas (ex.: 1-3, 5, 8-)", text: $model.options.range)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Ordem inversa", isOn: $model.options.reverse)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Papel e layout") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Papel", selection: $model.options.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Orientação", selection: $model.options.orientation) {
                        ForEach(Orientation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Escala", selection: $model.options.scale) {
                        ForEach(ScaleMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Páginas por folha", selection: $model.options.pagesPerSheet) {
                        ForEach([1, 2, 4, 6, 9], id: \.self) { Text("\($0)").tag($0) }
                    }
                    if model.options.pagesPerSheet > 1 {
                        Toggle("Moldura em cada página", isOn: $model.options.showBorders)
                    }
                    Picker("Margem extra", selection: $model.options.marginMM) {
                        ForEach([0, 5, 10, 15, 20], id: \.self) { Text($0 == 0 ? "Nenhuma" : "\($0) mm").tag($0) }
                    }
                }
                .padding(4)
            }

            GroupBox("Frente e verso manual") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Modo", selection: $model.options.duplex) {
                        ForEach(DuplexMode.allCases) { Text($0.title).tag($0) }
                    }
                    if model.options.duplex != .off {
                        Toggle("Verso em ordem inversa", isOn: $model.options.reverseBackSide)
                        Text("A frente é impressa primeiro; o app pede para você virar as folhas antes do verso.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Qualidade e papel") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Imagens", selection: $model.options.imageMode) {
                        ForEach(ImageMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Densidade do toner", selection: $model.options.density) {
                        Text("Clara").tag(1)
                        Text("Média").tag(3)
                        Text("Escura").tag(5)
                    }
                    Toggle("Economizar toner (rascunho)", isOn: $model.options.tonerSave)
                    Picker("Tipo de papel", selection: $model.options.mediaType) {
                        ForEach(JobOptions.mediaTypes, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Toggle("Alimentação manual (fenda frontal)", isOn: $model.options.manualFeed)
                }
                .padding(4)
            }
        }
    }
}

private struct JobsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fila da impressora").font(.headline)
                    Spacer()
                    Button("Cancelar todos") { Task { await model.cancelAllJobs() } }.buttonStyle(.link)
                }
                ForEach(model.jobs) { job in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(job.name).lineLimit(1)
                            Text("\(job.stateText) · \(job.user)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancelar") { Task { await model.cancel(job) } }.buttonStyle(.borderless)
                    }
                    Divider()
                }
            }
        }
    }
}

private struct PrintBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                switch model.activity {
                case .idle:
                    EmptyView()
                case .preparing(let name, let done, let total):
                    Text("Preparando “\(name)” — \(done)/\(total)").font(.callout)
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                case .sending(let name):
                    HStack { ProgressView().controlSize(.small); Text("Enviando “\(name)”…") }.font(.callout)
                case .waiting(let name):
                    Text("Aguardando você virar as folhas de “\(name)”…").font(.callout)
                case .finished(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                case .failed(let text):
                    Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                }
            }
            Spacer()
            if model.isBusy {
                Button("Cancelar") { model.cancelPrinting() }
            }
            Button {
                model.printAll()
            } label: {
                Label("Imprimir", systemImage: "printer").frame(minWidth: 90)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(model.files.isEmpty || model.isBusy || model.status == nil)
        }
    }
}

// MARK: - Wireless utility

private struct WirelessView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Rede sem fio da impressora", systemImage: "wifi").font(.title3.bold())
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            GroupBox("Conexão atual") {
                Group {
                    if model.wirelessLoading && model.wireless == nil {
                        HStack { ProgressView().controlSize(.small); Text("Consultando a impressora…") }
                    } else if let info = model.wireless {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            row("Rede (SSID)", info.ssid)
                            row("Canal", info.channel.isEmpty ? "—" : "\(info.channel)  (\(info.frequency))")
                            row("Roteador (BSSID)", info.accessPoint)
                            row("Endereço IP", info.ipAddress)
                            row("Máscara", info.subnetMask)
                            row("Gateway", info.gateway)
                            row("Endereço MAC", info.macAddress)
                            row("Nome na rede", info.hostName)
                            row("Firmware", info.firmware)
                        }
                    } else {
                        Label("A impressora não respondeu por SNMP em \(model.client.host).", systemImage: "wifi.slash")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Trocar de rede") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A impressora usa Wi-Fi de 2,4 GHz (802.11 b/g/n). Redes só de 5 GHz não aparecem para ela.")
                        .font(.callout).foregroundStyle(.secondary)

                    Text("1. Pelo botão WPS (sem digitar senha)").font(.headline)
                    Text("Segure o botão WPS da impressora até o LED piscar e, em até 2 minutos, aperte o botão WPS do roteador. Consulte o manual para o tempo exato do seu modelo.")
                        .font(.callout)

                    Text("2. Pelo painel da impressora (dentro do app)").font(.headline)
                    Text("Abra o painel, entre com a conta de administrador (a senha é sua, o app não a guarda) e vá em Configurações de rede ▸ Sem fio. Lá você escolhe a rede e digita a senha. Depois de salvar, a impressora muda de rede e pode ganhar outro IP; use “Procurar impressora” para achá-la.")
                        .font(.callout)
                    HStack {
                        Button("Abrir painel aqui no app") {
                            model.showWireless = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showAdminPanel = true }
                        }
                        Button("Abrir no navegador") { model.openAdminPage() }
                        Button("Copiar endereço IP") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.client.host, forType: .string)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Button("Atualizar") { Task { await model.loadWireless() } }
                Menu(model.discovery.scanning ? "Procurando…" : "Procurar impressora") {
                    Button("Procurar na rede") { Task { await model.discovery.scan() } }
                        .disabled(model.discovery.scanning)
                    Divider()
                    ForEach(model.discovery.printers) { printer in
                        Button(printer.name) {
                            Task {
                                await model.use(printer)
                                await model.loadWireless()
                            }
                        }
                    }
                    if model.discovery.printers.isEmpty { Text("Nenhuma impressora encontrada") }
                }
                .fixedSize()
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.loadWireless() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }
}

private struct Footer: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Developed by Wesley Melo (")
            if let url = URL(string: "https://greatcode.com.br") {
                Link("GreatCode.com.br", destination: url)
            }
            Text(")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
