import AppKit
import CoreGraphics

final class StatusBarController: NSObject {
    var onPickResolution: ((Int, Int) -> Void)?
    var onOpenCustomResolution: (() -> Void)?
    var onToggleDisplay: ((CGDirectDisplayID, Bool) -> Void)?
    var selectedUUIDsProvider: (() -> Set<String>)?

    // Use quadrado para ícone-only
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

            // Tamanho ideal: 18x18 pt (evita escala fracionária)
            img?.size = NSSize(width: 18, height: 18)

            button.image = img
            button.image?.isTemplate = true
            button.imageScaling = .scaleProportionallyDown
            // Ajuste opcional:
            // button.contentTintColor = .labelColor
        }

        statusItem.menu = buildMenu()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(rebuildMenu),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    @objc private func rebuildMenu() {
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Seção: Resolução
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

        // Seção: Telas NDI
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
            item.representedObject = info.id // guardamos o CGDirectDisplayID
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
        guard
            let dict = sender.representedObject as? [String: Int],
            let w = dict["w"],
            let h = dict["h"]
        else {
            return
        }
        onPickResolution?(w, h)
    }

    @objc private func openCustomResolution() {
        onOpenCustomResolution?()
    }

    @objc private func toggleDisplayNDI(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID else {
            return
        }
        let newState: NSControl.StateValue = (sender.state == .on) ? .off : .on
        sender.state = newState
        onToggleDisplay?(id, newState == .on)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // Utilidades

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
        guard err == .success else {
            return []
        }
        let list = Array(active.prefix(Int(count)))

        // Mapeia NSScreen -> nome amigável
        var namesByID: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if
                let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            {
                let did = CGDirectDisplayID(num.uint32Value)
                let name = screen.localizedName
                namesByID[did] = name
            }
        }

        return list.compactMap { id in
            guard
                let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else {
                return nil
            }
            let uuidStr = (CFUUIDCreateString(nil, cfUUID) as String)
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            let name = namesByID[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Tela Interna" : "Tela")
            return DisplayInfo(id: id, uuidString: uuidStr, name: name, width: w, height: h)
        }
    }
}
