// Swift
import Cocoa
import CoreImage

final class MultiDisplayNDIManager {
    static let shared = MultiDisplayNDIManager()

    private var ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    // Por display: sender + stream
    private struct Pipeline {
        var sender: NDISender
        var stream: CGDisplayStream
    }

    private var pipelines: [CGDirectDisplayID: Pipeline] = [:]

    func startAllDisplays() {
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

        // Evita duplicar pipelines
        stopAll()

        for (index, displayID) in activeDisplays.enumerated() {
            let width = Int(CGDisplayPixelsWide(displayID))
            let height = Int(CGDisplayPixelsHigh(displayID))
            guard width > 0, height > 0 else { continue }

            let name = "VisionCast NDI - Display \(index + 1)"

            guard let sender = NDISender(name: name, width: width, height: height) else {
                print("❌ NDI sender falhou para display \(displayID)")
                continue
            }

            // BGRA 8-bit
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
                    // Converte IOSurface -> CGImage (sRGB) e envia
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

        // Observa mudanças de monitores (pluga/despluga)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stopAll() {
        for (_, p) in pipelines {
            p.stream.stop()
            // NDISender é desalocado aqui e destrói só a instância do sender (não a NDI global)
        }
        pipelines.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displaysChanged() {
        // Recria pipelines quando os displays mudam
        startAllDisplays()
    }
}
