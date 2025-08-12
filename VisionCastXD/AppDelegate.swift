import Cocoa
import Network
import ReSwift

protocol LocalHTTPServerDelegate: AnyObject {
    func httpServerListStreamsJSON() -> Data
    func httpServerStartStream(uuid: String) -> Data
    func httpServerStopStream(uuid: String) -> Data
    func httpServerJPEGFrame(uuid: String) -> Data?
}

final class LocalHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private weak var delegate: LocalHTTPServerDelegate?
    private struct MJPEGContext {
        let connection: NWConnection
        let uuid: String
        var timer: Timer?
    }

    private var mjpegSessions: [ObjectIdentifier: MJPEGContext] = [:]

    init(port: UInt16, delegate: LocalHTTPServerDelegate) {
        self.port = port
        self.delegate = delegate
    }

    func start() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("LocalHTTPServer ready on port \(self.port)")
                case let .failed(err):
                    print("LocalHTTPServer failed: \(err)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.start(queue: .main)
        } catch {
            print("LocalHTTPServer error starting: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive(on: connection)
            case let .failed(err):
                print("HTTP connection failed: \(err)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error {
                print("HTTP receive error: \(error)")
                connection.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                else { self.receive(on: connection) }
                return
            }
            // Very small HTTP/1.1 parser for GET/POST/OPTIONS
            let request = String(decoding: data, as: UTF8.self)
            let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else { self.send(status: 400, body: Data(), on: connection); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { self.send(status: 400, body: Data(), on: connection); return }
            let method = String(parts[0])
            let path = String(parts[1])

            if method == "OPTIONS" {
                self.send(status: 204, body: Data(), on: connection)
                return
            }

            // Routes
            if method == "GET", path == "/api/streams" {
                let json = delegate?.httpServerListStreamsJSON() ?? Data()
                self.sendJSON(json, on: connection)
                return
            }
            if method == "POST", path.hasPrefix("/api/streams/"), path.hasSuffix("/start") {
                if let uuid = path.components(separatedBy: "/").dropFirst(3).first {
                    let json = delegate?.httpServerStartStream(uuid: uuid) ?? Data()
                    self.sendJSON(json, on: connection)
                    return
                }
            }
            if method == "POST", path.hasPrefix("/api/streams/"), path.hasSuffix("/stop") {
                if let uuid = path.components(separatedBy: "/").dropFirst(3).first {
                    let json = delegate?.httpServerStopStream(uuid: uuid) ?? Data()
                    self.sendJSON(json, on: connection)
                    return
                }
            }

            // GET /api/streams/{uuid}/preview.mjpg
            if method == "GET", path.hasPrefix("/api/streams/"), path.hasSuffix("/preview.mjpg") {
                if let uuid = path.components(separatedBy: "/").dropFirst(3).first {
                    self.startMJPEGStream(uuid: uuid, on: connection)
                    return
                }
            }

            // GET /display/{n}
            if method == "GET", path.hasPrefix("/display/") {
                if let numStr = path.split(separator: "/").dropFirst().first,
                   let index = Int(numStr),
                   index > 0
                {
                    let items = VirtualDisplayManager.shared.listForMenu()
                    if index <= items.count,
                       let uuid = VirtualDisplayManager.shared.uuidString(for: items[index - 1].id)
                    {
                        // Redireciona ou serve diretamente o MJPEG
                        self.startMJPEGStream(uuid: uuid, on: connection)
                        return
                    }
                }
            }

            // Fallback 404
            let notFound = try? JSONSerialization.data(withJSONObject: ["error": "not found"], options: [])
            self.send(status: 404, body: notFound ?? Data(), on: connection, contentType: "application/json")
        }
    }

    private func sendJSON(_ body: Data, on connection: NWConnection) {
        send(status: 200, body: body, on: connection, contentType: "application/json")
    }

    private func send(status: Int, body: Data, on connection: NWConnection, contentType: String = "text/plain") {
        var headers = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Connection: close\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type\r\n\r\n"
        let headData = Data(headers.utf8)
        connection.send(content: headData + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func startMJPEGStream(uuid: String, on connection: NWConnection) {
        let boundary = "frameboundarya1b2c3"
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Expires: 0\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n\r\n"

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            var ctx = MJPEGContext(connection: connection, uuid: uuid, timer: nil)
            let id = ObjectIdentifier(connection)

            // ~10 FPS
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                guard let jpeg = self.delegate?.httpServerJPEGFrame(uuid: uuid) else { return }
                var part = "\r\n--\(boundary)\r\n"
                part += "Content-Type: image/jpeg\r\n"
                part += "Content-Length: \(jpeg.count)\r\n\r\n"
                let head = Data(part.utf8)
                self.connectionSend(connection, data: head + jpeg)
            }

            ctx.timer = timer
            self.mjpegSessions[id] = ctx
        })

        connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if case .failed = st { self.stopMJPEG(on: connection) }
            if case .cancelled = st { self.stopMJPEG(on: connection) }
        }
    }

    private func stopMJPEG(on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        if var ctx = mjpegSessions.removeValue(forKey: id) {
            ctx.timer?.invalidate()
        }
        connection.cancel()
    }

    private func connectionSend(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
            if sendError != nil {
                self?.stopMJPEG(on: connection)
            }
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "OK"
        }
    }
}

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var ndiInitialized = false
    private var statusBar: StatusBarController?

    private var refreshWorkItem: DispatchWorkItem?
    private let refreshDebounce: TimeInterval = 0.3

    private let kSelectedDisplayUUIDs = "selectedDisplayUUIDs"

    private var httpServer: LocalHTTPServer?

    func applicationDidFinishLaunching(_: Notification) {
        // Defaults (30 fps por padrão, preview half-res desligado)
        UserDefaults.standard.register(defaults: [
            "preferredFPS": 30,
            "previewHalfRes": false,
        ])

        if NDIlib_initialize() { ndiInitialized = true } else { print("Falha ao inicializar NDI") }

        VirtualDisplayManager.shared.load()

        // Criar primeira tela (mantido se desejar)
        if VirtualDisplayManager.shared.listForMenu().isEmpty {
            if let (name, w, h) = promptCreateFirstVirtual() {
                let id = VirtualDisplayManager.shared.addVirtual(width: w, height: h, name: name, enabled: true)
                if let did = VirtualDisplayManager.shared.cgDisplayID(for: id),
                   let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
                {
                    let uuid = CFUUIDCreateString(nil, cf) as String
                    var cur = currentSelectedDisplayUUIDs()
                    cur.insert(uuid)
                    UserDefaults.standard.set(Array(cur), forKey: kSelectedDisplayUUIDs)
                    MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
                }
            }
        }

        VirtualDisplayManager.shared.createAllEnabled()
        setupStatusBar()

        statusBar?.refresh()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleStatusBarRefresh),
                                               name: Notification.Name("StatusBarRefreshRequest"),
                                               object: nil)

        var selected = currentSelectedDisplayUUIDs()
        selected.formUnion(VirtualDisplayManager.shared.currentVirtualUUIDs())
        UserDefaults.standard.set(Array(selected), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized { MultiDisplayNDIManager.shared.start() }

        // Start local HTTP API to expose streams on http://127.0.0.1:8777
        let server = LocalHTTPServer(port: 8777, delegate: self)
        httpServer = server
        server.start()

        // Menu app
        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        subMenu.addItem(quit)
        mainMenuItem.submenu = subMenu
        mainMenu.items = [mainMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    @objc private func handleStatusBarRefresh() { requestStatusBarRefresh() }

    private func requestStatusBarRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusBar?.refresh() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounce, execute: work)
    }

    private func currentSelectedDisplayUUIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: kSelectedDisplayUUIDs) as? [String] { return Set(arr) }
        return []
    }

    private func setupStatusBar() {
        let sb = StatusBarController()

        // NDI
        sb.onToggleDisplay = { [weak self] displayID, isOn in
            guard let self else { return }
            guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
            let uuid = CFUUIDCreateString(nil, cf) as String
            var current = self.currentSelectedDisplayUUIDs()
            if isOn { current.insert(uuid) } else { current.remove(uuid) }
            UserDefaults.standard.set(Array(current), forKey: self.kSelectedDisplayUUIDs)
            MultiDisplayNDIManager.shared.setSelectedDisplays(current)
            self.requestStatusBarRefresh()
        }

        sb.selectedUUIDsProvider = { [weak self] in self?.currentSelectedDisplayUUIDs() ?? [] }

        // Displays Virtuais
        sb.virtualItemsProvider = {
            VirtualDisplayManager.shared.listForMenu().map {
                StatusBarController.VirtualItem(id: $0.id, title: $0.title, sizeText: $0.size, enabled: $0.enabled)
            }
        }
        sb.onToggleVirtualItem = { [weak self] configID, _ in
            guard let self else { return }
            let item = VirtualDisplayManager.shared.listForMenu().first { $0.id == configID }
            if item?.enabled == true {
                if let uuid = VirtualDisplayManager.shared.uuidString(for: configID) {
                    var cur = self.currentSelectedDisplayUUIDs()
                    cur.remove(uuid)
                    UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                    MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
                }
                _ = VirtualDisplayManager.shared.setEnabled(configID: configID, enabled: false)
            } else {
                if let did = VirtualDisplayManager.shared.setEnabled(configID: configID, enabled: true),
                   let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
                {
                    let uuid = CFUUIDCreateString(nil, cf) as String
                    var cur = self.currentSelectedDisplayUUIDs()
                    cur.insert(uuid)
                    UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                    MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
                }
            }
            self.requestStatusBarRefresh()
        }
        sb.onAddVirtualPreset = { [weak self] w, h in
            guard let self else { return }
            let id = VirtualDisplayManager.shared.addVirtual(width: w, height: h, name: "Virtual \(w)x\(h)", enabled: true)
            if let did = VirtualDisplayManager.shared.cgDisplayID(for: id),
               let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
            {
                let uuid = CFUUIDCreateString(nil, cf) as String
                var cur = self.currentSelectedDisplayUUIDs()
                cur.insert(uuid)
                UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
            }
            self.requestStatusBarRefresh()
        }
        sb.onAddVirtualCustom = { [weak self] in self?.promptAddCustomVirtual() }
        sb.onRenameVirtual = { [weak self] id in self?.promptRenameVirtual(id: id) }
        sb.onEditVirtualPreset = { [weak self] id, w, h in
            VirtualDisplayManager.shared.updateResolution(configID: id, width: w, height: h)
            self?.requestStatusBarRefresh()
        }
        sb.onEditVirtualCustom = { [weak self] id in self?.promptEditResolutionVirtual(id: id) }
        sb.onRemoveVirtual = { [weak self] id in
            guard let self else { return }
            if let uuid = VirtualDisplayManager.shared.uuidString(for: id) {
                var cur = self.currentSelectedDisplayUUIDs()
                cur.remove(uuid)
                UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
            }
            VirtualDisplayManager.shared.removeConfig(configID: id)
            self.requestStatusBarRefresh()
        }

        // Preferências (FPS e Half-res)
        sb.onSetFPS = { [weak self] fps in
            guard let self else { return }
            Preferences.setPreferredFPS(fps)
            // Reinicia pipelines do NDI com novo FPS
            let current = MultiDisplayNDIManager.shared.selectedDisplayUUIDs
            MultiDisplayNDIManager.shared.stopAll()
            MultiDisplayNDIManager.shared.setSelectedDisplays(current)
            MultiDisplayNDIManager.shared.start()
            // Reinicia previews (FPS aplicado no start)
            VirtualDisplayManager.shared.refreshPreviewsForPreferencesChange()
            self.requestStatusBarRefresh()
        }
        sb.onToggleHalfRes = { [weak self] isOn in
            guard let self else { return }
            Preferences.setPreviewHalfRes(isOn)
            // Recria previews com novo tamanho em pontos
            VirtualDisplayManager.shared.refreshPreviewsForPreferencesChange()
            self.requestStatusBarRefresh()
        }

        statusBar = sb
    }

    // MARK: - Dialogs utilitários (os existentes + criar primeira tela)

    private func promptAddCustomVirtual() {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else { return }
        guard let name = promptName(defaultName: "Virtual \(w)x\(h)") else { return }
        let id = VirtualDisplayManager.shared.addVirtual(width: w, height: h, name: name, enabled: true)
        if let did = VirtualDisplayManager.shared.cgDisplayID(for: id),
           let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
        {
            let uuid = CFUUIDCreateString(nil, cf) as String
            var cur = currentSelectedDisplayUUIDs()
            cur.insert(uuid)
            UserDefaults.standard.set(Array(cur), forKey: kSelectedDisplayUUIDs)
            MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
        }
        requestStatusBarRefresh()
    }

    // Compatibilidade: chamado pelo CustomResolutionViewController
    // Lê a resolução salva (customWidth/customHeight) e aplica na primeira tela virtual habilitada.
    func applyStoredResolution() {
        let defaults = UserDefaults.standard
        let w = defaults.integer(forKey: "customWidth")
        let h = defaults.integer(forKey: "customHeight")
        guard w > 0, h > 0 else {
            return
        }

        // Aplica na primeira tela virtual habilitada (se existir)
        if let firstEnabled = VirtualDisplayManager.shared.listForMenu().first(where: { $0.enabled })?.id {
            VirtualDisplayManager.shared.updateResolution(configID: firstEnabled, width: w, height: h)
            // Atualiza menus/estado
            NotificationCenter.default.post(name: Notification.Name("StatusBarRefreshRequest"), object: nil)
        }
    }

    // ... dentro da classe AppDelegate ...

    // MARK: - Dialogs utilitários

    // Formatter que aceita apenas dígitos e mostra um aviso no próprio diálogo
    private final class DigitsOnlyFormatter: NumberFormatter {
        private let onInvalid: (() -> Void)?

        init(onInvalid: (() -> Void)? = nil) {
            self.onInvalid = onInvalid
            super.init()
            numberStyle = .none
            minimum = 1
            maximum = 100_000
            allowsFloats = false
            generatesDecimalNumbers = false
        }

        required init?(coder: NSCoder) {
            onInvalid = nil
            super.init(coder: coder)
        }

        override func isPartialStringValid(_ partialString: String,
                                           newEditingString _: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                           errorDescription _: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool
        {
            if partialString.isEmpty { return true }
            if partialString.allSatisfy({ $0.isNumber }) { return true }
            NSSound.beep()
            onInvalid?()
            return false
        }
    }

    // Pede resolução (somente números). Retorna nil se cancelar.
    private func promptResolution(defaultW: Int, defaultH: Int) -> (Int, Int)? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Resolução"
            alert.informativeText = "Digite apenas números (largura × altura em pixels)."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancelar")

            let errorLabel = NSTextField(labelWithString: "Somente números")
            errorLabel.textColor = .systemRed
            errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            errorLabel.isHidden = true
            errorLabel.frame = NSRect(x: 0, y: 4, width: 260, height: 16)

            let formatter = DigitsOnlyFormatter(onInvalid: { [weak errorLabel] in
                errorLabel?.isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { errorLabel?.isHidden = true }
            })

            let widthField = NSTextField(string: "\(defaultW)")
            widthField.alignment = .right
            widthField.frame = NSRect(x: 0, y: 28, width: 120, height: 24)
            widthField.placeholderString = "Largura"
            widthField.formatter = formatter

            let xLabel = NSTextField(labelWithString: "×")
            xLabel.frame = NSRect(x: 124, y: 28, width: 14, height: 24)
            xLabel.alignment = .center

            let heightField = NSTextField(string: "\(defaultH)")
            heightField.alignment = .right
            heightField.frame = NSRect(x: 140, y: 28, width: 120, height: 24)
            heightField.placeholderString = "Altura"
            heightField.formatter = formatter

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
            accessory.addSubview(widthField)
            accessory.addSubview(xLabel)
            accessory.addSubview(heightField)
            accessory.addSubview(errorLabel)
            alert.accessoryView = accessory

            let resp = alert.runModal()
            guard resp == .alertFirstButtonReturn else { return nil }

            let w = (widthField.stringValue as NSString).integerValue
            let h = (heightField.stringValue as NSString).integerValue
            if w > 0, h > 0 { return (w, h) }

            let err = NSAlert()
            err.messageText = "Valor inválido"
            err.informativeText = "Use apenas números maiores que zero para largura e altura."
            err.addButton(withTitle: "OK")
            err.runModal()
        }
    }

    // Pede um nome (padrão preenchido). Retorna nil se cancelar.
    private func promptName(defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Nome do Display"
        alert.informativeText = "Defina um nome para o display virtual."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancelar")

        let tf = NSTextField(string: defaultName)
        tf.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = tf

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        return tf.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    // Modal para criar a primeira tela (nome + resolução com validação numérica)
    private func promptCreateFirstVirtual() -> (String, Int, Int)? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Crie sua primeira tela"
            alert.informativeText = "Informe um nome e a resolução (largura × altura em pixels)."
            alert.addButton(withTitle: "Criar")
            alert.addButton(withTitle: "Cancelar")

            let errorLabel = NSTextField(labelWithString: "Somente números")
            errorLabel.textColor = .systemRed
            errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            errorLabel.isHidden = true
            errorLabel.frame = NSRect(x: 0, y: 4, width: 360, height: 16)

            let formatter = DigitsOnlyFormatter(onInvalid: { [weak errorLabel] in
                errorLabel?.isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { errorLabel?.isHidden = true }
            })

            let nameField = NSTextField(string: "Minha Tela 1")
            nameField.frame = NSRect(x: 0, y: 60, width: 360, height: 24)
            nameField.placeholderString = "Nome"

            let widthField = NSTextField(string: "1920")
            widthField.alignment = .right
            widthField.frame = NSRect(x: 0, y: 28, width: 140, height: 24)
            widthField.placeholderString = "Largura"
            widthField.formatter = formatter

            let xLabel = NSTextField(labelWithString: "×")
            xLabel.frame = NSRect(x: 146, y: 28, width: 14, height: 24)
            xLabel.alignment = .center

            let heightField = NSTextField(string: "1080")
            heightField.alignment = .right
            heightField.frame = NSRect(x: 164, y: 28, width: 140, height: 24)
            heightField.placeholderString = "Altura"
            heightField.formatter = formatter

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))
            accessory.addSubview(nameField)
            accessory.addSubview(widthField)
            accessory.addSubview(xLabel)
            accessory.addSubview(heightField)
            accessory.addSubview(errorLabel)
            alert.accessoryView = accessory

            let resp = alert.runModal()
            guard resp == .alertFirstButtonReturn else { return nil }

            let name = nameField.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let w = (widthField.stringValue as NSString).integerValue
            let h = (heightField.stringValue as NSString).integerValue
            if !name.isEmpty, w > 0, h > 0 {
                return (name, w, h)
            }

            let err = NSAlert()
            err.messageText = "Dados inválidos"
            err.informativeText = "Informe um nome e números maiores que zero para largura e altura."
            err.addButton(withTitle: "OK")
            err.runModal()
        }
    }

    // Editar resolução de uma tela existente
    private func promptEditResolutionVirtual(id: String) {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else { return }
        VirtualDisplayManager.shared.updateResolution(configID: id, width: w, height: h)
        // Atualiza menu
        NotificationCenter.default.post(name: Notification.Name("StatusBarRefreshRequest"), object: nil)
    }

    private func promptRenameVirtual(id: String) {
        if let name = promptName(defaultName: "") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            VirtualDisplayManager.shared.rename(configID: id, to: trimmed)
            requestStatusBarRefresh()
        }
    }

    // promptResolution / promptName / promptCreateFirstVirtual seguem iguais aos já adicionados

    func applicationWillTerminate(_: Notification) {
        httpServer?.stop()
        NotificationCenter.default.removeObserver(self, name: Notification.Name("StatusBarRefreshRequest"), object: nil)
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized { NDIlib_destroy() }
    }
}

