import Cocoa
import CoreImage
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    private var stream: CGDisplayStream?
    private let streamQueue = DispatchQueue(label: "screen.preview.stream", qos: .userInitiated)

    private var isWindowHighlighted = false
    private var lastSizePoints: NSSize?

    private var boundConfigID: String?
    private var boundDisplayID: CGDirectDisplayID?
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0

    override func loadView() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    func bindToVirtual(configID: String, title: String? = nil) {
        guard let did = VirtualDisplayManager.shared.cgDisplayID(for: configID) else {
            print("ScreenVC: não encontrou displayID para config \(configID)")
            return
        }
        boundConfigID = configID
        boundDisplayID = did

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

        let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let factor = Preferences.previewHalfRes ? 0.5 : 1.0
        let sizePoints = NSSize(width: CGFloat(pixelWidth) * factor / scale, height: CGFloat(pixelHeight) * factor / scale)
        window.setContentSize(sizePoints)
        window.contentAspectRatio = sizePoints
        if lastSizePoints != sizePoints {
            window.center()
            lastSizePoints = sizePoints
        }

        guard let did = displayID ?? boundDisplayID else { return }
        let fps = Preferences.preferredFPS
        let props: CFDictionary = [
            CGDisplayStream.showCursor: true,
            CGDisplayStream.minimumFrameTime: NSNumber(value: 1.0 / Double(fps)),
        ] as CFDictionary

        let outW = max(1, Int(Double(pixelWidth) * factor))
        let outH = max(1, Int(Double(pixelHeight) * factor))

        stream = CGDisplayStream(
            dispatchQueueDisplay: did,
            outputWidth: outW,
            outputHeight: outH,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props,
            queue: streamQueue
        ) { [weak self] _, _, frameSurface, _ in
            guard let self, let surface = frameSurface else { return }
            DispatchQueue.main.async {
                self.view.layer?.contents = surface
            }
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
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        // Mantido se precisar de snap ao mudar manualmente
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    }
}
