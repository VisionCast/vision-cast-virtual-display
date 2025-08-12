import Cocoa
import CoreImage
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    // Removido o NDISender para evitar duplicação da tela virtual
    private var display: CGVirtualDisplay?
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?
    private lazy var ciContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
        ])
    }()

    override func loadView() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "Vision Cast XD"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        self.display = display
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))

        // Aplica o modo de resolução salvo (fallback 1408x640)
        let defaults = UserDefaults.standard
        let savedW = defaults.integer(forKey: "customWidth")
        let savedH = defaults.integer(forKey: "customHeight")
        let w = savedW > 0 ? savedW : 1408
        let h = savedH > 0 ? savedH : 640
        applyVirtualDisplayMode(width: w, height: h)
    }

    func applyVirtualDisplayMode(width: Int, height: Int) {
        guard let display = display else { return }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)]
        guard display.apply(settings) else {
            print("Falha ao aplicar settings no CGVirtualDisplay.")
            return
        }
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            let active = NSColor(named: "TitleBarActive") ?? .windowBackgroundColor
            let inactive = NSColor(named: "TitleBarInactive") ?? .windowBackgroundColor
            view.window?.backgroundColor = isWindowHighlighted ? active : inactive
            if isWindowHighlighted { view.window?.orderFrontRegardless() }
        }

        guard viewData.resolution != .zero else { return }
        guard let window = view.window else { return }

        if viewData.resolution != previousResolution || viewData.scaleFactor != previousScaleFactor {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor

            window.setContentSize(viewData.resolution)
            window.contentAspectRatio = viewData.resolution
            window.center()

            stream?.stop()
            stream = nil

            guard let contentSize = window.contentView?.frame.size else {
                print("Erro: não conseguiu obter tamanho real do contentView")
                return
            }
            let backingScale = window.backingScaleFactor
            let pixelWidth = Int(contentSize.width * backingScale)
            let pixelHeight = Int(contentSize.height * backingScale)

            guard let display = display else {
                print("Display virtual não está disponível; abortando criação do stream.")
                return
            }

            // Stream apenas para renderizar na janela (sem enviar NDI aqui)
            stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: pixelWidth,
                outputHeight: pixelHeight,
                pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                properties: [CGDisplayStream.showCursor: true] as CFDictionary,
                queue: .main
            ) { [weak self] _, _, frameSurface, _ in
                guard let self = self, let surface = frameSurface else { return }
                self.view.layer?.contents = surface

                // Mantemos a conversão para CGImage apenas se precisar de efeitos
                // Caso queira otimizar, pode remover o bloco abaixo
                // let ciImage = CIImage(ioSurface: surface)
                // _ = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
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
}
