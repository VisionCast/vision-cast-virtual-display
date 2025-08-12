// Swift
import Cocoa
import CoreImage

final class MultiDisplayNDIManager {
    static let shared = MultiDisplayNDIManager()

    // Conjunto de UUIDs de telas selecionadas para transmitir
    // Persistência é gerenciada pelo AppDelegate/UserDefaults.
    private(set) var selectedDisplayUUIDs: Set<String> = []

    func setSelectedDisplays(_ uuids: Set<String>) {
        selectedDisplayUUIDs = uuids
        // Reinicia com a nova seleção
        restart()
    }

    private var ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    private struct Pipeline {
        var sender: NDISender
        var stream: CGDisplayStream
    }

    private var pipelines: [CGDirectDisplayID: Pipeline] = [:]

    // Inicia somente as telas selecionadas
    func start() {
        buildPipelinesForSelectedDisplays()
        // Observa mudanças de monitores (pluga/despluga)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func restart() {
        stopAll()
        buildPipelinesForSelectedDisplays()
    }

    private func buildPipelinesForSelectedDisplays() {
        guard !selectedDisplayUUIDs.isEmpty else { return }

        // Lista displays ativos
        var max = UInt32(16)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(max))
        var count: UInt32 = 0
        let err = CGGetActiveDisplayList(max, &activeDisplays, &count)
        guard err == .success else {
            print("CGGetActiveDisplayList falhou: \(err.rawValue)")
            return
        }
        activeDisplays = Array(activeDisplays.prefix(Int(count)))

        // Filtra pelos UUIDs selecionados
        let selectedIDs: [CGDirectDisplayID] = activeDisplays.compactMap { id in
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let uuid = CFUUIDCreateString(nil, cf) as String
            return selectedDisplayUUIDs.contains(uuid) ? id : nil
        }

        for (index, displayID) in selectedIDs.enumerated() {
            let width = Int(CGDisplayPixelsWide(displayID))
            let height = Int(CGDisplayPixelsHigh(displayID))
            guard width > 0, height > 0 else { continue }

            let name = "VisionCast NDI - Display \(index + 1)"

            guard let sender = NDISender(name: name, width: width, height: height) else {
                print("❌ NDI sender falhou para display \(displayID)")
                continue
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
                continue
            }

            pipelines[displayID] = Pipeline(sender: sender, stream: stream)
            stream.start()
        }
    }

    func stopAll() {
        for (_, p) in pipelines {
            p.stream.stop()
        }
        pipelines.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displaysChanged() {
        // Recria pipelines quando os displays mudam, respeitando a seleção atual
        restart()
    }
}
