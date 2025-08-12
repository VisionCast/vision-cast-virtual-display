import ApplicationServices // <- para AXIsProcessTrustedWithOptions
import Cocoa
import CoreImage
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    private var ndiSender: NDISender?
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

    // Cria a view raiz quando não há XIB
    override func loadView() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Reconhecedor de clique para "entrar" na tela virtual
        let click = NSClickGestureRecognizer(target: self, action: #selector(didClickEnter(_:)))
        click.numberOfClicksRequired = 1
        view.addGestureRecognizer(click)

        // Descriptor do virtual display
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

    // Converte os valores para UInt ao criar o modo
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

    private func ensureAccessibilityPermission() -> Bool {
        // Solicita (ou verifica) permissão
        let opts: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            // Abre diretamente a tela certa nas Configurações do Sistema
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        return trusted
    }

    @objc private func didClickEnter(_ gr: NSClickGestureRecognizer) {
        guard gr.state == .ended, let display = display else { return }

        guard ensureAccessibilityPermission() else {
            print("⚠️ Sem permissão de Acessibilidade ainda. Autorize o app e reabra.")
            return
        }

        // Posição clicada na view -> pixels do display virtual
        let p = gr.location(in: view)
        let wPx = CGFloat(CGDisplayPixelsWide(display.displayID))
        let hPx = CGFloat(CGDisplayPixelsHigh(display.displayID))
        let xPx = max(0, min(wPx - 1, (p.x / view.bounds.width) * wPx))
        let yPx = max(0, min(hPx - 1, ((view.bounds.height - p.y) / view.bounds.height) * hPx))

        // Tenta mover no espaço local do display virtual
        let err = CGDisplayMoveCursorToPoint(display.displayID, CGPoint(x: xPx, y: yPx))
        if err == .success {
            print("✅ Cursor movido para o display virtual em (\(Int(xPx)), \(Int(yPx)))")
            return
        } else {
            print("⚠️ CGDisplayMoveCursorToPoint falhou (\(err.rawValue)). Fazendo fallback global.")
        }

        // Fallback: “warp” global para o centro do display virtual
        let bounds = CGDisplayBounds(display.displayID)
        let globalTarget = CGPoint(x: bounds.midX, y: bounds.midY)
        CGWarpMouseCursorPosition(globalTarget)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(truncating: true)) // re-associa, por garantia
        print("✅ Cursor movido (fallback) para o centro do display virtual: \(globalTarget)")
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
