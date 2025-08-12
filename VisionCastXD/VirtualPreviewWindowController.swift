import Cocoa
import CoreVideo

final class VirtualPreviewWindowController: NSWindowController {
    private let displayID: CGDirectDisplayID
    private let pixelWidth: Int
    private let pixelHeight: Int

    private var stream: CGDisplayStream?
    private let contentView = NSView(frame: .zero)

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, title: String) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        // Converte pixels -> points com base no scale da tela principal
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let sizePoints = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: sizePoints),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = title
        win.center()

        super.init(window: win)
        window?.contentView = contentView
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
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

    deinit { stop() }
}
