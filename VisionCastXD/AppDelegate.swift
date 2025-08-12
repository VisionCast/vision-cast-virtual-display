import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var ndiInitialized = false
    private var statusBar: StatusBarController?
    private var screenVC: ScreenViewController! // <- manter referência

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

        let selected = loadOrCreateDefaultSelectedDisplayUUIDs()
        MultiDisplayNDIManager.shared.setSelectedDisplays(selected)
        if ndiInitialized {
            MultiDisplayNDIManager.shared.start()
        }

        // Menu de app, atalho para "Custom Resolution..." e "Quit"
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
        sb.onPickResolution = { [weak self] w, h in
            guard let self else { return }
            let defaults = UserDefaults.standard
            defaults.set(w, forKey: self.kCustomWidth)
            defaults.set(h, forKey: self.kCustomHeight)
            self.applyPixelPerfectResolution(width: w, height: h)
            self.screenVC?.applyVirtualDisplayMode(width: w, height: h) // <- aplica no display virtual também
        }
        sb.onOpenCustomResolution = { [weak self] in
            self?.openCustomResolutionWindow()
        }
        sb.onToggleDisplay = { [weak self] displayID, isOn in
            guard let self else { return }
            guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return }
            let uuid = CFUUIDCreateString(nil, cf) as String
            var current = self.currentSelectedDisplayUUIDs()
            if isOn { current.insert(uuid) } else { current.remove(uuid) }
            if current.isEmpty { current = self.defaultDisplayUUIDs() }
            UserDefaults.standard.set(Array(current), forKey: self.kSelectedDisplayUUIDs)
            MultiDisplayNDIManager.shared.setSelectedDisplays(current)
        }
        sb.selectedUUIDsProvider = { [weak self] in
            self?.currentSelectedDisplayUUIDs() ?? []
        }
        statusBar = sb
    }

    private func currentSelectedDisplayUUIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        if let arr = defaults.array(forKey: kSelectedDisplayUUIDs) as? [String] {
            return Set(arr)
        }
        return []
    }

    private func loadOrCreateDefaultSelectedDisplayUUIDs() -> Set<String> {
        let existing = currentSelectedDisplayUUIDs()
        if !existing.isEmpty { return existing }
        let def = defaultDisplayUUIDs()
        UserDefaults.standard.set(Array(def), forKey: kSelectedDisplayUUIDs)
        return def
    }

    private func defaultDisplayUUIDs() -> Set<String> {
        // Tenta achar a tela virtual criada pelo app:
        // usamos vendorID/productID definidos no ScreenViewController (0x3456/0x1234).
        let targetVendor: UInt32 = 0x3456
        let targetProd: UInt32 = 0x1234

        var max = UInt32(16)
        var active = [CGDirectDisplayID](repeating: 0, count: Int(max))
        var count: UInt32 = 0
        _ = CGGetActiveDisplayList(max, &active, &count)
        let list = Array(active.prefix(Int(count)))

        var preferred: CGDirectDisplayID?

        for id in list {
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            if vendor == targetVendor, model == targetProd {
                preferred = id
                break
            }
        }

        let chosenID = preferred ?? NSScreen.main.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        }

        if let id = chosenID,
           let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        {
            let uuid = CFUUIDCreateString(nil, cf) as String
            return [uuid]
        }
        return []
    }

    // MARK: - Resolução

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
        guard let screen = window.screen ?? NSScreen.main else {
            print("No screen available to determine backingScaleFactor.")
            return
        }

        let backingScale = screen.backingScaleFactor
        let scaledWidth = CGFloat(width) / backingScale
        let scaledHeight = CGFloat(height) / backingScale
        let newOrigin = window.frame.origin
        let frame = NSRect(origin: newOrigin, size: CGSize(width: scaledWidth, height: scaledHeight))

        window.setFrame(frame, display: true, animate: true)
        window.center()

        print("Requested size: \(width)x\(height)")
        print("Backing scale factor: \(backingScale)")
        print("Applied frame: \(window.frame)")
    }

    func applicationWillTerminate(_: Notification) {
        MultiDisplayNDIManager.shared.stopAll()
        if ndiInitialized {
            NDIlib_destroy()
        }
    }
}
