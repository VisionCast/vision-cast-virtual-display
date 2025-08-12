import AppKit
import CoreGraphics

final class StatusBarController: NSObject {
    var onPickResolution: ((Int, Int) -> Void)?
    var onOpenCustomResolution: (() -> Void)?
    var onToggleDisplay: ((CGDirectDisplayID, Bool) -> Void)?
    var selectedUUIDsProvider: (() -> Set<String>)?

    // NOVO: gerenciamento de virtuais
    struct VirtualItem {
        let id: String
        let title: String
        let sizeText: String
        let enabled: Bool
    }

    var virtualItemsProvider: (() -> [VirtualItem])?
    var onToggleVirtualItem: ((String, Bool) -> Void)?
    var onAddVirtualPreset: ((Int, Int) -> Void)?
    var onAddVirtualCustom: (() -> Void)? // <- novo

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private let resolutions: [(label: String, w: Int, h: Int)] = [
        ("1280 x 720", 1280, 720),
        ("1408 x 640", 1408, 640),
        ("1920 x 1080", 1920, 1080),
        ("2560 x 1440", 2560, 1440),
    ]

    override init() {
        super.init()
        if let button = statusItem.button {
            let custom = NSImage(named: "StatusBarIcon")
            let img = custom ?? NSImage(systemSymbolName: "display", accessibilityDescription: "VisionCast")
            img?.size = NSSize(width: 18, height: 18)
            button.image = img
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
        }
        statusItem.menu = buildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildMenu),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func refresh() { rebuildMenu() }

    @objc private func rebuildMenu() {
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Displays Virtuais
        let vTitle = NSMenuItem()
        vTitle.title = "Displays Virtuais"
        vTitle.isEnabled = false
        menu.addItem(vTitle)

        let vItems = virtualItemsProvider?() ?? []
        if vItems.isEmpty {
            let empty = NSMenuItem()
            empty.title = "Nenhum virtual configurado"
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for it in vItems {
                let item = NSMenuItem(title: "\(it.title) (\(it.sizeText))", action: #selector(toggleVirtual(_:)), keyEquivalent: "")
                item.target = self
                item.state = it.enabled ? .on : .off
                item.representedObject = it.id
                menu.addItem(item)
            }
        }

        // Adicionar (presets + Personalizar…)
        let addSub = NSMenu(title: "Adicionar Display Virtual")
        for r in resolutions {
            let sub = NSMenuItem(title: r.label, action: #selector(addVirtualPreset(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = ["w": r.w, "h": r.h]
            addSub.addItem(sub)
        }
        addSub.addItem(.separator())
        let custom = NSMenuItem(title: "Personalizar…", action: #selector(addVirtualCustom), keyEquivalent: "")
        custom.target = self
        addSub.addItem(custom)

        let addRoot = NSMenuItem(title: "Adicionar Display Virtual", action: nil, keyEquivalent: "")
        addRoot.submenu = addSub
        menu.addItem(addRoot)

        menu.addItem(.separator())

        // Resolução da janela/preview
        let titleRes = NSMenuItem()
        titleRes.title = "Resolução"
        titleRes.isEnabled = false
        menu.addItem(titleRes)

        for r in resolutions {
            let item = NSMenuItem(title: r.label, action: #selector(didPickResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["w": r.w, "h": r.h]
            menu.addItem(item)
        }
        let customize = NSMenuItem(title: "Personalizar…", action: #selector(openCustomResolution), keyEquivalent: "")
        customize.target = self
        menu.addItem(customize)

        menu.addItem(.separator())

        // NDI • Telas compartilhadas
        let titleNDI = NSMenuItem()
        titleNDI.title = "NDI • Telas compartilhadas"
        titleNDI.isEnabled = false
        menu.addItem(titleNDI)

        let selected = selectedUUIDsProvider?() ?? []
        for info in Self.activeDisplaysInfo() {
            let label = "\(info.name) (\(info.width)x\(info.height))"
            let item = NSMenuItem(title: label, action: #selector(toggleDisplayNDI(_:)), keyEquivalent: "")
            item.target = self
            item.state = selected.contains(info.uuidString) ? .on : .off
            item.representedObject = info.id
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func didPickResolution(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Int],
              let w = dict["w"], let h = dict["h"] else { return }
        onPickResolution?(w, h)
    }

    @objc private func openCustomResolution() { onOpenCustomResolution?() }

    @objc private func toggleDisplayNDI(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else { return }
        let newState: NSControl.StateValue = (sender.state == .on) ? .off : .on
        sender.state = newState
        onToggleDisplay?(id, newState == .on)
    }

    @objc private func toggleVirtual(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let newState: NSControl.StateValue = (sender.state == .on) ? .off : .on
        sender.state = newState
        onToggleVirtualItem?(id, newState == .on)
    }

    @objc private func addVirtualPreset(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Int],
              let w = dict["w"], let h = dict["h"] else { return }
        onAddVirtualPreset?(w, h)
    }

    @objc private func addVirtualCustom() {
        onAddVirtualCustom?()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // Utilidades (inalterado)
    struct DisplayInfo {
        let id: CGDirectDisplayID
        let uuidString: String
        let name: String
        let width: Int
        let height: Int
    }

    static func activeDisplaysInfo() -> [DisplayInfo] {
        var max = UInt32(16)
        var active = [CGDirectDisplayID](repeating: 0, count: Int(max))
        var count: UInt32 = 0
        let err = CGGetActiveDisplayList(max, &active, &count)
        guard err == .success else { return [] }
        let list = Array(active.prefix(Int(count)))

        var namesByID: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let did = CGDirectDisplayID(num.uint32Value)
                namesByID[did] = screen.localizedName
            }
        }

        return list.compactMap { id in
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let uuidStr = (CFUUIDCreateString(nil, cfUUID) as String)
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            let name = namesByID[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Tela Interna" : "Tela")
            return DisplayInfo(id: id, uuidString: uuidStr, name: name, width: w, height: h)
        }
    }
}