extension AppDelegate: LocalHTTPServerDelegate {
    // GET /api/streams
    func httpServerListStreamsJSON() -> Data {
        // Build a list with all virtual items + whether each UUID is selected for NDI
        let selectedUUIDs = MultiDisplayNDIManager.shared.selectedDisplayUUIDs
        let items = VirtualDisplayManager.shared.listForMenu().map { item -> [String: Any] in
            var dict: [String: Any] = [
                "id": item.id,
                "title": item.title,
                "size": item.size,
                "enabled": item.enabled,
            ]
            if let uuid = VirtualDisplayManager.shared.uuidString(for: item.id) {
                dict["uuid"] = uuid
                dict["ndiEnabled"] = selectedUUIDs.contains(uuid)
            }
            return dict
        }
        let obj: [String: Any] = [
            "streams": items,
            "ndiRunning": ndiInitialized,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
        return data
    }

    // POST /api/streams/{uuid}/start
    func httpServerStartStream(uuid: String) -> Data {
        var current = MultiDisplayNDIManager.shared.selectedDisplayUUIDs
        current.insert(uuid)
        UserDefaults.standard.set(Array(current), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(current)
        if ndiInitialized { MultiDisplayNDIManager.shared.start() }
        return httpServerListStreamsJSON()
    }

    // POST /api/streams/{uuid}/stop
    func httpServerStopStream(uuid: String) -> Data {
        var current = MultiDisplayNDIManager.shared.selectedDisplayUUIDs
        current.remove(uuid)
        UserDefaults.standard.set(Array(current), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(current)
        return httpServerListStreamsJSON()
    }

    func httpServerJPEGFrame(uuid: String) -> Data? {
        // Localiza a tela virtual
        guard let item = VirtualDisplayManager.shared.listForMenu()
            .first(where: { VirtualDisplayManager.shared.uuidString(for: $0.id) == uuid }),
            let did = VirtualDisplayManager.shared.cgDisplayID(for: item.id),
            let cgimg = CGDisplayCreateImage(did)
        else {
            return nil
        }

        // Tamanho da tela capturada
        let srcWidth = CGFloat(cgimg.width)
        let srcHeight = CGFloat(cgimg.height)

        // Escolhe tamanho alvo com base na tela capturada (escala para um "limite" sem ultrapassar)
        let maxWidth: CGFloat = 1920
        let maxHeight: CGFloat = 1080

        // Calcula escala proporcional para encaixar no canvas alvo
        let scale = min(maxWidth / srcWidth, maxHeight / srcHeight)
        let targetWidth = srcWidth * scale
        let targetHeight = srcHeight * scale

        // Cria imagem final no tamanho alvo fixo (maxWidth × maxHeight)
        let outImage = NSImage(size: NSSize(width: maxWidth, height: maxHeight))
        outImage.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: maxWidth, height: maxHeight)).fill()

        // Desenha imagem centralizada mantendo proporção
        let offsetX = (maxWidth - targetWidth) / 2
        let offsetY = (maxHeight - targetHeight) / 2
        let image = NSImage(cgImage: cgimg, size: NSSize(width: srcWidth, height: srcHeight))
        image.draw(in: NSRect(x: offsetX, y: offsetY, width: targetWidth, height: targetHeight),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        outImage.unlockFocus()

        // Exporta JPEG
        guard let tiff = outImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
