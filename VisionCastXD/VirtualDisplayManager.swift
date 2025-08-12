import Cocoa

final class VirtualDisplayManager {
    static let shared = VirtualDisplayManager()

    struct Config: Codable {
        var id: String
        var name: String
        var width: Int
        var height: Int
        var enabled: Bool
        var serial: UInt32
    }

    struct VDisplay {
        let config: Config
        let display: CGVirtualDisplay
    }

    private let kStorageKey = "virtualDisplays.configs"
    private(set) var configs: [Config] = []
    private var displaysByID: [String: VDisplay] = [:]
    private var previewsByID: [String: VirtualPreviewWindowController] = [:] // <- novo
    private var nextSerial: UInt32 = 0x0100

    func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: kStorageKey),
           let arr = try? JSONDecoder().decode([Config].self, from: data)
        {
            configs = arr
            if let maxSerial = arr.map({ $0.serial }).max() {
                nextSerial = max(nextSerial, maxSerial &+ 1)
            }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: kStorageKey)
        }
    }

    func listForMenu() -> [(id: String, title: String, enabled: Bool, size: String)] {
        configs.map {
            let title = $0.name.isEmpty ? "Virtual \($0.id.prefix(4))" : $0.name
            return (id: $0.id, title: title, enabled: $0.enabled, size: "\($0.width)x\($0.height)")
        }
    }

    func cgDisplayID(for configID: String) -> CGDirectDisplayID? {
        displaysByID[configID]?.display.displayID
    }

    func uuidString(for configID: String) -> String? {
        guard let did = cgDisplayID(for: configID),
              let cf = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    func currentVirtualUUIDs() -> Set<String> {
        Set(displaysByID.values.compactMap {
            guard let cf = CGDisplayCreateUUIDFromDisplayID($0.display.displayID)?.takeRetainedValue()
            else { return nil }
            return CFUUIDCreateString(nil, cf) as String
        })
    }

    @discardableResult
    func addVirtual(width: Int, height: Int, name: String? = nil, enabled: Bool = true) -> String {
        let id = UUID().uuidString
        let cfg = Config(
            id: id,
            name: name ?? "Virtual \(configs.count + 1)",
            width: width,
            height: height,
            enabled: enabled,
            serial: nextSerial
        )
        nextSerial &+= 1
        configs.append(cfg)
        save()
        if enabled { _ = createDisplay(from: cfg) }
        return id
    }

    func setEnabled(configID: String, enabled: Bool) -> CGDirectDisplayID? {
        guard let idx = configs.firstIndex(where: { $0.id == configID }) else { return nil }
        configs[idx].enabled = enabled
        save()

        if enabled {
            if displaysByID[configID] == nil {
                let did = createDisplay(from: configs[idx])
                return did
            }
            return displaysByID[configID]?.display.displayID
        } else {
            destroy(configID: configID)
            return nil
        }
    }

    func createAllEnabled() {
        for cfg in configs where cfg.enabled {
            _ = createDisplay(from: cfg)
        }
    }

    func destroy(configID: String) {
        // fecha preview primeiro
        closePreview(for: configID)
        // remove display runtime
        guard let vd = displaysByID.removeValue(forKey: configID) else { return }
        print("VDM: destruído \(vd.display.displayID) [\(configID)]")
    }

    func removeConfig(configID: String) {
        destroy(configID: configID)
        configs.removeAll { $0.id == configID }
        save()
    }

    // MARK: Interno

    @discardableResult
    private func createDisplay(from cfg: Config) -> CGDirectDisplayID? {
        if let existing = displaysByID[cfg.id] { return existing.display.displayID }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = cfg.name
        descriptor.maxPixelsWide = UInt32(max(cfg.width, 3840))
        descriptor.maxPixelsHigh = UInt32(max(cfg.height, 2160))
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = cfg.serial

        let display = CGVirtualDisplay(descriptor: descriptor)

        descriptor.terminationHandler = { [weak self] _, terminated in
            guard let self else { return }
            if let (k, _) = self.displaysByID.first(where: { $0.value.display.displayID == terminated.displayID }) {
                self.closePreview(for: k)
                self.displaysByID.removeValue(forKey: k)
                print("VDM: display \(terminated.displayID) encerrado pelo sistema (config \(k) permanece).")
            }
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(cfg.width), height: UInt(cfg.height), refreshRate: 60)]
        guard display.apply(settings) else {
            print("VDM: falha ao aplicar modo \(cfg.width)x\(cfg.height)")
            return nil
        }

        displaysByID[cfg.id] = VDisplay(config: cfg, display: display)

        // Abre preview automaticamente
        openPreview(for: cfg.id, title: cfg.name, width: cfg.width, height: cfg.height)

        print("VDM: criado \(display.displayID) \(cfg.width)x\(cfg.height) [\(cfg.id)]")
        return display.displayID
    }

    private func openPreview(for configID: String, title: String, width: Int, height: Int) {
        guard previewsByID[configID] == nil,
              let did = cgDisplayID(for: configID) else { return }
        let wc = VirtualPreviewWindowController(displayID: did, pixelWidth: width, pixelHeight: height, title: title)
        previewsByID[configID] = wc
        wc.showWindow(nil)
        wc.start()
    }

    private func closePreview(for configID: String) {
        if let wc = previewsByID.removeValue(forKey: configID) {
            wc.stop()
            wc.close()
        }
    }
}
