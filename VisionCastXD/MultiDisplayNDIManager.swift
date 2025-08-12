// Swift
import Cocoa
import CoreImage

final class MultiDisplayNDIManager {
    static let shared = MultiDisplayNDIManager()

    private(set) var selectedDisplayUUIDs: Set<String> = []
    private var observingDisplayChanges = false

    private lazy var ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    private struct Pipeline {
        var sender: NDISender
        var stream: CGDisplayStream
    }

    private var pipelines: [CGDirectDisplayID: Pipeline] = [:]

    func start() {
        if !observingDisplayChanges {
            observingDisplayChanges = true
            NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        applySelection()
    }

    func stopForDisplayID(_ id: CGDirectDisplayID) {
        stopPipeline(for: id)
        if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            let uuid = CFUUIDCreateString(nil, cf) as String
            if selectedDisplayUUIDs.contains(uuid) {
                selectedDisplayUUIDs.remove(uuid)
                var arr = Array(selectedDisplayUUIDs)
                UserDefaults.standard.set(arr, forKey: "selectedDisplayUUIDs")
            }
        }
    }

    func setSelectedDisplays(_ uuids: Set<String>) {
        let old = selectedDisplayUUIDs
        selectedDisplayUUIDs = uuids

        if uuids.isEmpty {
            stopAll()
            print("NDI: seleção vazia — todos pipelines parados")
            return
        }

        let map = currentUUIDToDisplayID()

        let toStop = old.subtracting(uuids)
        for u in toStop {
            if let id = map[u] { stopPipeline(for: id) }
        }

        let toStart = uuids.subtracting(old)
        for u in toStart {
            if let id = map[u] { startPipeline(for: id) }
        }

        let activeIDs = pipelines.keys.map { Int($0) }.sorted()
        print("NDI: seleção=\(selectedDisplayUUIDs.count) | ativos=\(activeIDs)")
    }

    func stopAll() {
        for (id, p) in pipelines {
            p.stream.stop()
            p.sender.shutdown()
            print("NDI: parou \(id)")
        }
        pipelines.removeAll()
        if observingDisplayChanges {
            NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            observingDisplayChanges = false
        }
    }

    // Permite reabrir o sender com o novo nome (ex.: após renomear virtual)
    func refreshSenderName(for displayID: CGDirectDisplayID) {
        guard pipelines[displayID] != nil else { return }
        stopPipeline(for: displayID)
        startPipeline(for: displayID)
    }

    private func applySelection() {
        let map = currentUUIDToDisplayID()
        let selectedIDsSet = Set(selectedDisplayUUIDs.compactMap { map[$0] })

        let idsToStop = Set(pipelines.keys).subtracting(selectedIDsSet)
        for id in idsToStop { stopPipeline(for: id) }

        let idsToStart = selectedIDsSet.subtracting(Set(pipelines.keys))
        for id in idsToStart { startPipeline(for: id) }

        let activeIDs = pipelines.keys.map { Int($0) }.sorted()
        print("NDI: seleção(sync)=\(selectedDisplayUUIDs.count) | ativos=\(activeIDs)")
    }

    private func currentUUIDToDisplayID() -> [String: CGDirectDisplayID] {
        var max = UInt32(16)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(max))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(max, &activeDisplays, &count) == .success else { return [:] }
        let list = Array(activeDisplays.prefix(Int(count)))

        var map: [String: CGDirectDisplayID] = [:]
        for id in list {
            if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                let uuid = CFUUIDCreateString(nil, cf) as String
                map[uuid] = id
            }
        }
        return map
    }

    private func displayFriendlyName(for displayID: CGDirectDisplayID) -> String {
        if let name = VirtualDisplayManager.shared.nameForDisplayID(displayID) { return name }
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(num.uint32Value) == displayID
            {
                return screen.localizedName
            }
        }
        return "Display \(displayID)"
    }

    private func startPipeline(for displayID: CGDirectDisplayID) {
        if pipelines[displayID] != nil { return }

        let width = Int(CGDisplayPixelsWide(displayID))
        let height = Int(CGDisplayPixelsHigh(displayID))
        guard width > 0, height > 0 else { return }

        let sourceName = "VisionCast NDI - \(displayFriendlyName(for: displayID))"

        guard let sender = NDISender(name: sourceName, width: width, height: height) else {
            print("❌ NDI sender falhou para display \(displayID)")
            return
        }

        let props: CFDictionary = [CGDisplayStream.showCursor: true] as CFDictionary

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props,
            queue: .main,
            handler: { [weak self] _, _, surface, _ in
                guard let self, let surface else { return }
                let ciImage = CIImage(ioSurface: surface)
                if let cg = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    sender.send(image: cg)
                }
            }
        ) else {
            print("❌ CGDisplayStream falhou para display \(displayID)")
            sender.shutdown()
            return
        }

        pipelines[displayID] = Pipeline(sender: sender, stream: stream)
        stream.start()
    }

    private func stopPipeline(for displayID: CGDirectDisplayID) {
        guard let p = pipelines.removeValue(forKey: displayID) else { return }
        p.stream.stop()
        p.sender.shutdown()
    }

    @objc private func displaysChanged() {
        applySelection()
    }
}
