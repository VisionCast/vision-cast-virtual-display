// Swift
import Cocoa
import CoreImage

final class MultiDisplayNDIManager {
    static let shared = MultiDisplayNDIManager()

    private(set) var selectedDisplayUUIDs: Set<String> = []
    private var observingDisplayChanges = false

    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    private final class Pipeline {
        let sender: NDISender
        let stream: CGDisplayStream
        let buffer: UnsafeMutablePointer<UInt8>
        let rowBytes: Int
        let queue: DispatchQueue
        init(sender: NDISender, stream: CGDisplayStream, buffer: UnsafeMutablePointer<UInt8>, rowBytes: Int, queue: DispatchQueue) {
            self.sender = sender; self.stream = stream; self.buffer = buffer; self.rowBytes = rowBytes; self.queue = queue
        }

        deinit { buffer.deallocate() }
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
                UserDefaults.standard.set(Array(selectedDisplayUUIDs), forKey: "selectedDisplayUUIDs")
            }
        }
    }

    func setSelectedDisplays(_ uuids: Set<String>) {
        let old = selectedDisplayUUIDs
        selectedDisplayUUIDs = uuids
        if uuids.isEmpty { stopAll(); return }

        let map = currentUUIDToDisplayID()
        for u in old.subtracting(uuids) { if let id = map[u] { stopPipeline(for: id) } }
        for u in uuids.subtracting(old) { if let id = map[u] { startPipeline(for: id) } }
    }

    func stopAll() {
        for (_, p) in pipelines { p.stream.stop(); p.sender.shutdown() }
        pipelines.removeAll()
        if observingDisplayChanges {
            NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            observingDisplayChanges = false
        }
    }

    func refreshSenderName(for displayID: CGDirectDisplayID) {
        guard pipelines[displayID] != nil else { return }
        stopPipeline(for: displayID)
        startPipeline(for: displayID)
    }

    private func applySelection() {
        let map = currentUUIDToDisplayID()
        let selectedIDs = Set(selectedDisplayUUIDs.compactMap { map[$0] })
        let idsToStop = Set(pipelines.keys).subtracting(selectedIDs)
        for id in idsToStop { stopPipeline(for: id) }
        let idsToStart = selectedIDs.subtracting(Set(pipelines.keys))
        for id in idsToStart { startPipeline(for: id) }
    }

    private func currentUUIDToDisplayID() -> [String: CGDirectDisplayID] {
        var max = UInt32(16)
        var active = [CGDirectDisplayID](repeating: 0, count: Int(max))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(max, &active, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: Array(active.prefix(Int(count))).compactMap { id in
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, cf) as String, id)
        })
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
        guard let sender = NDISender(name: sourceName, width: width, height: height) else { return }

        let rowBytes = width * 4
        let capacity = rowBytes * height
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)

        let queue = DispatchQueue(label: "ndi.stream.\(displayID)", qos: .userInitiated)

        let fps = Preferences.preferredFPS
        let props: CFDictionary = [
            CGDisplayStream.showCursor: true,
            CGDisplayStream.minimumFrameTime: NSNumber(value: 1.0 / Double(fps)),
        ] as CFDictionary

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props,
            queue: queue,
            handler: { [weak self] _, _, surface, _ in
                guard let self, let surface else { return }
                autoreleasepool {
                    let ciImage = CIImage(ioSurface: surface)
                    self.ciContext.render(ciImage,
                                          toBitmap: buffer,
                                          rowBytes: rowBytes,
                                          bounds: ciImage.extent,
                                          format: .BGRA8,
                                          colorSpace: self.colorSpace)
                    sender.sendBGRA(bytes: buffer, bytesPerRow: rowBytes)
                }
            }
        ) else {
            sender.shutdown()
            buffer.deallocate()
            return
        }

        pipelines[displayID] = Pipeline(sender: sender, stream: stream, buffer: buffer, rowBytes: rowBytes, queue: queue)
        stream.start()
    }

    private func stopPipeline(for displayID: CGDirectDisplayID) {
        guard let p = pipelines.removeValue(forKey: displayID) else { return }
        p.stream.stop()
        p.sender.shutdown()
        // buffer desalocado no deinit do Pipeline
    }

    @objc private func displaysChanged() {
        applySelection()
    }
}
