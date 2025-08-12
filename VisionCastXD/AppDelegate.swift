import Cocoa
import ReSwift

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

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleStatusBarRefresh),
                                               name: Notification.Name("StatusBarRefreshRequest"),
                                               object: nil)

        var selected = currentSelectedDisplayUUIDs()
        selected.formUnion(VirtualDisplayManager.shared.currentVirtualUUIDs())
        UserDefaults.standard.set(Array(selected), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized { MultiDisplayNDIManager.shared.start() }

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
        NotificationCenter.default.removeObserver(self, name: Notification.Name("StatusBarRefreshRequest"), object: nil)
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized { NDIlib_destroy() }
    }
}
