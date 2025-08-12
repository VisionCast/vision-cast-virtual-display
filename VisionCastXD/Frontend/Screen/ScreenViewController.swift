import Cocoa
import CoreImage
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    // Preview vinculado a um virtual existente
    private var boundConfigID: String?
    private var boundDisplayID: CGDirectDisplayID?
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0

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
        if let layer = root.layer {
            layer.backgroundColor = NSColor.black.cgColor
            layer.contentsScale = 1.0
            layer.rasterizationScale = 1.0
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Nada de criar display aqui. O AppDelegate chamará bindToVirtual().
    }

    // Liga este preview a um display virtual já criado pelo VirtualDisplayManager
    func bindToVirtual(configID: String, title: String? = nil) {
        guard let did = VirtualDisplayManager.shared.cgDisplayID(for: configID) else {
            print("ScreenVC: não encontrou displayID para config \(configID)")
            return
        }
        boundConfigID = configID
        boundDisplayID = did

        // Usa resolução da config
        if let cfg = VirtualDisplayManager.shared.listForMenu().first(where: { $0.id == configID }) {
            let parts = cfg.size.split(separator: "x")
            if let w = Int(parts.first ?? "0"), let h = Int(parts.last ?? "0") {
                pixelWidth = w
                pixelHeight = h
            }
        }

        if let t = title { view.window?.title = t }
        startPreview()
    }

    // Atualiza resolução do preview já vinculado (sem criar/derrubar o virtual)
    func updateBoundResolution(width: Int, height: Int) {
        pixelWidth = width
        pixelHeight = height
        restartPreviewResizingWindow()
    }

    private func startPreview() {
        guard let did = boundDisplayID else { return }
        restartPreviewResizingWindow(displayID: did)
    }

    private func restartPreviewResizingWindow(displayID: CGDirectDisplayID? = nil) {
        stream?.stop()
        stream = nil

        guard let window = view.window else { return }

        // Pixel-perfect: pontos = pixels / backingScale
        let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let sizePoints = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        window.setContentSize(sizePoints)
        window.contentAspectRatio = sizePoints
        window.center()

        guard let did = displayID ?? boundDisplayID else { return }
        let props: CFDictionary = [CGDisplayStream.showCursor: true] as CFDictionary

        stream = CGDisplayStream(
            dispatchQueueDisplay: did,
            outputWidth: pixelWidth,
            outputHeight: pixelHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props,
            queue: .main
        ) { [weak self] _, _, frameSurface, _ in
            guard let self = self, let surface = frameSurface else { return }
            self.view.layer?.contents = surface
        }

        stream?.start()
        store.dispatch(ScreenViewAction.setDisplayID(did))
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            let active = NSColor(named: "TitleBarActive") ?? .windowBackgroundColor
            let inactive = NSColor(named: "TitleBarInactive") ?? .windowBackgroundColor
            view.window?.backgroundColor = isWindowHighlighted ? active : inactive
            if isWindowHighlighted { view.window?.orderFrontRegardless() }
        }

        // Mantemos compatibilidade caso alguma parte ainda envie viewData.resolution
        guard viewData.resolution != .zero, let window = view.window else { return }
        if viewData.resolution != previousResolution || viewData.scaleFactor != previousScaleFactor {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor

            window.setContentSize(viewData.resolution)
            window.contentAspectRatio = viewData.resolution
            window.center()
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
