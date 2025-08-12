import Cocoa
import CoreVideo

final class VirtualPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let displayID: CGDirectDisplayID
    private var pixelWidth: Int
    private var pixelHeight: Int

    private var stream: CGDisplayStream?
    private let contentView = NSView(frame: .zero)

    // Chamado quando a janela for fechada
    private let onClose: () -> Void

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, title: String, onClose: @escaping () -> Void = {}) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.onClose = onClose

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let sizePoints = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: sizePoints),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.contentAspectRatio = sizePoints
        win.center()

        super.init(window: win)
        window?.delegate = self
        window?.contentView = contentView
        contentView.wantsLayer = true
        if let layer = contentView.layer {
            layer.backgroundColor = NSColor.black.cgColor
            layer.contentsScale = 1.0
            layer.rasterizationScale = 1.0
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        guard stream == nil else { return }
        let props: CFDictionary = [CGDisplayStream.showCursor: true] as CFDictionary
        stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: pixelWidth,
            outputHeight: pixelHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props,
            queue: .main,
            handler: { [weak self] _, _, surface, _ in
                guard let self, let surface else { return }
                self.contentView.layer?.contents = surface
            }
        )
        stream?.start()
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    func resize(toPixelWidth w: Int, height h: Int) {
        pixelWidth = w
        pixelHeight = h
        stop()

        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let sizePoints = NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)

        if let win = window {
            win.setContentSize(sizePoints)
            win.contentAspectRatio = sizePoints
            win.center()
        }
        start()
    }

    func setTitle(_ title: String) {
        window?.title = title
    }

    // Ao fechar a janela do preview, pare stream e notifique o gerenciador (para matar NDI)
    func windowWillClose(_: Notification) {
        stop()
        onClose()
    }

    deinit { stop() }
}
