import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Janela principal removida (não abrimos preview default)
    var window: NSWindow!
    private var ndiInitialized = false
    private var statusBar: StatusBarController?

    private let kCustomWidth = "customWidth"
    private let kCustomHeight = "customHeight"
    private let kSelectedDisplayUUIDs = "selectedDisplayUUIDs"

    func applicationDidFinishLaunching(_: Notification) {
        if NDIlib_initialize() {
            ndiInitialized = true
        } else {
            print("Falha ao inicializar NDI")
        }

        VirtualDisplayManager.shared.load()

        // Se não existir nenhuma tela, pede para criar a primeira (nome + resolução)
        if VirtualDisplayManager.shared.listForMenu().isEmpty {
            if let (name, w, h) = promptCreateFirstVirtual() {
                let id = VirtualDisplayManager.shared.addVirtual(width: w, height: h, name: name, enabled: true)
                // Inclui no NDI já na inicialização
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

        // Cria todos os virtuais habilitados (e abre seus previews)
        VirtualDisplayManager.shared.createAllEnabled()

        setupStatusBar()

        // Observa pedidos de refresh do Status Bar (ex.: ao fechar preview)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleStatusBarRefresh),
                                               name: Notification.Name("StatusBarRefreshRequest"),
                                               object: nil)

        // Seleção NDI inicial
        var selected = currentSelectedDisplayUUIDs()
        selected.formUnion(VirtualDisplayManager.shared.currentVirtualUUIDs())
        UserDefaults.standard.set(Array(selected), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized {
            MultiDisplayNDIManager.shared.start()
        }

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

    @objc private func handleStatusBarRefresh() {
        statusBar?.refresh()
    }

    private func currentSelectedDisplayUUIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: kSelectedDisplayUUIDs) as? [String] {
            return Set(arr)
        }
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

            self.statusBar?.refresh()
        }

        sb.selectedUUIDsProvider = { [weak self] in
            self?.currentSelectedDisplayUUIDs() ?? []
        }

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
            self.statusBar?.refresh()
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
            self.statusBar?.refresh()
        }
        sb.onAddVirtualCustom = { [weak self] in
            self?.promptAddCustomVirtual()
        }
        sb.onRenameVirtual = { [weak self] id in
            self?.promptRenameVirtual(id: id)
        }
        sb.onEditVirtualPreset = { [weak self] id, w, h in
            VirtualDisplayManager.shared.updateResolution(configID: id, width: w, height: h)
            self?.statusBar?.refresh()
        }
        sb.onEditVirtualCustom = { [weak self] id in
            self?.promptEditResolutionVirtual(id: id)
        }
        sb.onRemoveVirtual = { [weak self] id in
            guard let self else { return }
            if let uuid = VirtualDisplayManager.shared.uuidString(for: id) {
                var cur = self.currentSelectedDisplayUUIDs()
                cur.remove(uuid)
                UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
            }
            VirtualDisplayManager.shared.removeConfig(configID: id)
            self.statusBar?.refresh()
        }

        statusBar = sb
    }

    // MARK: - Dialogs utilitários

    private func promptAddCustomVirtual() {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else { return }

        // Pede nome também
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
        statusBar?.refresh()
    }

    private func promptRenameVirtual(id: String) {
        if let name = promptName(defaultName: "") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            VirtualDisplayManager.shared.rename(configID: id, to: trimmed)
            statusBar?.refresh()
        }
    }

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

    private func promptEditResolutionVirtual(id: String) {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else { return }
        VirtualDisplayManager.shared.updateResolution(configID: id, width: w, height: h)
        statusBar?.refresh()
    }

    // Aceita apenas números; mostra aviso ao tentar caractere inválido e valida ao confirmar
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

    // Pede um nome (padrão preenchido), retorna nil se cancelar
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
        return tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // Compatibilidade (caso algum fluxo legado chame)
    func applyStoredResolution() {
        let defaults = UserDefaults.standard
        let w = defaults.integer(forKey: kCustomWidth)
        let h = defaults.integer(forKey: kCustomHeight)
        guard w > 0, h > 0 else { return }
        // Sem janela principal padrão para redimensionar. Mantido para compatibilidade.
    }

    func applicationWillTerminate(_: Notification) {
        NotificationCenter.default.removeObserver(self, name: Notification.Name("StatusBarRefreshRequest"), object: nil)
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized {
            NDIlib_destroy()
        }
    }
}
