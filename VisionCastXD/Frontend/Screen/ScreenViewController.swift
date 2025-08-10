import Cocoa
import CoreImage
import ReSwift

// Action para ReSwift - usado para setar o display virtual criado
enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

// Seu NDISender (deve estar em outro arquivo, importado aqui)
// import NDISender (ou defina no mesmo módulo)

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    private var ndiSender: NDISender?
    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Criação do descriptor da virtual display
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Vision Cast XD"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        // Cria o display virtual
        display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))

        // Configura as resoluções suportadas
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: 1408, height: 640, refreshRate: 60),
            // outras resoluções, se quiser...
        ]
        display.apply(settings)
    }

    override func update(with viewData: ScreenViewData) {
        // Atualiza cor da janela conforme highlight
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        guard viewData.resolution != .zero else { return }

        if viewData.resolution != previousResolution || viewData.scaleFactor != previousScaleFactor {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor

            // Ajusta tamanho da janela e centraliza
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            view.window?.center()

            // Para stream anterior e libera
            stream?.stop()
            stream = nil

            // Obtém tamanho real do contentView (em pontos) e calcula pixels reais multiplicando pela escala da janela
            guard let contentSize = view.window?.contentView?.frame.size else {
                print("Erro: não conseguiu obter tamanho real do contentView")
                return
            }
            let backingScale = view.window?.backingScaleFactor ?? 1.0
            let pixelWidth = Int(contentSize.width * backingScale)
            let pixelHeight = Int(contentSize.height * backingScale)

            print("Creating NDISender with real content size \(pixelWidth)x\(pixelHeight)")

            ndiSender = NDISender(name: "VisionCast NDI", width: pixelWidth, height: pixelHeight)
            if ndiSender == nil {
                print("❌ Falha ao iniciar NDI Sender")
            }

            // Cria o stream para capturar o conteúdo da virtual display
            stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: pixelWidth,
                outputHeight: pixelHeight,
                pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                properties: [CGDisplayStream.showCursor: true] as CFDictionary,
                queue: .main
            ) { [weak self] _, _, frameSurface, _ in
                guard let self = self else { return }
                if let surface = frameSurface {
                    self.view.layer?.contents = surface

                    // Converte IOSurface para CGImage para envio via NDI
                    let ciImage = CIImage(ioSurface: surface)
                    let context = CIContext()
                    if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                        self.ndiSender?.send(image: cgImage)
                    }
                }
            }

            stream?.start()
        }
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard let screenResolution = previousResolution,
              abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let screenResolution = previousResolution else { return }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
