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

        // Carrega configs; NÃO cria nenhum virtual automaticamente
        VirtualDisplayManager.shared.load()
        VirtualDisplayManager.shared.createAllEnabled() // Se não houver, não abre preview algum

        setupStatusBar()

        // Seleção NDI inicial = o que já havia + virtuais habilitados
        var selected = currentSelectedDisplayUUIDs()
        selected.formUnion(VirtualDisplayManager.shared.currentVirtualUUIDs())
        UserDefaults.standard.set(Array(selected), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized {
            MultiDisplayNDIManager.shared.start()
        }

        // Menu simples (somente “Sair”, opcional)
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

    private func setupStatusBar() {
        let sb = StatusBarController()

        // NDI
        sb.onToggleDisplay = { [weak self] displayID, isOn in
            guard let self else {
                return
            }
            guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
                return
            }
            let uuid = CFUUIDCreateString(nil, cf) as String

            var current = self.currentSelectedDisplayUUIDs()
            if isOn {
                current.insert(uuid)
            } else {
                current.remove(uuid)
            }
            UserDefaults.standard.set(Array(current), forKey: self.kSelectedDisplayUUIDs)
            MultiDisplayNDIManager.shared.setSelectedDisplays(current)

            // Atualiza a UI do menu imediatamente
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
            guard let self else {
                return
            }
            let item = VirtualDisplayManager.shared.listForMenu().first {
                $0.id == configID
            }
            if item?.enabled == true {
                // Desabilitar: remove do NDI e fecha preview
                if let uuid = VirtualDisplayManager.shared.uuidString(for: configID) {
                    var cur = self.currentSelectedDisplayUUIDs()
                    cur.remove(uuid)
                    UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                    MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
                }
                _ = VirtualDisplayManager.shared.setEnabled(configID: configID, enabled: false)
            } else {
                // Habilitar: cria, abre preview e inclui no NDI
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
            guard let self else {
                return
            }
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
            guard let self else {
                return
            }
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

    // Dialogs utilitários
    private func promptAddCustomVirtual() {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else {
            return
        }
        let id = VirtualDisplayManager.shared.addVirtual(width: w, height: h, name: "Virtual \(w)x\(h)", enabled: true)
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
        let alert = NSAlert()
        alert.messageText = "Renomear Display Virtual"
        alert.informativeText = "Defina um novo nome."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancelar")

        let tf = NSTextField(string: "")
        tf.placeholderString = "Nome"
        tf.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = tf

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        VirtualDisplayManager.shared.rename(configID: id, to: name)
        statusBar?.refresh()
    }

    private func promptEditResolutionVirtual(id: String) {
        let (w, h) = promptResolution(defaultW: 1920, defaultH: 1080) ?? (0, 0)
        guard w > 0, h > 0 else {
            return
        }
        VirtualDisplayManager.shared.updateResolution(configID: id, width: w, height: h)
        statusBar?.refresh()
    }

    private func promptResolution(defaultW: Int, defaultH: Int) -> (Int, Int)? {
        let alert = NSAlert()
        alert.messageText = "Resolução"
        alert.informativeText = "Defina largura × altura (em pixels)."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancelar")

        let widthField = NSTextField(string: "\(defaultW)")
        widthField.alignment = .right
        widthField.frame = NSRect(x: 0, y: 28, width: 120, height: 24)
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.frame = NSRect(x: 124, y: 28, width: 14, height: 24)
        xLabel.alignment = .center
        let heightField = NSTextField(string: "\(defaultH)")
        heightField.alignment = .right
        heightField.frame = NSRect(x: 140, y: 28, width: 120, height: 24)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        accessory.addSubview(widthField)
        accessory.addSubview(xLabel)
        accessory.addSubview(heightField)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let w = Int(widthField.stringValue) ?? 0
        let h = Int(heightField.stringValue) ?? 0
        guard w > 0, h > 0 else {
            return nil
        }
        return (w, h)
    }

    private func currentSelectedDisplayUUIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: kSelectedDisplayUUIDs) as? [String] {
            return Set(arr)
        }
        return []
    }

    // Compatibilidade (caso algum fluxo legado chame)
    func applyStoredResolution() {
        let defaults = UserDefaults.standard
        let w = defaults.integer(forKey: kCustomWidth)
        let h = defaults.integer(forKey: kCustomHeight)
        guard w > 0, h > 0 else {
            return
        }
        // Sem janela principal padrão para redimensionar. Mantido para compatibilidade.
    }

    func applicationWillTerminate(_: Notification) {
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized {
            NDIlib_destroy()
        }
    }
}
