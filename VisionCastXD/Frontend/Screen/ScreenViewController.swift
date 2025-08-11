import Cocoa
import CoreImage
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    private var ndiSender: NDISender?
    private var display: CGVirtualDisplay? // deixe opcional para lidar com falhas posteriores
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

    // Cria a view raiz quando não há XIB
    override func loadView() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Descriptor do virtual display
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main // em Swift, use a property em vez do setter
        descriptor.name = "Vision Cast XD"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        // Cria o display (não é opcional em Swift)
        let display = CGVirtualDisplay(descriptor: descriptor)
        self.display = display
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))

        // Configura modos e aplica
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: 1408, height: 640, refreshRate: 60),
        ]

        // Em Swift o método é 'apply(_:)'
        guard display.apply(settings) else {
            print("Falha ao aplicar settings no CGVirtualDisplay (plugin pode não ter iniciado).")
            self.display = nil
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

            print("Creating NDISender with real content size \(pixelWidth)x\(pixelHeight)")
            ndiSender = NDISender(name: "VisionCast NDI", width: pixelWidth, height: pixelHeight)
            if ndiSender == nil {
                print("❌ Falha ao iniciar NDI Sender")
            }

            guard let display = display else {
                print("Display virtual não está disponível; abortando criação do stream.")
                return
            }

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

                let ciImage = CIImage(ioSurface: surface)
                if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    self.ndiSender?.send(image: cgImage)
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
