import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var ndiInitialized = false
    private var statusBar: StatusBarController?
    private var screenVC: ScreenViewController!

    private let kCustomWidth = "customWidth"
    private let kCustomHeight = "customHeight"
    private let kSelectedDisplayUUIDs = "selectedDisplayUUIDs"

    func applicationDidFinishLaunching(_: Notification) {
        if NDIlib_initialize() {
            ndiInitialized = true
            print("NDI inicializado com sucesso")
        } else {
            print("Falha ao inicializar NDI")
        }

        // Carrega configs e cria TODOS os virtuais habilitados (com preview)
        VirtualDisplayManager.shared.load()
        VirtualDisplayManager.shared.createAllEnabled()

        // Janela/preview principal existente
        let viewController = ScreenViewController()
        screenVC = viewController

        let defaults = UserDefaults.standard
        let requestedWidth: Int = defaults.integer(forKey: kCustomWidth) > 0 ? defaults.integer(forKey: kCustomWidth) : 1408
        let requestedHeight: Int = defaults.integer(forKey: kCustomHeight) > 0 ? defaults.integer(forKey: kCustomHeight) : 640

        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        let widthInPoints = CGFloat(requestedWidth) / scale
        let heightInPoints = CGFloat(requestedHeight) / scale

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: widthInPoints, height: heightInPoints),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.delegate = viewController
        window.title = "Vision Cast XD"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 3840, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentView?.wantsLayer = true
        if let layer = window.contentView?.layer {
            layer.contentsScale = 1.0
            layer.rasterizationScale = 1.0
        }
        window.contentView?.wantsBestResolutionOpenGLSurface = false

        applyPixelPerfectResolution(width: requestedWidth, height: requestedHeight)
        window.makeKeyAndOrderFront(nil)

        setupStatusBar()

        // Seleção NDI: mantém o que já tinha e soma os virtuais habilitados
        var selected = currentSelectedDisplayUUIDs()
        selected.formUnion(VirtualDisplayManager.shared.currentVirtualUUIDs())
        UserDefaults.standard.set(Array(selected), forKey: kSelectedDisplayUUIDs)
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized { MultiDisplayNDIManager.shared.start() }

        // Menu simples do app
        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")
        let resolutionItem = NSMenuItem(title: "Custom Resolution...", action: #selector(openCustomResolutionWindow), keyEquivalent: "r")
        resolutionItem.target = self
        subMenu.addItem(resolutionItem)
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
        subMenu.addItem(quitMenuItem)
        mainMenuItem.submenu = subMenu
        mainMenu.items = [mainMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    private func setupStatusBar() {
        let sb = StatusBarController()

        // Janela/preview principal
        sb.onPickResolution = { [weak self] w, h in
            guard let self else { return }
            let defaults = UserDefaults.standard
            defaults.set(w, forKey: self.kCustomWidth)
            defaults.set(h, forKey: self.kCustomHeight)
            self.applyPixelPerfectResolution(width: w, height: h)
            self.screenVC?.applyVirtualDisplayMode(width: w, height: h)
        }
        sb.onOpenCustomResolution = { [weak self] in self?.openCustomResolutionWindow() }

        // NDI displays
        sb.onToggleDisplay = { [weak self] displayID, isOn in
            guard let self else { return }
            guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
            let uuid = CFUUIDCreateString(nil, cf) as String
            var current = self.currentSelectedDisplayUUIDs()
            if isOn { current.insert(uuid) } else { current.remove(uuid) }
            UserDefaults.standard.set(Array(current), forKey: self.kSelectedDisplayUUIDs)
            MultiDisplayNDIManager.shared.setSelectedDisplays(current)
        }
        sb.selectedUUIDsProvider = { [weak self] in self?.currentSelectedDisplayUUIDs() ?? [] }

        // Displays Virtuais
        sb.virtualItemsProvider = {
            VirtualDisplayManager.shared.listForMenu().map {
                StatusBarController.VirtualItem(id: $0.id, title: $0.title, sizeText: $0.size, enabled: $0.enabled)
            }
        }
        sb.onToggleVirtualItem = { [weak self] configID, enable in
            guard let self else { return }
            if !enable {
                if let uuid = VirtualDisplayManager.shared.uuidString(for: configID) {
                    var cur = self.currentSelectedDisplayUUIDs()
                    cur.remove(uuid)
                    UserDefaults.standard.set(Array(cur), forKey: self.kSelectedDisplayUUIDs)
                    MultiDisplayNDIManager.shared.setSelectedDisplays(cur)
                }
                _ = VirtualDisplayManager.shared.setEnabled(configID: configID, enabled: false)
                self.statusBar?.refresh()
                return
            }
            if let did = VirtualDisplayManager.shared.setEnabled(configID: configID, enabled: true) {
                if let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() {
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

        statusBar = sb
    }

    // Caixa de diálogo simples para width/height customizados
    private func promptAddCustomVirtual() {
        let alert = NSAlert()
        alert.messageText = "Novo Display Virtual"
        alert.informativeText = "Defina a resolução desejada (em pixels)."
        alert.addButton(withTitle: "Criar")
        alert.addButton(withTitle: "Cancelar")

        let widthField = NSTextField(string: "1920")
        widthField.placeholderString = "Largura"
        widthField.alignment = .right
        widthField.frame = NSRect(x: 0, y: 28, width: 120, height: 24)

        let xLabel = NSTextField(labelWithString: "×")
        xLabel.frame = NSRect(x: 124, y: 28, width: 14, height: 24)
        xLabel.alignment = .center

        let heightField = NSTextField(string: "1080")
        heightField.placeholderString = "Altura"
        heightField.alignment = .right
        heightField.frame = NSRect(x: 140, y: 28, width: 120, height: 24)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        accessory.addSubview(widthField)
        accessory.addSubview(xLabel)
        accessory.addSubview(heightField)
        alert.accessoryView = accessory

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        let w = Int(widthField.stringValue) ?? 0
        let h = Int(heightField.stringValue) ?? 0
        guard w > 0, h > 0 else { return }

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

    private func currentSelectedDisplayUUIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: kSelectedDisplayUUIDs) as? [String] {
            return Set(arr)
        }
        return []
    }

    @objc func openCustomResolutionWindow() {
        let controller = CustomResolutionWindowController()
        controller.showWindow(nil)
    }

    func applyStoredResolution() {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: kCustomWidth)
        let height = defaults.integer(forKey: kCustomHeight)
        applyPixelPerfectResolution(width: width, height: height)
    }

    func applyPixelPerfectResolution(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let backingScale = screen.backingScaleFactor
        let scaledWidth = CGFloat(width) / backingScale
        let scaledHeight = CGFloat(height) / backingScale
        let newOrigin = window.frame.origin
        let frame = NSRect(origin: newOrigin, size: CGSize(width: scaledWidth, height: scaledHeight))
        window.setFrame(frame, display: true, animate: true)
        window.center()
    }

    func applicationWillTerminate(_: Notification) {
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized { NDIlib_destroy() }
    }
}
